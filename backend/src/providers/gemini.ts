import type { Env } from "../types";

export interface GeminiIdentification {
  detectedDialogue: string;
  showTitle: string | null;
  mediaType: "television" | "movie" | "other";
  releaseYear: number | null;
  seasonNumber: number | null;
  episodeNumber: number | null;
  episodeEvidence: string;
  visualEvidence: string[];
  rawConfidence: number;
}

const IDENTIFY_SYSTEM_PROMPT = `You identify the exact TV show or film in a short clip.
Use dialogue, OCR/text visible in frames, people/locations/wardrobe, audio, public title,
caption, thumbnail, and source metadata as separate evidence. Captions and hashtags may
be misleading and can never be the sole basis for a high-confidence result. Return no
title when the evidence does not reliably support one. Return seasonNumber and
episodeNumber only when the supplied dialogue or visual evidence supports that exact
episode; otherwise both must be null. Never infer an episode just because a caption
claims one.`;

const RESPONSE_SCHEMA = {
  type: "OBJECT",
  required: [
    "detectedDialogue",
    "showTitle",
    "mediaType",
    "releaseYear",
    "seasonNumber",
    "episodeNumber",
    "episodeEvidence",
    "visualEvidence",
    "rawConfidence",
  ],
  properties: {
    detectedDialogue: { type: "STRING" },
    showTitle: { type: "STRING", nullable: true },
    mediaType: { type: "STRING", enum: ["television", "movie", "other"] },
    releaseYear: { type: "INTEGER", nullable: true },
    seasonNumber: { type: "INTEGER", nullable: true },
    episodeNumber: { type: "INTEGER", nullable: true },
    episodeEvidence: { type: "STRING" },
    visualEvidence: { type: "ARRAY", items: { type: "STRING" } },
    rawConfidence: { type: "NUMBER" },
  },
};

export async function identifyClip(env: Env, parts: unknown[]): Promise<GeminiIdentification> {
  const models = [...new Set([env.GEMINI_MODEL, env.GEMINI_FALLBACK_MODEL].filter(Boolean))];
  let lastError: unknown;
  for (let index = 0; index < models.length; index += 1) {
    try {
      return await requestModel(env, models[index], parts);
    } catch (error) {
      lastError = error;
      if (!(error instanceof ProviderError) || !error.retryable || index === models.length - 1) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 400 * (index + 1)));
    }
  }
  throw lastError instanceof Error
    ? lastError
    : new ProviderError("provider_unavailable", "Identification provider unavailable.", true);
}

async function requestModel(
  env: Env,
  model: string,
  parts: unknown[],
): Promise<GeminiIdentification> {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent` +
    `?key=${encodeURIComponent(env.GEMINI_API_KEY)}`;
  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      signal: AbortSignal.timeout(22_000),
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: IDENTIFY_SYSTEM_PROMPT }] },
        contents: [{ role: "user", parts }],
        generationConfig: {
          responseMimeType: "application/json",
          responseSchema: RESPONSE_SCHEMA,
          temperature: 0.1,
          maxOutputTokens: 1_200,
        },
      }),
    });
  } catch {
    throw new ProviderError("provider_unavailable", "Identification timed out.", true);
  }
  if (!response.ok) {
    throw new ProviderError(
      "provider_unavailable",
      `Identification provider returned ${response.status}.`,
      response.status === 429 || response.status >= 500,
    );
  }

  const data = await response.json() as {
    candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
  };
  const text = data.candidates?.[0]?.content?.parts?.map((part) => part.text ?? "").join("") ?? "";
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new ProviderError("provider_unavailable", "Identification response was not valid JSON.", false);
  }
  return validateIdentification(parsed);
}

function validateIdentification(value: unknown): GeminiIdentification {
  if (!value || typeof value !== "object") throw invalidSchema();
  const payload = value as Record<string, unknown>;
  const mediaType = payload.mediaType;
  const visualEvidence = payload.visualEvidence;
  if (
    typeof payload.detectedDialogue !== "string" ||
    !(payload.showTitle === null || typeof payload.showTitle === "string") ||
    !["television", "movie", "other"].includes(String(mediaType)) ||
    !(payload.releaseYear === null || isInteger(payload.releaseYear)) ||
    !(payload.seasonNumber === null || isInteger(payload.seasonNumber)) ||
    !(payload.episodeNumber === null || isInteger(payload.episodeNumber)) ||
    typeof payload.episodeEvidence !== "string" ||
    !Array.isArray(visualEvidence) ||
    !visualEvidence.every((item) => typeof item === "string") ||
    typeof payload.rawConfidence !== "number" ||
    !Number.isFinite(payload.rawConfidence)
  ) {
    throw invalidSchema();
  }

  const confidence = clamp01(payload.rawConfidence);
  let showTitle = payload.showTitle?.trim() || null;
  if (confidence < 0.55) showTitle = null;
  const episodeEvidence = payload.episodeEvidence.trim();
  const exactEpisodeSupported =
    showTitle !== null &&
    confidence >= 0.78 &&
    episodeEvidence.length >= 12 &&
    payload.seasonNumber !== null &&
    payload.episodeNumber !== null;
  return {
    detectedDialogue: payload.detectedDialogue.trim(),
    showTitle,
    mediaType: mediaType as GeminiIdentification["mediaType"],
    releaseYear: payload.releaseYear as number | null,
    seasonNumber: exactEpisodeSupported ? payload.seasonNumber as number : null,
    episodeNumber: exactEpisodeSupported ? payload.episodeNumber as number : null,
    episodeEvidence,
    visualEvidence: (visualEvidence as string[]).slice(0, 12),
    rawConfidence: confidence,
  };
}

export class ProviderError extends Error {
  constructor(
    public readonly code: "provider_unavailable",
    message: string,
    public readonly retryable: boolean,
  ) {
    super(message);
  }
}

function invalidSchema(): ProviderError {
  return new ProviderError("provider_unavailable", "Identification response failed schema validation.", false);
}

function isInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value);
}

const clamp01 = (value: number): number => Math.max(0, Math.min(1, value));
