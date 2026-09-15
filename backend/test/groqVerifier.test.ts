import { afterEach, describe, expect, it, vi } from "vitest";
import { verificationRequestBody, verifyEpisode } from "../src/providers/groq";
import type { Env } from "../src/types";

const args = {
  showTitle: "Example Show",
  detectedDialogue: "Ron Hextall just scored the final goal for us",
  visualEvidence: [],
  captionClaims: [],
  candidateSeason: 2,
  candidateEpisode: 2,
  episodeGuide: [],
  webEvidence: [],
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("episode verifier request", () => {
  it("asks for schema-constrained JSON with low reasoning effort", () => {
    const body = verificationRequestBody("openai/gpt-oss-120b", args) as any;

    expect(body.model).toBe("openai/gpt-oss-120b");
    expect(body.reasoning_effort).toBe("low");
    expect(body.include_reasoning).toBe(false);
    // Groq rejects reasoning_format alongside include_reasoning.
    expect(body).not.toHaveProperty("reasoning_format");
    expect(body.response_format.type).toBe("json_schema");
    expect(body.response_format.json_schema.strict).toBe(true);
    const schema = body.response_format.json_schema.schema;
    expect(schema.additionalProperties).toBe(false);
    expect([...schema.required].sort()).toEqual(Object.keys(schema.properties).sort());
    expect(JSON.parse(body.messages[1].content)).toEqual(args);
  });

  it("sends the configured model and reads the structured reply", async () => {
    let sent: any;
    vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
      sent = JSON.parse(String(init?.body));
      return Response.json({
        choices: [{
          message: {
            content: JSON.stringify({
              verified: true,
              seasonNumber: 2,
              episodeNumber: 2,
              episodeTitle: "The Unprecedented Goal",
              evidence: "Two transcript lines match this episode.",
              confidence: 0.91,
            }),
          },
        }],
      });
    });

    const result = await verifyEpisode(
      { GROQ_API_KEY: "test", GROQ_MODEL: "openai/gpt-oss-120b" } as unknown as Env,
      args,
    );

    expect(sent.model).toBe("openai/gpt-oss-120b");
    expect(result).toEqual({
      verified: true,
      seasonNumber: 2,
      episodeNumber: 2,
      episodeTitle: "The Unprecedented Goal",
      evidence: "Two transcript lines match this episode.",
      confidence: 0.91,
    });
  });
});
