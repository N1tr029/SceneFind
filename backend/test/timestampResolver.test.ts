import { describe, expect, it } from "vitest";
import { resolveSceneTimeline, searchablePhrases, titlesMatch } from "../src/timestampResolver";
import type { TranscriptCue } from "../src/sourceRetrieval";

const cues: TranscriptCue[] = [
  {
    startSeconds: 26.18,
    endSeconds: 29.76,
    text: "Okay, I had to have made some kind of a dent by now.",
  },
  {
    startSeconds: 35.94,
    endSeconds: 39.24,
    text: "What a bunch of whiners. This is gonna suck up my whole life.",
  },
  {
    startSeconds: 49.54,
    endSeconds: 52.48,
    text: "There you go. Now everybody is happy.",
  },
];

describe("resolveSceneTimeline", () => {
  it("uses consistent dialogue offsets to measure the original clip window", async () => {
    const canonicalOffset = 3_562.1;
    const result = await resolveSceneTimeline({
      cues,
      durationSeconds: 52,
      expectedTitle: "Bruce Almighty",
      fetcher: (async (input: RequestInfo | URL) => {
        const url = new URL(String(input));
        const phrase = decodeURIComponent(url.pathname.replace(/^\/search\//, ""));
        const localStart = phrase.includes("made some kind")
          ? 26.18
          : phrase.includes("bunch of whiners")
            ? 35.94
            : 49.54;
        return Response.json({ docs: [{
          title: "Bruce Almighty",
          serie: null,
          phrase,
          time: Math.round((canonicalOffset + localStart) * 1_000),
        }] });
      }) as typeof fetch,
    });

    expect(result).not.toBeNull();
    expect(result?.canonicalTitle).toBe("Bruce Almighty");
    expect(result?.anchorCount).toBeGreaterThanOrEqual(2);
    expect(result?.startSeconds).toBeCloseTo(canonicalOffset, 1);
    expect(result?.endSeconds).toBeCloseTo(canonicalOffset + 52, 1);
    expect(result?.maximumAnchorDeviationSeconds).toBeLessThan(0.1);
  });

  it("does not claim a transcript-only title from one ambiguous anchor", async () => {
    const result = await resolveSceneTimeline({
      cues: cues.slice(0, 1),
      durationSeconds: 30,
      fetcher: (async () => Response.json({ docs: [{
        title: "Wrong Movie",
        phrase: cues[0].text,
        time: 1_000_000,
      }] })) as typeof fetch,
    });

    expect(result).toBeNull();
  });

  it("rejects one title-scoped anchor when too much of the clip end is unverified", async () => {
    const result = await resolveSceneTimeline({
      cues: cues.slice(0, 1),
      durationSeconds: 60,
      expectedTitle: "Bruce Almighty",
      fetcher: (async () => Response.json({ docs: [{
        title: "Bruce Almighty",
        phrase: cues[0].text,
        time: 1_026_180,
      }] })) as typeof fetch,
    });

    expect(result).toBeNull();
  });

  it("rejects multiple early anchors when the clip ending is not covered", async () => {
    const earlyCues = cues.slice(0, 2).map((cue, index) => ({
      ...cue,
      startSeconds: index * 6,
      endSeconds: index * 6 + 3,
    }));
    const result = await resolveSceneTimeline({
      cues: earlyCues,
      durationSeconds: 80,
      expectedTitle: "Bruce Almighty",
      fetcher: (async (input: RequestInfo | URL) => {
        const phrase = decodeURIComponent(new URL(String(input)).pathname.replace(/^\/search\//, ""));
        const cue = earlyCues.find((item) => item.text === phrase);
        return Response.json({ docs: cue ? [{
          title: "Bruce Almighty",
          phrase,
          time: (1_000 + cue.startSeconds) * 1_000,
        }] : [] });
      }) as typeof fetch,
    });

    expect(result).toBeNull();
  });

  it("never combines dialogue anchors from different episodes", async () => {
    const episodeCues: TranscriptCue[] = [
      { startSeconds: 0, endSeconds: 3, text: "First distinctive sentence has enough words to search safely" },
      { startSeconds: 6, endSeconds: 9, text: "Second distinctive sentence also has enough words to search safely" },
    ];
    const result = await resolveSceneTimeline({
      cues: episodeCues,
      durationSeconds: 20,
      expectedTitle: "Example Show",
      fetcher: (async (input: RequestInfo | URL) => {
        const phrase = decodeURIComponent(new URL(String(input)).pathname.replace(/^\/search\//, ""));
        const index = episodeCues.findIndex((cue) => cue.text === phrase);
        return Response.json({ docs: index < 0 ? [] : [{
          title: index === 0 ? "Episode Alpha" : "Episode Beta",
          serie: "Example Show",
          phrase,
          time: (1_000 + episodeCues[index].startSeconds) * 1_000,
        }] });
      }) as typeof fetch,
    });

    expect(result).toBeNull();
  });

  it("allows one high-similarity anchor within eight seconds of the clip end", async () => {
    const endingCue = { ...cues[0], startSeconds: 51, endSeconds: 54 };
    const result = await resolveSceneTimeline({
      cues: [endingCue],
      durationSeconds: 60,
      expectedTitle: "Bruce Almighty",
      fetcher: (async () => Response.json({ docs: [{
        title: "Bruce Almighty",
        phrase: endingCue.text,
        time: 1_051_000,
      }] })) as typeof fetch,
    });

    expect(result?.anchorCount).toBe(1);
    expect(result?.endExtrapolationSeconds).toBe(6);
    expect(result?.endSeconds).toBe(1_060);
  });

  it("retries one transient dialogue-index failure", async () => {
    const endingCue = { ...cues[0], startSeconds: 51, endSeconds: 54 };
    let calls = 0;
    const result = await resolveSceneTimeline({
      cues: [endingCue],
      durationSeconds: 60,
      expectedTitle: "Bruce Almighty",
      fetcher: (async () => {
        calls += 1;
        return calls === 1
          ? new Response(null, { status: 503 })
          : Response.json({ docs: [{
              title: "Bruce Almighty",
              phrase: endingCue.text,
              time: 1_051_000,
            }] });
      }) as typeof fetch,
    });

    expect(calls).toBe(2);
    expect(result?.endSeconds).toBe(1_060);
  });

  it("recovers exact anchors from bounded windows when auto-captions add noise", async () => {
    const noisyCues: TranscriptCue[] = [
      {
        startSeconds: 4.76,
        endSeconds: 8.6,
        text: "Pam line three okay thanks New York as it turns out",
      },
      {
        startSeconds: 14.44,
        endSeconds: 17.7,
        text: "but Michael offered to get me a part time job at corporate",
      },
    ];
    const result = await resolveSceneTimeline({
      cues: noisyCues,
      durationSeconds: 37,
      expectedTitle: "The Office",
      fetcher: (async (input: RequestInfo | URL) => {
        const query = decodeURIComponent(new URL(String(input)).pathname.replace(/^\/search\//, ""));
        if (query === "New York as it turns out") {
          return Response.json({ docs: [{
            title: "Crime Aid",
            serie: "The Office",
            phrase: "New York, as it turns out, is very expensive.",
            time: 8_600,
          }] });
        }
        if (query === "but Michael offered to get me") {
          return Response.json({ docs: [{
            title: "Crime Aid",
            serie: "The Office",
            phrase: "But Michael offered to get me a part-time job at corporate.",
            time: 15_700,
          }] });
        }
        return Response.json({ docs: [] });
      }) as typeof fetch,
    });

    expect(result?.canonicalTitle).toBe("The Office");
    expect(result?.episodeTitle).toBe("Crime Aid");
    expect(result?.anchorCount).toBe(2);
    expect(result?.maximumAnchorDeviationSeconds).toBeLessThan(2);
  });

  it("uses the latest three anchors for the clip-ending moment", async () => {
    const endpointCues: TranscriptCue[] = Array.from({ length: 4 }, (_, index) => ({
      startSeconds: index * 10,
      endSeconds: index * 10 + 3,
      text: `Endpoint dialogue number ${index} contains enough distinctive words to search`,
    }));
    const offsets = [100, 100, 102, 103];
    const result = await resolveSceneTimeline({
      cues: endpointCues,
      durationSeconds: 35,
      expectedTitle: "Example Movie",
      fetcher: (async (input: RequestInfo | URL) => {
        const phrase = decodeURIComponent(new URL(String(input)).pathname.replace(/^\/search\//, ""));
        const index = endpointCues.findIndex((cue) => cue.text === phrase);
        return Response.json({ docs: index < 0 ? [] : [{
          title: "Example Movie",
          phrase,
          time: (endpointCues[index].startSeconds + offsets[index]) * 1_000,
        }] });
      }) as typeof fetch,
    });

    expect(result?.startSeconds).toBe(101);
    expect(result?.tailOffsetSeconds).toBe(102);
    expect(result?.endSeconds).toBe(137);
    expect(result?.heldOutEndAnchorErrorSeconds).toBe(3);
  });

  it("rejects an ending anchor that misses the earlier alignment by over four seconds", async () => {
    const endpointCues: TranscriptCue[] = Array.from({ length: 4 }, (_, index) => ({
      startSeconds: index * 10,
      endSeconds: index * 10 + 3,
      text: `Discontinuous dialogue number ${index} contains enough distinctive words to search`,
    }));
    const offsets = [96, 96, 98, 100.3];
    const result = await resolveSceneTimeline({
      cues: endpointCues,
      durationSeconds: 35,
      expectedTitle: "Example Movie",
      fetcher: (async (input: RequestInfo | URL) => {
        const phrase = decodeURIComponent(new URL(String(input)).pathname.replace(/^\/search\//, ""));
        const index = endpointCues.findIndex((cue) => cue.text === phrase);
        return Response.json({ docs: index < 0 ? [] : [{
          title: "Example Movie",
          phrase,
          time: (endpointCues[index].startSeconds + offsets[index]) * 1_000,
        }] });
      }) as typeof fetch,
    });

    expect(result).toBeNull();
  });
});

describe("timestamp phrase selection", () => {
  it("keeps distinctive phrases distributed across the clip", () => {
    const phrases = searchablePhrases(cues);
    expect(phrases.length).toBeGreaterThanOrEqual(2);
    expect(phrases[0].startSeconds).toBeLessThan(phrases.at(-1)!.startSeconds);
  });

  it("reserves query coverage near the end of a long clip", () => {
    const longCues = Array.from({ length: 24 }, (_, index) => ({
      startSeconds: index * 60,
      endSeconds: index * 60 + 4,
      text: `Distinctive dialogue sentence number ${index} contains enough searchable words`,
    }));
    const phrases = searchablePhrases(longCues);

    expect(phrases).toHaveLength(8);
    expect(phrases.at(-1)!.startSeconds).toBeGreaterThanOrEqual(1_200);
  });

  it("normalizes punctuation and subtitles in title comparisons", () => {
    expect(titlesMatch("Spider-Man: No Way Home", "Spider Man No Way Home")).toBe(true);
  });
});
