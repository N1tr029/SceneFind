import type {
  AnalysisProgressEvent,
  AnalysisProgressKind,
  AnalysisRequest,
  ClipAnalysisResult,
  Env,
  SceneCandidate,
  WatchProvider,
} from "./types";
import { finishAllowance } from "./entitlement";
import { identifyClip } from "./providers/gemini";
import type { EpisodeVerification } from "./providers/groq";
import { resolveEpisodeEvidence } from "./episodeEvidence";
import {
  evidenceParts,
  hasRemoteYouTubeVideo,
  retrieveEvidence,
  type RetrievedEvidence,
} from "./sourceRetrieval";
import { handleWatchLinks } from "./watchLinks";
import { resolveSceneTimeline } from "./timestampResolver";
import { resolveEpisodeMetadata } from "./episodeCatalog";
import { transcribeMedia } from "./providers/groqTranscription";

interface SessionState {
  requestID: string;
  request: AnalysisRequest;
  entitlementOwner: string;
  reservationID: string;
  startedAtMs: number;
  events: AnalysisProgressEvent[];
  status: "running" | "completed" | "cancelled" | "failed";
  allowanceFinished: boolean;
  result?: ClipAnalysisResult;
  errorCode?: string;
}

const TERMINAL_RETENTION_MS = 15 * 60 * 1_000;

export class AnalysisSession implements DurableObject {
  private session?: SessionState;
  private readonly writers = new Set<WritableStreamDefaultWriter<Uint8Array>>();
  private readonly encoder = new TextEncoder();
  private readonly ready: Promise<void>;

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {
    this.ready = state.blockConcurrencyWhile(async () => {
      this.session = await state.storage.get<SessionState>("session");
    });
  }

  async fetch(req: Request): Promise<Response> {
    await this.ready;
    const url = new URL(req.url);
    switch (`${req.method} ${url.pathname}`) {
      case "POST /start":
        return this.handleStart(req);
      case "GET /events":
        return this.handleEvents();
      case "DELETE /cancel":
        return this.handleCancel();
      default:
        return new Response("not found", { status: 404 });
    }
  }

  async alarm(): Promise<void> {
    this.session = undefined;
    for (const writer of this.writers) await this.closeWriter(writer);
    await this.state.storage.deleteAll();
  }

  private async handleStart(req: Request): Promise<Response> {
    if (this.session) return Response.json({ ok: true, alreadyStarted: true });
    const body = await req.json() as {
      request: AnalysisRequest;
      requestID: string;
      entitlementOwner: string;
      reservationID: string;
    };
    this.session = {
      ...body,
      startedAtMs: Date.now(),
      events: [],
      status: "running",
      allowanceFinished: false,
    };
    await this.persist();
    this.state.waitUntil(this.runPipeline().catch((error) => this.fail(error)));
    return Response.json({ ok: true });
  }

  private handleEvents(): Response {
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const writer = writable.getWriter();
    this.writers.add(writer);
    const backlog = this.session?.events ?? [];
    for (const event of backlog) void this.push(writer, event);
    if (this.session?.status === "failed") {
      void this.pushRaw(writer, `event: error\ndata: ${JSON.stringify({ code: this.session.errorCode ?? "internal" })}\n\n`)
        .finally(() => this.closeWriter(writer));
    } else if (this.session?.status === "completed" || this.session?.status === "cancelled") {
      void this.closeWriter(writer);
    }
    return new Response(readable, {
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-cache, no-store",
        connection: "keep-alive",
      },
    });
  }

  private async handleCancel(): Promise<Response> {
    if (this.session?.status === "running") {
      this.session.status = "cancelled";
      await this.finishAllowance(false);
      this.discardSensitiveInput();
      await this.persist();
      await this.scheduleExpiry();
    }
    for (const writer of this.writers) await this.closeWriter(writer);
    return new Response(null, { status: 204 });
  }

  private async runPipeline(): Promise<void> {
    const session = this.requiredSession();
    await this.emit("requestRead", "Source received", sourceLabel(session.request));

    const evidence = await retrieveEvidence(session.request);
    if (this.cancelled()) return;
    await this.emit(
      "metadataRetrieved",
      "Source retrieved",
      evidence.title ?? sourceHost(evidence.finalURL) ?? "Direct media",
    );
    if (evidence.dialogue) {
      await this.emit("transcriptRetrieved", "Dialogue found", preview(evidence.dialogue));
    }
    if (evidence.mediaDataBase64 || evidence.thumbnailDataBase64 || hasRemoteYouTubeVideo(evidence)) {
      await this.emit(
        "mediaRetrieved",
        evidence.mediaDataBase64 || hasRemoteYouTubeVideo(evidence)
          ? "Video evidence retrieved"
          : "Thumbnail retrieved",
      );
    }

    await this.emit("mediaAnalysisStarted", "Analyzing dialogue and visuals");
    const identification = await identifyClip(this.env, evidenceParts(session.request, evidence));
    if (this.cancelled()) return;
    if (identification.detectedDialogue) {
      await this.emit("dialogueDetected", "Dialogue found", preview(identification.detectedDialogue));
    }
    if (!identification.showTitle) throw new PublicPipelineError("not_found");
    await this.emit("showIdentified", "Possible show or movie", identification.showTitle);

    const timelineTask = evidence.transcriptCues?.length
      ? resolveSceneTimeline({
          cues: evidence.transcriptCues,
          durationSeconds: evidence.durationSeconds,
          expectedTitle: identification.showTitle,
        }).catch(() => null)
      : Promise.resolve(null);

    let verification: EpisodeVerification = {
      verified: false,
      seasonNumber: null,
      episodeNumber: null,
      episodeTitle: null,
      evidence: "No exact episode was supported by the supplied evidence.",
      confidence: 0,
    };
    if (identification.mediaType === "television") {
      await this.emit(
        "episodeCandidatesFound",
        "Researching exact episode",
        identification.seasonNumber !== null && identification.episodeNumber !== null
          ? `Untrusted candidate S${identification.seasonNumber} E${identification.episodeNumber}`
          : "Searching transcript anchors, images, and the canonical episode guide",
      );
      try {
        verification = await resolveEpisodeEvidence(this.env, {
          showTitle: identification.showTitle,
          detectedDialogue: identification.detectedDialogue || evidence.dialogue || "",
          transcriptCues: evidence.transcriptCues,
          visualEvidence: [identification.episodeEvidence, ...identification.visualEvidence]
            .filter(Boolean),
          captionEvidence: [
            evidence.title,
            evidence.description,
            session.request.sourceText,
          ].filter((value): value is string => Boolean(value)).join("\n"),
          candidateSeason: identification.seasonNumber,
          candidateEpisode: identification.episodeNumber,
        });
      } catch {
        verification = { ...verification, evidence: "Episode verifier was unavailable." };
      }
    }
    let timeline = await timelineTask;
    if (!timeline && (evidence.mediaURL || evidence.mediaDataBase64)) {
      const transcribedCues = await transcribeMedia(this.env, evidence).catch(() => []);
      if (transcribedCues.length > 0) {
        await this.emit(
          "transcriptRetrieved",
          "Timed audio transcription recovered",
          `${transcribedCues.length} speech segments`,
        );
        timeline = await resolveSceneTimeline({
          cues: transcribedCues,
          durationSeconds: evidence.durationSeconds,
          expectedTitle: identification.showTitle,
        }).catch(() => null);
      }
    }
    if (timeline?.seriesTitle && timeline.episodeTitle) {
      const catalogEpisode = await resolveEpisodeMetadata({
        showTitle: timeline.seriesTitle,
        episodeTitle: timeline.episodeTitle,
      }).catch(() => null);
      if (catalogEpisode) {
        verification = {
          verified: true,
          seasonNumber: catalogEpisode.seasonNumber,
          episodeNumber: catalogEpisode.episodeNumber,
          episodeTitle: catalogEpisode.episodeTitle,
          evidence:
            `Timed dialogue matched “${timeline.episodeTitle}”; TVMaze maps it to ` +
            `S${catalogEpisode.seasonNumber} E${catalogEpisode.episodeNumber}. ` +
            catalogEpisode.sourceURL,
          confidence: Math.max(0.94, timeline.confidence),
        };
      }
    }
    if (this.cancelled()) return;
    await this.emit(
      verification.verified ? "episodeVerified" : "episodeUnverified",
      verification.verified ? "Verified result" : "Show verified; episode uncertain",
      verification.evidence,
    );
    if (timeline) {
      await this.emit(
        "timestampResolved",
        "Exact clip window matched",
        `${formatTimestamp(timeline.startSeconds)}–${formatTimestamp(timeline.endSeconds)} · ` +
          `${timeline.anchorCount} dialogue anchor${timeline.anchorCount === 1 ? "" : "s"}`,
      );
    }

    const candidate = this.buildCandidate(identification, verification, timeline);
    const [artworkURL, providers] = await Promise.all([
      fetchArtwork(candidate.mediaTitle).catch(() => null),
      fetchWatchProviders(this.env, candidate, session.request.region).catch(() => []),
    ]);
    if (this.cancelled()) return;
    const completedCandidate: SceneCandidate = {
      ...candidate,
      heroImageURL: artworkURL,
      watchProviders: providers,
    };
    if (artworkURL) await this.emit("artworkRetrieved", "Artwork found", candidate.mediaTitle);
    await this.emit(
      "providersChecked",
      providers.length > 0 ? "Streaming availability" : "No verified streaming destination",
      providers.length > 0 ? `${providers.length} verified destination${providers.length === 1 ? "" : "s"}` : undefined,
    );

    const result = this.buildResult(
      session,
      evidence,
      identification,
      completedCandidate,
      verification,
    );
    await this.complete(result);
  }

  private buildCandidate(
    identification: Awaited<ReturnType<typeof identifyClip>>,
    verification: EpisodeVerification,
    timeline: Awaited<ReturnType<typeof resolveSceneTimeline>>,
  ): SceneCandidate {
    const episodeVerified = identification.mediaType === "television" && verification.verified;
    return {
      id: crypto.randomUUID(),
      mediaTitle: identification.showTitle!,
      mediaType: identification.mediaType,
      releaseYear: identification.releaseYear ?? 0,
      seasonNumber: episodeVerified ? verification.seasonNumber : null,
      episodeNumber: episodeVerified ? verification.episodeNumber : null,
      episodeTitle: episodeVerified ? verification.episodeTitle : null,
      sceneTimestampSeconds: timeline?.startSeconds ?? null,
      clipEndTimestampSeconds: timeline?.endSeconds ?? null,
      matchedSubtitleText: timeline?.matchedDialogue ?? null,
      confidence: Math.min(0.99, Math.max(0.55, episodeVerified
        ? (identification.rawConfidence + verification.confidence) / 2
        : identification.rawConfidence)),
      subtitleScore: Math.max(verification.confidence, timeline?.confidence ?? 0),
      visualScore: identification.rawConfidence,
      metadataScore: 0,
      streamingService: null,
      streamingURL: null,
      heroImageURL: null,
      watchProviders: [],
      timestampAccuracy: timeline ? "matchedDialogue" : null,
      timestampBasis: timeline
        ? `Matched ${timeline.anchorCount} timed dialogue anchor${timeline.anchorCount === 1 ? "" : "s"} ` +
          `within ${timeline.maximumAnchorDeviationSeconds.toFixed(1)}s; ending anchor ` +
          `${timeline.endExtrapolationSeconds.toFixed(1)}s before the clip finished` +
          (timeline.heldOutEndAnchorErrorSeconds === null
            ? "."
            : ` with ${timeline.heldOutEndAnchorErrorSeconds.toFixed(1)}s held-out error.`)
        : null,
    };
  }

  private buildResult(
    session: SessionState,
    evidence: RetrievedEvidence,
    identification: Awaited<ReturnType<typeof identifyClip>>,
    topCandidate: SceneCandidate,
    verification: EpisodeVerification,
  ): ClipAnalysisResult {
    return {
      id: crypto.randomUUID(),
      requestID: session.requestID,
      createdAt: new Date(session.startedAtMs).toISOString(),
      detectedDialogue: identification.detectedDialogue || evidence.dialogue || "",
      topCandidate,
      alternativeCandidates: [],
      analysisDetails: {
        sourcePlatform: session.request.platformHint ?? "unknown",
        sourceType: session.request.sourceType ?? (session.request.sourceURL ? "url" : "file"),
        extractedFrameCount:
          evidence.thumbnailDataBase64 || evidence.mediaMimeType?.startsWith("image/") ? 1 : 0,
        subtitleCandidatesCompared: evidence.transcriptCues?.length ?? (evidence.dialogue ? 1 : 0),
        totalProcessingDuration: (Date.now() - session.startedAtMs) / 1_000,
        directMediaAnalyzed: Boolean(evidence.mediaDataBase64 || hasRemoteYouTubeVideo(evidence)),
        visualEvidence: identification.visualEvidence,
        episodeVerificationEvidence: verification.evidence,
        progressEvents: session.events,
      },
    };
  }

  private async emit(kind: AnalysisProgressKind, title: string, detail?: string): Promise<void> {
    const session = this.requiredSession();
    const event: AnalysisProgressEvent = {
      id: crypto.randomUUID(),
      kind,
      title,
      detail: detail ?? null,
      elapsedSeconds: (Date.now() - session.startedAtMs) / 1_000,
    };
    session.events.push(event);
    await this.persist();
    for (const writer of this.writers) await this.push(writer, event);
  }

  private async complete(result: ClipAnalysisResult): Promise<void> {
    const session = this.requiredSession();
    if (session.status !== "running") return;
    await this.finishAllowance(true);
    session.result = result;
    session.status = "completed";
    const event: AnalysisProgressEvent = {
      id: crypto.randomUUID(),
      kind: "completed",
      title: "Verified result ready",
      detail: JSON.stringify(result),
      elapsedSeconds: (Date.now() - session.startedAtMs) / 1_000,
    };
    session.events.push(event);
    this.discardSensitiveInput();
    await this.persist();
    await this.scheduleExpiry();
    for (const writer of this.writers) {
      await this.push(writer, event);
      await this.closeWriter(writer);
    }
  }

  private async fail(error: unknown): Promise<void> {
    const session = this.session;
    if (!session || session.status !== "running") return;
    session.status = "failed";
    session.errorCode = error instanceof PublicPipelineError ? error.code : "provider_unavailable";
    await this.finishAllowance(false);
    this.discardSensitiveInput();
    await this.persist();
    await this.scheduleExpiry();
    for (const writer of this.writers) {
      await this.pushRaw(writer, `event: error\ndata: ${JSON.stringify({ code: session.errorCode })}\n\n`);
      await this.closeWriter(writer);
    }
  }

  private async finishAllowance(success: boolean): Promise<void> {
    const session = this.requiredSession();
    if (session.allowanceFinished) return;
    await finishAllowance(
      this.env,
      session.entitlementOwner,
      session.reservationID,
      success,
    );
    session.allowanceFinished = true;
  }

  private persist(): Promise<void> {
    return this.state.storage.put("session", this.requiredSession());
  }

  private requiredSession(): SessionState {
    if (!this.session) throw new Error("analysis not started");
    return this.session;
  }

  private discardSensitiveInput(): void {
    const session = this.requiredSession();
    session.request = {
      sourceType: session.request.sourceType,
      platformHint: session.request.platformHint,
      region: session.request.region,
      idempotencyKey: session.request.idempotencyKey,
    };
  }

  private scheduleExpiry(): Promise<void> {
    return this.state.storage.setAlarm(Date.now() + TERMINAL_RETENTION_MS);
  }

  private push(writer: WritableStreamDefaultWriter<Uint8Array>, event: AnalysisProgressEvent) {
    return this.pushRaw(writer, `data: ${JSON.stringify(event)}\n\n`);
  }

  private async pushRaw(writer: WritableStreamDefaultWriter<Uint8Array>, text: string) {
    try {
      await writer.write(this.encoder.encode(text));
    } catch {
      this.writers.delete(writer);
    }
  }

  private async closeWriter(writer: WritableStreamDefaultWriter<Uint8Array>) {
    this.writers.delete(writer);
    try {
      await writer.close();
    } catch {
      // Already closed by the client.
    }
  }

  private cancelled(): boolean {
    return this.session?.status === "cancelled";
  }
}

class PublicPipelineError extends Error {
  constructor(public readonly code: "not_found") {
    super(code);
  }
}

function sourceLabel(request: AnalysisRequest): string {
  if (request.sourceURL) return new URL(request.sourceURL).hostname;
  return request.sourceType ?? "direct media";
}

function preview(value: string): string {
  const normalized = value.replace(/\s+/g, " ").trim();
  return normalized.length > 180 ? `${normalized.slice(0, 177)}…` : normalized;
}

function formatTimestamp(value: number): string {
  const seconds = Math.max(0, Math.round(value));
  const hours = Math.floor(seconds / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);
  const remainder = seconds % 60;
  return [hours, minutes, remainder].map((part) => String(part).padStart(2, "0")).join(":");
}

function sourceHost(value?: string): string | null {
  if (!value) return null;
  try {
    return new URL(value).hostname;
  } catch {
    return null;
  }
}

async function fetchArtwork(title: string): Promise<string | null> {
  const url = new URL("https://api.tvmaze.com/search/shows");
  url.searchParams.set("q", title);
  const response = await fetch(url, { signal: AbortSignal.timeout(4_000) });
  if (!response.ok) return null;
  const values = await response.json() as Array<{
    show?: { name?: string; image?: { original?: string; medium?: string } };
  }>;
  const normalized = normalize(title);
  const match = values.find((value) => normalize(value.show?.name ?? "") === normalized);
  return match?.show?.image?.original ?? match?.show?.image?.medium ?? null;
}

/** Brand symbol and colour per service, mirroring the local Debug path so a
 *  backend-resolved provider looks identical to a locally-resolved one. The
 *  backend previously returned play.tv.fill and FFFFFF for everything, which
 *  made every provider row render as a white pill. */
const PROVIDER_STYLE: Record<string, { symbol: string; color: string }> = {
  netflix: { symbol: "play.tv.fill", color: "E50914" },
  appleTV: { symbol: "appletv.fill", color: "FFFFFF" },
  disneyPlus: { symbol: "sparkles", color: "4D8CFF" },
  hulu: { symbol: "play.tv.fill", color: "1CE783" },
  primeVideo: { symbol: "play.circle.fill", color: "00A8E1" },
  max: { symbol: "play.tv.fill", color: "6C5CE7" },
  peacock: { symbol: "sparkles.tv.fill", color: "FFD500" },
  paramountPlus: { symbol: "play.tv.fill", color: "0064FF" },
};

async function fetchWatchProviders(
  env: Env,
  candidate: SceneCandidate,
  region?: string,
): Promise<WatchProvider[]> {
  const url = new URL("https://internal/v1/watch-links");
  url.searchParams.set("title", candidate.mediaTitle);
  url.searchParams.set("type", candidate.mediaType === "television" ? "tv" : candidate.mediaType);
  if (candidate.releaseYear > 0) url.searchParams.set("year", String(candidate.releaseYear));
  if (candidate.seasonNumber) url.searchParams.set("season", String(candidate.seasonNumber));
  if (candidate.episodeNumber) url.searchParams.set("episode", String(candidate.episodeNumber));
  if (candidate.episodeTitle) url.searchParams.set("episodeTitle", candidate.episodeTitle);
  if (region) url.searchParams.set("region", region);
  const response = await handleWatchLinks(new Request(url), env);
  if (!response.ok) return [];
  const body = await response.json() as {
    links?: Array<{ url: string; service: string; serviceName: string }>;
  };
  return (body.links ?? []).map((link) => {
    const style = PROVIDER_STYLE[link.service] ?? { symbol: "play.circle.fill", color: "8AB4F8" };
    return {
    id: link.service,
    name: link.serviceName,
    offer: candidate.seasonNumber ? "Verified episode" : "Verified title",
    episodeURL: link.url,
    sceneURL: null,
    symbolName: style.symbol,
    brandColorHex: style.color,
    destinationLevel: candidate.seasonNumber ? "exactEpisode" : "show",
    destinationDiagnostic: candidate.seasonNumber
      ? "Backend-verified exact provider page for this episode."
      : "The provider page confirmed this title.",
    };
  });
}

function normalize(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}
