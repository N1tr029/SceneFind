import { describe, expect, it } from "vitest";
import { resolveEpisodeEvidence } from "../src/episodeEvidence";
import type { Env } from "../src/types";

const env = {
  SEARCH_API_KEY: "BSA-test",
  GROQ_API_KEY: "test",
  GROQ_MODEL: "test",
} as unknown as Env;

const guideFetcher = (async () => Response.json({
  name: "Example Show",
  url: "https://www.tvmaze.com/shows/1/example-show",
  _embedded: { episodes: [
    {
      season: 2,
      number: 2,
      name: "The Unprecedented Goal",
      summary: "Murray leaves the hockey game early in traffic and misses the final goal.",
      url: "https://www.tvmaze.com/episodes/22/the-unprecedented-goal",
    },
    {
      season: 4,
      number: 16,
      name: "The Dynamic Duo",
      summary: "Barry tries to reinvent himself with a new identity.",
      url: "https://www.tvmaze.com/episodes/416/the-dynamic-duo",
    },
  ] },
})) as typeof fetch;

describe("resolveEpisodeEvidence", () => {
  it("accepts two quoted transcript anchors mapped to one canonical episode", async () => {
    const anchors = [
      "Ron Hextall just scored the final goal for us",
      "We left the hockey game early because of traffic",
    ];
    const result = await resolveEpisodeEvidence(env, {
      showTitle: "Example Show",
      detectedDialogue: anchors.join(". "),
      transcriptCues: anchors.map((text, index) => ({
        startSeconds: index * 8,
        endSeconds: index * 8 + 4,
        text,
      })),
      visualEvidence: ["A family wears hockey jerseys in an arena."],
      captionEvidence: "#viral",
      candidateSeason: null,
      candidateEpisode: null,
    }, {
      fetcher: guideFetcher,
      searcher: async (options) => [{
        url: "https://transcripts.example/example-show/s02e02-the-unprecedented-goal",
        title: "Example Show S2E2 — The Unprecedented Goal transcript",
        snippet: options.query.includes("Hextall") ? anchors[0] : anchors[1],
      }],
      verifier: async () => { throw new Error("offline"); },
    });

    expect(result.verified).toBe(true);
    expect(result.seasonNumber).toBe(2);
    expect(result.episodeNumber).toBe(2);
    expect(result.episodeTitle).toBe("The Unprecedented Goal");
    expect(result.evidence).toContain("2 anchor(s)");
  });

  it("verifies a canonical candidate from its transcript page without calling Groq", async () => {
    const anchor = "Ron Hextall scored the final goal while we sat in traffic";
    let verifierCalls = 0;
    const fetcher = (async (input: RequestInfo | URL) => {
      const url = input instanceof Request ? input.url : input.toString();
      if (url.includes("api.tvmaze.com")) return guideFetcher(input);
      if (url === "https://transcripts.example/example-show/the-unprecedented-goal") {
        return new Response(`<html><body>${anchor}. We left the hockey game early.</body></html>`, {
          status: 200,
          headers: { "content-type": "text/html" },
        });
      }
      return new Response("not found", { status: 404 });
    }) as typeof fetch;
    const withoutGroq = { ...env, GROQ_API_KEY: "" };

    const result = await resolveEpisodeEvidence(withoutGroq, {
      showTitle: "Example Show",
      detectedDialogue: anchor,
      visualEvidence: ["A family leaves a hockey game."],
      captionEvidence: "Example Show S2 E2",
      candidateSeason: 2,
      candidateEpisode: 2,
    }, {
      fetcher,
      searcher: async ({ query }) => query.includes("The Unprecedented Goal")
        ? [{
            url: "http://transcripts.example/example-show/the-unprecedented-goal",
            title: "Example Show — The Unprecedented Goal transcript",
            snippet: "Full episode script",
          }]
        : [],
      verifier: async () => {
        verifierCalls += 1;
        throw new Error("Groq must not be called");
      },
    });

    expect(result.verified).toBe(true);
    expect(result.episodeTitle).toBe("The Unprecedented Goal");
    expect(result.evidence).toContain("https://transcripts.example/");
    expect(verifierCalls).toBe(0);
  });

  it("rejects a caption-only season and episode claim", async () => {
    const result = await resolveEpisodeEvidence(env, {
      showTitle: "Example Show",
      detectedDialogue: "Can you please hand me that folder from the desk",
      visualEvidence: ["Two people stand in a plain office hallway."],
      captionEvidence: "Example Show Season 4 Episode 16",
      candidateSeason: 4,
      candidateEpisode: 16,
    }, {
      fetcher: guideFetcher,
      searcher: async () => [],
      verifier: async () => ({
        verified: true,
        seasonNumber: 4,
        episodeNumber: 16,
        episodeTitle: "The Dynamic Duo",
        evidence: "The caption names it.",
        confidence: 0.99,
      }),
    });

    expect(result.verified).toBe(false);
    expect(result.seasonNumber).toBeNull();
    expect(result.evidence).toContain("independent");
  });

  it("rejects a verifier result that is absent from the canonical guide", async () => {
    const result = await resolveEpisodeEvidence(env, {
      showTitle: "Example Show",
      detectedDialogue: "Ron Hextall just scored the final goal for us",
      visualEvidence: ["A hockey game ends with a goalie scoring."],
      captionEvidence: "",
      candidateSeason: null,
      candidateEpisode: null,
    }, {
      fetcher: guideFetcher,
      searcher: async () => [],
      verifier: async () => ({
        verified: true,
        seasonNumber: 99,
        episodeNumber: 99,
        episodeTitle: "Invented Episode",
        evidence: "Model memory",
        confidence: 0.99,
      }),
    });

    expect(result.verified).toBe(false);
    expect(result.episodeTitle).toBeNull();
  });
});
