// Server-side Groq client for episode verification. Key lives only here.

import type { Env } from "../types";
import { ProviderError } from "./gemini";

export interface EpisodeVerification {
  verified: boolean;
  seasonNumber: number | null;
  episodeNumber: number | null;
  episodeTitle: string | null;
  evidence: string;
  confidence: number; // 0..1
}

const VERIFY_SYSTEM_PROMPT = `You verify a candidate TV episode against detected
dialogue, visual evidence, independently indexed transcript search results, and
a canonical episode guide. A social caption or preliminary guess may generate a
candidate but can never verify it. Choose only an entry present in episodeGuide,
and require either indexed dialogue evidence or concrete clip details that agree
with that entry's summary. Return ONLY strict JSON with keys: verified
(boolean), seasonNumber, episodeNumber, episodeTitle, evidence (short string),
confidence (0..1). Set verified=false unless the dialogue or visuals clearly
match a specific episode.`;

export async function verifyEpisode(
  env: Env,
  args: {
    showTitle: string;
    detectedDialogue: string;
    visualEvidence: string[];
    captionClaims: Array<{ season: number; episode: number }>;
    candidateSeason: number | null;
    candidateEpisode: number | null;
    episodeGuide: Array<{
      seasonNumber: number;
      episodeNumber: number;
      episodeTitle: string;
      summary: string;
      sourceURL: string;
    }>;
    webEvidence: Array<{
      seasonNumber: number;
      episodeNumber: number;
      episodeTitle: string;
      anchor: string;
      excerpt: string;
      sourceURL: string;
    }>;
  },
): Promise<EpisodeVerification> {
  let res: Response;
  try {
    res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${env.GROQ_API_KEY}`,
      },
      signal: AbortSignal.timeout(6_000),
      body: JSON.stringify({
        model: env.GROQ_MODEL,
        temperature: 0.1,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: VERIFY_SYSTEM_PROMPT },
          { role: "user", content: JSON.stringify(args) },
        ],
      }),
    });
  } catch {
    throw new ProviderError("provider_unavailable", "Episode verifier timed out.", true);
  }

  if (!res.ok) {
    throw new ProviderError(
      "provider_unavailable",
      `Episode verifier returned ${res.status}.`,
      res.status === 429 || res.status >= 500,
    );
  }

  const data = (await res.json()) as any;
  const text: string = data?.choices?.[0]?.message?.content ?? "{}";
  let parsed: any = {};
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = {};
  }

  const verified = parsed.verified === true &&
    Number.isSafeInteger(parsed.seasonNumber) &&
    Number.isSafeInteger(parsed.episodeNumber) &&
    typeof parsed.evidence === "string" &&
    parsed.evidence.trim().length >= 12 &&
    typeof parsed.confidence === "number" &&
    parsed.confidence >= 0.78;
  return {
    verified,
    seasonNumber: typeof parsed.seasonNumber === "number" ? parsed.seasonNumber : null,
    episodeNumber: typeof parsed.episodeNumber === "number" ? parsed.episodeNumber : null,
    episodeTitle: typeof parsed.episodeTitle === "string" ? parsed.episodeTitle : null,
    evidence: typeof parsed.evidence === "string" ? parsed.evidence : "",
    confidence:
      typeof parsed.confidence === "number"
        ? Math.max(0, Math.min(1, parsed.confidence))
        : 0,
  };
}
