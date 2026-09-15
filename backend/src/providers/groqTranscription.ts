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
  if (!response.ok) {
    // Logged without media or transcript content: status and Groq's own
    // message are enough to tell an expired key from a rejected file.
    console.warn("groq transcription failed", response.status, (await response.text()).slice(0, 300));
    return [];
  }
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

/** Groq's transcription endpoint takes multipart form data only, and infers
 *  the format from the file name, so an upload named "clip" with no extension
 *  and a JSON body carrying a URL were both rejected. */
export function transcriptionRequest(
  env: Env,
  evidence: {
    mediaURL?: string;
    mediaDataBase64?: string;
    mediaMimeType?: string;
  },
): { body: FormData; headers: Record<string, string> } | null {
  const form = new FormData();
  if (evidence.mediaURL && isHTTPSURL(evidence.mediaURL)) {
    form.append("url", evidence.mediaURL);
  } else if (evidence.mediaDataBase64 && evidence.mediaMimeType) {
    const bytes = Uint8Array.from(atob(evidence.mediaDataBase64), (character) => character.charCodeAt(0));
    form.append(
      "file",
      new Blob([bytes], { type: evidence.mediaMimeType }),
      `clip.${fileExtension(evidence.mediaMimeType)}`,
    );
  } else {
    return null;
  }
  form.append("model", env.GROQ_TRANSCRIPTION_MODEL || "whisper-large-v3-turbo");
  form.append("language", "en");
  form.append("response_format", "verbose_json");
  form.append("timestamp_granularities[]", "segment");
  form.append("temperature", "0");
  return { body: form, headers: {} };
}

/** Extensions Groq accepts: flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, webm. */
function fileExtension(mimeType: string): string {
  const subtype = mimeType.split(";")[0].split("/")[1]?.toLowerCase() ?? "";
  const known: Record<string, string> = {
    mp4: "mp4", "x-m4a": "m4a", m4a: "m4a", mpeg: "mp3", mp3: "mp3", webm: "webm",
    ogg: "ogg", wav: "wav", "x-wav": "wav", flac: "flac", quicktime: "mp4",
  };
  return known[subtype] ?? "mp4";
}

function isHTTPSURL(value: string): boolean {
  try {
    return new URL(value).protocol === "https:";
  } catch {
    return false;
  }
}
