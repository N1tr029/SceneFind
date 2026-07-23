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
dialogue and visual evidence. Return ONLY strict JSON with keys: verified
(boolean), seasonNumber, episodeNumber, episodeTitle, evidence (short string),
confidence (0..1). Set verified=false unless the dialogue or visuals clearly
match a specific episode.`;

export async function verifyEpisode(
  env: Env,
  args: {
    showTitle: string;
    detectedDialogue: string;
    visualEvidence: string[];
    candidateSeason: number | null;
    candidateEpisode: number | null;
  },
): Promise<EpisodeVerification> {
  const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.GROQ_API_KEY}`,
    },
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

  if (!res.ok) {
    throw new ProviderError("provider_unavailable", `groq ${res.status}`);
  }

  const data = (await res.json()) as any;
  const text: string = data?.choices?.[0]?.message?.content ?? "{}";
  let parsed: any = {};
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = {};
  }

  return {
    verified: parsed.verified === true,
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
