// Server-side Gemini client. The key lives only here (env secret) and never
// reaches the client. Mirrors what the app's GeminiClipIdentificationService
// used to do directly.

import type { Env } from "../types";

export interface GeminiIdentification {
  detectedDialogue: string;
  showTitle: string | null;
  mediaType: "television" | "movie" | "other";
  releaseYear: number | null;
  seasonNumber: number | null;
  episodeNumber: number | null;
  visualEvidence: string[];
  rawConfidence: number; // 0..1 self-reported, re-scored downstream
}

const IDENTIFY_SYSTEM_PROMPT = `You identify the exact TV show or film a short clip comes from.
Return ONLY strict JSON with keys: detectedDialogue, showTitle, mediaType
("television"|"movie"|"other"), releaseYear, seasonNumber, episodeNumber,
visualEvidence (array of short strings), rawConfidence (0..1). Use null when
unknown. Never guess an episode number without visual or dialogue evidence.`;

// `parts` are Gemini content parts already assembled by the caller (inline
// image data for frames, text for transcript, etc.).
export async function identifyClip(
  env: Env,
  parts: unknown[],
): Promise<GeminiIdentification> {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${env.GEMINI_MODEL}:generateContent` +
    `?key=${encodeURIComponent(env.GEMINI_API_KEY)}`;

  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: IDENTIFY_SYSTEM_PROMPT }] },
      contents: [{ role: "user", parts }],
      generationConfig: { responseMimeType: "application/json", temperature: 0.2 },
    }),
  });

  if (!res.ok) {
    // Map to a stable public error upstream; do not leak the provider body.
    throw new ProviderError("provider_unavailable", `gemini ${res.status}`);
  }

  const data = (await res.json()) as any;
  const text: string =
    data?.candidates?.[0]?.content?.parts?.map((p: any) => p.text).join("") ?? "{}";

  const parsed = safeJSON(text);
  return {
    detectedDialogue: str(parsed.detectedDialogue) ?? "",
    showTitle: str(parsed.showTitle),
    mediaType: (["television", "movie", "other"].includes(parsed.mediaType)
      ? parsed.mediaType
      : "other") as GeminiIdentification["mediaType"],
    releaseYear: num(parsed.releaseYear),
    seasonNumber: num(parsed.seasonNumber),
    episodeNumber: num(parsed.episodeNumber),
    visualEvidence: Array.isArray(parsed.visualEvidence)
      ? parsed.visualEvidence.filter((v: unknown) => typeof v === "string")
      : [],
    rawConfidence: clamp01(num(parsed.rawConfidence) ?? 0),
  };
}

export class ProviderError extends Error {
  constructor(public readonly code: "provider_unavailable", message: string) {
    super(message);
  }
}

function safeJSON(text: string): any {
  try {
    return JSON.parse(text);
  } catch {
    // Gemini occasionally wraps JSON in prose; grab the first {...} block.
    const m = text.match(/\{[\s\S]*\}/);
    if (m) {
      try {
        return JSON.parse(m[0]);
      } catch {
        /* fall through */
      }
    }
    return {};
  }
}

const str = (v: unknown): string | null => (typeof v === "string" && v.length ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && isFinite(v) ? v : null);
const clamp01 = (n: number): number => Math.max(0, Math.min(1, n));
