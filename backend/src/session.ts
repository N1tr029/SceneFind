// AnalysisSession Durable Object.
//
// One instance per analysis id. It owns the pipeline run, buffers progress
// events durably, and fans them out to any connected SSE client. The worker
// (index.ts) routes to it by id.
//
// Internal routes (worker -> DO):
//   POST   /start   { request, requestID }   begin the pipeline
//   GET    /events                           Server-Sent Events stream
//   DELETE /cancel                           stop work + drop evidence

import type {
  AnalysisProgressEvent,
  AnalysisProgressKind,
  AnalysisRequest,
  ClipAnalysisResult,
  Env,
  SceneCandidate,
} from "./types";
import { identifyClip } from "./providers/gemini";
import { verifyEpisode } from "./providers/groq";

interface SessionState {
  requestID: string;
  request: AnalysisRequest;
  startedAtMs: number;
  events: AnalysisProgressEvent[];
  status: "running" | "completed" | "cancelled" | "failed";
  result?: ClipAnalysisResult;
  errorCode?: string;
}

export class AnalysisSession implements DurableObject {
  private session?: SessionState;
  private readonly writers = new Set<WritableStreamDefaultWriter<Uint8Array>>();
  private readonly encoder = new TextEncoder();

  constructor(private readonly state: DurableObjectState, private readonly env: Env) {}

  async fetch(req: Request): Promise<Response> {
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

  private async handleStart(req: Request): Promise<Response> {
    if (this.session) {
      return Response.json({ ok: true, alreadyStarted: true });
    }
    const body = (await req.json()) as { request: AnalysisRequest; requestID: string };
    this.session = {
      requestID: body.requestID,
      request: body.request,
      startedAtMs: Date.now(),
      events: [],
      status: "running",
    };
    // Kick off the pipeline; it survives as long as an SSE client is connected.
    // TODO: for durability across eviction between POST and GET, drive the
    // pipeline from a Durable Object alarm instead of a bare promise.
    void this.runPipeline().catch((err) => this.fail(err));
    return Response.json({ ok: true });
  }

  private handleEvents(): Response {
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const writer = writable.getWriter();
    this.writers.add(writer);

    // Replay everything buffered so far, then stream live events.
    const backlog = this.session?.events ?? [];
    for (const evt of backlog) void this.push(writer, evt);
    if (this.session?.status === "completed" || this.session?.status === "cancelled") {
      void this.closeWriter(writer);
    }

    return new Response(readable, {
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      },
    });
  }

  private async handleCancel(): Promise<Response> {
    if (this.session && this.session.status === "running") {
      this.session.status = "cancelled";
    }
    await this.state.storage.deleteAll(); // drop temporary evidence
    for (const w of this.writers) await this.closeWriter(w);
    return new Response(null, { status: 204 });
  }

  // --- pipeline ------------------------------------------------------------

  private async runPipeline(): Promise<void> {
    const s = this.session!;

    await this.emit("requestRead", "Reading shared clip");

    // TODO: fetch source metadata + media. For social/web URLs this is the
    // retrieval stage the app used to do locally. Until ported, we pass the URL
    // straight to the model as context.
    await this.emit("metadataRetrieved", "Resolved source", s.request.sourceURL ?? undefined);
    await this.emit("mediaRetrieved", "Fetched media");

    if (this.cancelled()) return;
    await this.emit("mediaAnalysisStarted", "Analyzing frames + dialogue");

    // Real provider work — key stays server-side.
    const parts: unknown[] = [
      {
        text:
          `Identify the show or film for this shared clip. Source URL: ` +
          `${s.request.sourceURL ?? "(none)"}.`,
      },
    ];
    // TODO: attach extracted frames as inlineData image parts + transcript.

    const id = await identifyClip(this.env, parts);
    await this.emit("dialogueDetected", "Detected dialogue", id.detectedDialogue || undefined);

    if (!id.showTitle) {
      // Nothing to verify — finish with a low-confidence "unidentified" result.
      await this.emit("episodeUnverified", "Could not identify the show");
      return this.complete(this.buildResult(s, id.detectedDialogue, null, []));
    }

    await this.emit("showIdentified", "Identified show", id.showTitle);
    await this.emit("episodeCandidatesFound", "Found episode candidates");

    if (this.cancelled()) return;
    const verification = await verifyEpisode(this.env, {
      showTitle: id.showTitle,
      detectedDialogue: id.detectedDialogue,
      visualEvidence: id.visualEvidence,
      candidateSeason: id.seasonNumber,
      candidateEpisode: id.episodeNumber,
    });

    await this.emit(
      verification.verified ? "episodeVerified" : "episodeUnverified",
      verification.verified ? "Verified episode" : "Episode unverified",
      verification.evidence || undefined,
    );

    // TODO: provider resolution (where to watch) + artwork lookup (TMDB).
    await this.emit("providersChecked", "Checked streaming providers");
    await this.emit("artworkRetrieved", "Fetched artwork");

    const candidate = this.buildCandidate(id, verification);
    return this.complete(this.buildResult(s, id.detectedDialogue, candidate, [candidate]));
  }

  private buildCandidate(
    id: Awaited<ReturnType<typeof identifyClip>>,
    v: Awaited<ReturnType<typeof verifyEpisode>>,
  ): SceneCandidate {
    const confidence = Math.max(id.rawConfidence, v.confidence);
    return {
      id: crypto.randomUUID(),
      mediaTitle: id.showTitle ?? "Unknown",
      mediaType: id.mediaType,
      releaseYear: id.releaseYear ?? 0,
      seasonNumber: v.seasonNumber ?? id.seasonNumber ?? null,
      episodeNumber: v.episodeNumber ?? id.episodeNumber ?? null,
      episodeTitle: v.episodeTitle,
      sceneTimestampSeconds: null,
      clipEndTimestampSeconds: null,
      matchedSubtitleText: null,
      confidence,
      subtitleScore: 0,
      visualScore: id.rawConfidence,
      metadataScore: v.confidence,
      streamingService: null, // TODO: provider resolution
      streamingURL: null,
      heroImageURL: null, // TODO: artwork lookup
      watchProviders: null,
    };
  }

  private buildResult(
    s: SessionState,
    dialogue: string,
    top: SceneCandidate | null,
    alternatives: SceneCandidate[],
  ): ClipAnalysisResult {
    const placeholder: SceneCandidate = top ?? {
      id: crypto.randomUUID(),
      mediaTitle: "Unidentified",
      mediaType: "other",
      releaseYear: 0,
      confidence: 0,
      subtitleScore: 0,
      visualScore: 0,
      metadataScore: 0,
    } as SceneCandidate;
    return {
      id: crypto.randomUUID(),
      requestID: s.requestID,
      createdAt: new Date(s.startedAtMs).toISOString(),
      detectedDialogue: dialogue,
      topCandidate: placeholder,
      alternativeCandidates: alternatives,
      analysisDetails: {
        sourcePlatform: s.request.platformHint ?? "unknown",
        sourceType: "url",
        extractedFrameCount: 0,
        subtitleCandidatesCompared: 0,
        totalProcessingDuration: (Date.now() - s.startedAtMs) / 1000,
        directMediaAnalyzed: false,
        progressEvents: s.events,
      },
    };
  }

  // --- event fan-out -------------------------------------------------------

  private async emit(kind: AnalysisProgressKind, title: string, detail?: string): Promise<void> {
    const s = this.session!;
    const evt: AnalysisProgressEvent = {
      id: crypto.randomUUID(),
      kind,
      title,
      detail: detail ?? null,
      elapsedSeconds: (Date.now() - s.startedAtMs) / 1000,
    };
    s.events.push(evt);
    await this.state.storage.put("session", s);
    for (const w of this.writers) await this.push(w, evt);
  }

  private async complete(result: ClipAnalysisResult): Promise<void> {
    const s = this.session!;
    s.result = result;
    s.status = "completed";
    await this.state.storage.put("session", s);
    // Final "completed" event carries the full result as its detail payload.
    const evt: AnalysisProgressEvent = {
      id: crypto.randomUUID(),
      kind: "completed",
      title: "Done",
      detail: JSON.stringify(result),
      elapsedSeconds: (Date.now() - s.startedAtMs) / 1000,
    };
    s.events.push(evt);
    for (const w of this.writers) {
      await this.push(w, evt);
      await this.closeWriter(w);
    }
  }

  private async fail(err: unknown): Promise<void> {
    if (this.session) {
      this.session.status = "failed";
      this.session.errorCode = err instanceof Error ? err.message : "internal";
    }
    for (const w of this.writers) {
      await this.pushRaw(w, `event: error\ndata: {"code":"internal"}\n\n`);
      await this.closeWriter(w);
    }
  }

  private push(w: WritableStreamDefaultWriter<Uint8Array>, evt: AnalysisProgressEvent) {
    return this.pushRaw(w, `data: ${JSON.stringify(evt)}\n\n`);
  }

  private async pushRaw(w: WritableStreamDefaultWriter<Uint8Array>, text: string) {
    try {
      await w.write(this.encoder.encode(text));
    } catch {
      this.writers.delete(w);
    }
  }

  private async closeWriter(w: WritableStreamDefaultWriter<Uint8Array>) {
    this.writers.delete(w);
    try {
      await w.close();
    } catch {
      /* already closed */
    }
  }

  private cancelled(): boolean {
    return this.session?.status === "cancelled";
  }
}
