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

  it("retries in plain JSON mode when Groq rejects the structured request", async () => {
    const bodies: any[] = [];
    vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body));
      bodies.push(body);
      if (body.response_format.type === "json_schema") {
        return new Response(JSON.stringify({ error: { message: "unsupported parameter" } }), { status: 400 });
      }
      return Response.json({
        choices: [{ message: { content: JSON.stringify({
          verified: false,
          seasonNumber: null,
          episodeNumber: null,
          episodeTitle: null,
          evidence: "No transcript line matched.",
          confidence: 0.2,
        }) } }],
      });
    });

    const result = await verifyEpisode(
      { GROQ_API_KEY: "test", GROQ_MODEL: "openai/gpt-oss-120b" } as unknown as Env,
      args,
    );

    expect(bodies).toHaveLength(2);
    expect(bodies[1].response_format).toEqual({ type: "json_object" });
    expect(bodies[1]).not.toHaveProperty("include_reasoning");
    expect(result.verified).toBe(false);
    expect(result.evidence).toBe("No transcript line matched.");
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

describe("providerErrorSummary", () => {
  it("keeps the provider's code and message but never echoed generations", async () => {
    const { providerErrorSummary } = await import("../src/providers/errorSummary");
    const summary = await providerErrorSummary(new Response(JSON.stringify({
      error: {
        message: "Failed to generate JSON.",
        type: "invalid_request_error",
        code: "json_validate_failed",
        failed_generation: "{\"evidence\":\"a line of dialogue from the clip\"}",
      },
    }), { status: 400 }));

    expect(summary).toBe("400 json_validate_failed: Failed to generate JSON.");
    expect(summary).not.toContain("dialogue");
  });
});
