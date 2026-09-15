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

/** Strict structured output: Groq constrains decoding to this schema, so the
 *  reply always parses. Nullable fields are unions because strict mode requires
 *  every property to be listed as required. */
const VERIFICATION_SCHEMA = {
  type: "object",
  properties: {
    verified: { type: "boolean" },
    seasonNumber: { type: ["integer", "null"] },
    episodeNumber: { type: ["integer", "null"] },
    episodeTitle: { type: ["string", "null"] },
    evidence: { type: "string" },
    confidence: { type: "number" },
  },
  required: ["verified", "seasonNumber", "episodeNumber", "episodeTitle", "evidence", "confidence"],
  additionalProperties: false,
} as const;

/** The verifier model is a reasoning model. Low effort keeps it inside the
 *  timeout and the free tier's tokens-per-minute budget; the reasoning text is
 *  never needed, so it is not sent back. */
export function verificationRequestBody(model: string, args: unknown): Record<string, unknown> {
  return {
    model,
    temperature: 0.1,
    reasoning_effort: "low",
    include_reasoning: false,
    max_completion_tokens: 1_024,
    response_format: {
      type: "json_schema",
      json_schema: { name: "episode_verification", strict: true, schema: VERIFICATION_SCHEMA },
    },
    messages: [
      { role: "system", content: VERIFY_SYSTEM_PROMPT },
      { role: "user", content: JSON.stringify(args) },
    ],
  };
}

/** The fallback: JSON mode, which every Groq model supports, without the
 *  reasoning or schema parameters. */
export function plainVerificationRequestBody(model: string, args: unknown): Record<string, unknown> {
  return {
    model,
    temperature: 0.1,
    max_completion_tokens: 1_024,
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: VERIFY_SYSTEM_PROMPT },
      { role: "user", content: JSON.stringify(args) },
    ],
  };
}

async function postVerification(env: Env, body: Record<string, unknown>): Promise<Response> {
  try {
    return await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${env.GROQ_API_KEY}`,
      },
      signal: AbortSignal.timeout(6_000),
      body: JSON.stringify(body),
    });
  } catch {
    throw new ProviderError("provider_unavailable", "Episode verifier timed out.", true);
  }
}

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
  let res = await postVerification(env, verificationRequestBody(env.GROQ_MODEL, args));
  if (res.status === 400) {
    // Structured outputs and reasoning parameters are the newest part of this
    // request. If Groq rejects them, one plain JSON-mode retry keeps the
    // verifier working while the log says what to fix.
    console.warn("groq verifier rejected structured request", (await res.text()).slice(0, 300));
    res = await postVerification(env, plainVerificationRequestBody(env.GROQ_MODEL, args));
  }

  if (!res.ok) {
    console.warn("groq verifier failed", res.status, (await res.text()).slice(0, 300));
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
