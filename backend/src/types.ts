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

  // Vars (wrangler.toml [vars])
  GEMINI_MODEL: string;
  GROQ_MODEL: string;
  ALLOW_INSECURE_DEV_AUTH: string;

  // Bindings
  ANALYSIS: DurableObjectNamespace;
  RATE_LIMIT: KVNamespace;
}

export type AnalysisProgressKind =
  | "requestRead"
  | "metadataRetrieved"
  | "mediaRetrieved"
  | "mediaAnalysisStarted"
  | "dialogueDetected"
  | "showIdentified"
  | "episodeCandidatesFound"
  | "episodeVerified"
  | "episodeUnverified"
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
  // For direct uploads the client first PUTs media to a signed URL (future);
  // for now a URL is required.
  platformHint?: string;
  idempotencyKey?: string;
}

// Stable public error codes — provider errors are mapped to these, raw bodies
// never reach the client.
export type PublicErrorCode =
  | "unauthorized"
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

export interface EntitlementState {
  freeRemaining: number;
  isPremium: boolean;
  renewsAt?: string | null;
  fairUseLimited: boolean;
}
