import type { TranscriptCue } from "../sourceRetrieval";
import type { Env } from "../types";

interface GroqSegment {
  start?: number;
  end?: number;
  text?: string;
  avg_logprob?: number;
  no_speech_prob?: number;
}

export async function transcribeMedia(
  env: Env,
  evidence: {
    mediaURL?: string;
    mediaDataBase64?: string;
    mediaMimeType?: string;
  },
  fetcher: typeof fetch = fetch,
): Promise<TranscriptCue[]> {
  const request = transcriptionRequest(env, evidence);
  if (!request) return [];
  let response: Response;
  try {
    response = await fetcher("https://api.groq.com/openai/v1/audio/transcriptions", {
      ...request,
      headers: {
        ...request.headers,
        authorization: `Bearer ${env.GROQ_API_KEY}`,
      },
      signal: AbortSignal.timeout(24_000),
    });
  } catch {
    return [];
  }
  if (!response.ok) return [];
  let body: { segments?: GroqSegment[] };
  try {
    body = await response.json() as { segments?: GroqSegment[] };
  } catch {
    return [];
  }
  return parseGroqSegments(body.segments);
}

export function parseGroqSegments(segments?: GroqSegment[]): TranscriptCue[] {
  if (!Array.isArray(segments)) return [];
  return segments.slice(0, 4_000).flatMap((segment): TranscriptCue[] => {
    const startSeconds = Number(segment.start);
    const endSeconds = Number(segment.end);
    const text = segment.text?.replace(/\s+/g, " ").trim() ?? "";
    if (
      !Number.isFinite(startSeconds) ||
      !Number.isFinite(endSeconds) ||
      endSeconds < startSeconds ||
      text.length < 2 ||
      Number(segment.no_speech_prob ?? 0) >= 0.8 ||
      Number(segment.avg_logprob ?? 0) < -1.2
    ) return [];
    return [{ startSeconds, endSeconds, text }];
  });
}

function transcriptionRequest(
  env: Env,
  evidence: {
    mediaURL?: string;
    mediaDataBase64?: string;
    mediaMimeType?: string;
  },
): { body: BodyInit; headers: Record<string, string> } | null {
  const common = {
    model: env.GROQ_TRANSCRIPTION_MODEL || "whisper-large-v3-turbo",
    language: "en",
    response_format: "verbose_json",
    timestamp_granularities: ["segment"],
    temperature: 0,
  };
  if (evidence.mediaURL && isHTTPSURL(evidence.mediaURL)) {
    return {
      body: JSON.stringify({ ...common, url: evidence.mediaURL }),
      headers: { "content-type": "application/json" },
    };
  }
  if (!evidence.mediaDataBase64 || !evidence.mediaMimeType) return null;
  const bytes = Uint8Array.from(atob(evidence.mediaDataBase64), (character) => character.charCodeAt(0));
  const form = new FormData();
  form.append("file", new Blob([bytes], { type: evidence.mediaMimeType }), "clip");
  form.append("model", common.model);
  form.append("language", common.language);
  form.append("response_format", common.response_format);
  form.append("timestamp_granularities[]", "segment");
  form.append("temperature", "0");
  return { body: form, headers: {} };
}

function isHTTPSURL(value: string): boolean {
  try {
    return new URL(value).protocol === "https:";
  } catch {
    return false;
  }
}
