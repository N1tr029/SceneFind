// Wire types for the SceneFind /v1 API.
//
// These mirror the app's Swift models in Shared/Models/AnalysisModels.swift so
// the client can decode responses without changes. Keep the JSON field names in
// sync with the Codable structs (Swift uses the property names verbatim).

export interface Env {
  // Secrets (wrangler secret put ...)
  GROQ_API_KEY: string;
  GEMINI_API_KEY: string;
  APPLE_TEAM_ID?: string;
  APPLE_APP_ID?: string;
  APPLE_BUNDLE_ID: string;
  /** SerpApi (64 hex chars) or Brave Search (`BSA…`) key, told apart by shape.
   *  Optional: without it /v1/watch-links resolves nothing and the app falls
   *  back to opening a service's own search page. */
  SEARCH_API_KEY?: string;

  // Vars (wrangler.toml [vars])
  GEMINI_MODEL: string;
  GEMINI_FALLBACK_MODEL: string;
  GROQ_MODEL: string;
  GROQ_TRANSCRIPTION_MODEL: string;
  ALLOW_INSECURE_DEV_AUTH: string;
  APP_ATTEST_ALLOW_DEVELOPMENT: string;
  APPLE_ENABLE_ONLINE_CHECKS: string;

  // Bindings
  ANALYSIS: DurableObjectNamespace;
  APP_ATTEST: DurableObjectNamespace;
  ENTITLEMENTS: DurableObjectNamespace;
  RATE_LIMIT: KVNamespace;
  /** Resolved episode → provider URL cache, shared by every install. */
  WATCH_LINKS: KVNamespace;
}

/** A provider page confirmed to be the requested title. */
export interface WatchLink {
  url: string;
  service:
    | "netflix"
    | "appleTV"
    | "disneyPlus"
    | "hulu"
    | "primeVideo"
    | "max"
    | "peacock"
    | "paramountPlus";
  serviceName: string;
}

export interface WatchLinksResponse {
  links: WatchLink[];
  /** Whether this answer cost a search or came from the shared cache. */
  source: "resolved" | "cache";
}

export type AnalysisProgressKind =
  | "requestRead"
  | "metadataRetrieved"
  | "transcriptRetrieved"
  | "mediaRetrieved"
  | "mediaAnalysisStarted"
  | "dialogueDetected"
  | "showIdentified"
  | "episodeCandidatesFound"
  | "episodeVerified"
  | "episodeUnverified"
  | "timestampResolved"
  | "providersChecked"
  | "artworkRetrieved"
  | "completed";

export interface AnalysisProgressEvent {
  id: string; // UUID
  kind: AnalysisProgressKind;
  title: string;
  detail?: string | null;
  elapsedSeconds: number;
}

export type MediaType = "television" | "movie" | "other";

export interface SceneCandidate {
  id: string;
  mediaTitle: string;
  mediaType: MediaType;
  releaseYear: number;
  seasonNumber?: number | null;
  episodeNumber?: number | null;
  episodeTitle?: string | null;
  sceneTimestampSeconds?: number | null;
  clipEndTimestampSeconds?: number | null;
  matchedSubtitleText?: string | null;
  confidence: number;
  subtitleScore: number;
  visualScore: number;
  metadataScore: number;
  streamingService?: string | null;
  streamingURL?: string | null;
  heroImageURL?: string | null;
  watchProviders?: WatchProvider[] | null;
  timestampAccuracy?: "matchedDialogue" | "estimated" | null;
  timestampBasis?: string | null;
}

export interface WatchProvider {
  id: string;
  name: string;
  offer: string;
  episodeURL: string;
  sceneURL?: string | null;
  symbolName: string;
  brandColorHex: string;
  destinationLevel?: "exactEpisode" | "show" | "search" | null;
  destinationDiagnostic?: string | null;
}

export interface AnalysisDetails {
  sourcePlatform: string;
  sourceType: string;
  extractedFrameCount: number;
  subtitleCandidatesCompared: number;
  totalProcessingDuration: number;
  directMediaAnalyzed?: boolean | null;
  visualEvidence?: string[] | null;
  episodeVerificationEvidence?: string | null;
  progressEvents?: AnalysisProgressEvent[] | null;
  stageTimings?: { stage: AnalysisProgressKind; durationSeconds: number }[] | null;
}

export interface ClipAnalysisResult {
  id: string;
  requestID: string;
  createdAt: string; // ISO-8601
  detectedDialogue: string;
  topCandidate: SceneCandidate;
  alternativeCandidates: SceneCandidate[];
  analysisDetails: AnalysisDetails;
}

// POST /v1/analysis request body.
export interface AnalysisRequest {
  // Exactly one of these identifies the media to analyze.
  sourceURL?: string; // a shared clip/social URL
  sourceType?: "url" | "video" | "image" | "plainText" | "file";
  sourceText?: string;
  /** Direct user-selected media. Capped and validated again by the Worker. */
  sourceDataBase64?: string;
  sourceMimeType?: string;
  platformHint?: string;
  region?: string;
  idempotencyKey: string;
}

// Stable public error codes — provider errors are mapped to these, raw bodies
// never reach the client.
export type PublicErrorCode =
  | "unauthorized"
  | "attestation_required"
  | "rate_limited"
  | "entitlement_exhausted"
  | "invalid_request"
  | "unsupported_source"
  | "provider_unavailable"
  | "not_found"
  | "internal";

export interface PublicError {
  error: { code: PublicErrorCode; message: string };
}

export type EntitlementPlan = "freeTrial" | "starter" | "pro" | "lifetime";

export type EntitlementStatus =
  | "active"
  | "gracePeriod"
  | "billingRetry"
  | "expired"
  | "revoked"
  | "refunded";

export interface EntitlementState {
  plan: EntitlementPlan;
  status: EntitlementStatus;
  allowance: number;
  remaining: number;
  periodStart?: string | null;
  periodEnd?: string | null;
  renewsAt?: string | null;
  canAnalyze: boolean;
  lastSyncedAt: string;
}

export interface AllowanceReservation {
  reservationID: string;
  state: EntitlementState;
  duplicate: boolean;
}
