import { describe, expect, it } from "vitest";
import { fetchReferenceTrack, parseSubRip } from "../src/providers/openSubtitles";
import { resolveSceneTimelineFromReference } from "../src/timestampResolver";
import type { TranscriptCue } from "../src/sourceRetrieval";
import type { Env } from "../src/types";

class FakeKV {
  readonly values = new Map<string, string>();
  puts = 0;

  async get(key: string, type?: string): Promise<unknown> {
    const value = this.values.get(key);
    if (value === undefined) return null;
    return type === "json" ? JSON.parse(value) : value;
  }

  async put(key: string, value: string): Promise<void> {
    this.puts += 1;
    this.values.set(key, value);
  }
}

const SRT = `1
00:00:01,000 --> 00:00:03,000
<i>What do you guys get up to</i>
today at school?

2
00:00:04,500 --> 00:00:06,000
{\\an8}I saw my mom.

3
00:00:07,000 --> 00:00:09,250
I understand, Nikki, that you
were upset about it.
`;

describe("parseSubRip", () => {
  it("reads timings and strips styling, positioning, and line breaks", () => {
    const cues = parseSubRip(SRT);
    expect(cues).toHaveLength(3);
    expect(cues[0]).toEqual({
      startSeconds: 1,
      endSeconds: 3,
      text: "What do you guys get up to today at school?",
    });
    expect(cues[1].text).toBe("I saw my mom.");
    expect(cues[2].startSeconds).toBeCloseTo(7, 3);
    expect(cues[2].endSeconds).toBeCloseTo(9.25, 3);
  });

  it("ignores blocks without a usable timing line", () => {
    expect(parseSubRip("1\nnot a timing\nsome text\n")).toEqual([]);
    expect(parseSubRip("1\n00:00:05,000 --> 00:00:01,000\nbackwards\n")).toEqual([]);
  });
});

describe("resolveSceneTimelineFromReference", () => {
  // A clip lifted from 40 minutes into the feature: the same lines, shifted.
  const offset = 2_400;
  const reference: TranscriptCue[] = [
    { startSeconds: 12, endSeconds: 14, text: "Something else entirely." },
    {
      startSeconds: offset + 1,
      endSeconds: offset + 3,
      text: "What do you guys get up to today at school?",
    },
    { startSeconds: offset + 4.5, endSeconds: offset + 6, text: "I saw my mom." },
    {
      startSeconds: offset + 7,
      endSeconds: offset + 9.25,
      text: "I understand, Nikki, that you were upset about it.",
    },
  ];

  const clip: TranscriptCue[] = [
    { startSeconds: 1, endSeconds: 3, text: "What do you guys get up to today at school" },
    { startSeconds: 7, endSeconds: 9.25, text: "I understand Nikki that you were upset about it" },
  ];

  it("recovers the clip's position in the full runtime", () => {
    const result = resolveSceneTimelineFromReference({
      cues: clip,
      referenceCues: reference,
      durationSeconds: 10,
      canonicalTitle: "A Simple Favor",
    });

    expect(result).not.toBeNull();
    expect(result?.canonicalTitle).toBe("A Simple Favor");
    expect(result?.startSeconds).toBeCloseTo(offset, 0);
    expect(result?.endSeconds).toBeCloseTo(offset + 10, 0);
    expect(result?.anchorCount).toBeGreaterThanOrEqual(2);
  });

  it("refuses when the clip's dialogue is not in the reference", () => {
    expect(resolveSceneTimelineFromReference({
      cues: [
        { startSeconds: 1, endSeconds: 4, text: "Completely unrelated words spoken here today" },
        { startSeconds: 6, endSeconds: 9, text: "Nothing in this track resembles that line" },
      ],
      referenceCues: reference,
      durationSeconds: 10,
      canonicalTitle: "A Simple Favor",
    })).toBeNull();
  });

  it("refuses without a reference track rather than guessing", () => {
    expect(resolveSceneTimelineFromReference({
      cues: clip,
      referenceCues: [],
      durationSeconds: 10,
      canonicalTitle: "A Simple Favor",
    })).toBeNull();
  });
});

describe("fetchReferenceTrack", () => {
  function makeEnv(kv: FakeKV, key = "os-key"): Env {
    return {
      OPENSUBTITLES_API_KEY: key,
      SUBTITLES: kv,
    } as unknown as Env;
  }

  function searchAndDownload(srt: string): typeof fetch {
    return (async (input: RequestInfo | URL) => {
      const url = String(input instanceof Request ? input.url : input);
      if (url.includes("/subtitles?")) {
        return Response.json({ data: [
          { attributes: { download_count: 10, from_trusted: false, files: [{ file_id: 1 }] } },
          { attributes: { download_count: 900, from_trusted: true, files: [{ file_id: 42 }] } },
        ] });
      }
      if (url.endsWith("/download")) return Response.json({ link: "https://dl.example/42.srt" });
      return new Response(srt);
    }) as typeof fetch;
  }

  const longTrack = Array.from({ length: 30 }, (_, index) =>
    `${index + 1}\n00:00:${String(index * 2).padStart(2, "0")},000 --> ` +
    `00:00:${String(index * 2 + 1).padStart(2, "0")},000\nLine number ${index}\n`).join("\n");

  it("downloads once and serves the cached track afterwards", async () => {
    const kv = new FakeKV();
    const env = makeEnv(kv);
    let downloads = 0;
    const fetcher = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/download")) downloads += 1;
      return searchAndDownload(longTrack)(input);
    }) as typeof fetch;

    const first = await fetchReferenceTrack(env, { title: "A Simple Favor", year: 2018 }, fetcher);
    const second = await fetchReferenceTrack(env, { title: "A Simple Favor", year: 2018 }, fetcher);

    expect(first).toHaveLength(30);
    expect(second).toHaveLength(30);
    expect(downloads).toBe(1);
  });

  it("skips a same-name release from the wrong year", async () => {
    const kv = new FakeKV();
    const fetcher = (async () => Response.json({ data: [
      { attributes: { download_count: 9_000, feature_details: { year: 1994 }, files: [{ file_id: 7 }] } },
    ] })) as typeof fetch;
    expect(await fetchReferenceTrack(makeEnv(kv), { title: "The Favor", year: 2018 }, fetcher))
      .toBeNull();
  });

  it("remembers a title the index does not carry", async () => {
    const kv = new FakeKV();
    const fetcher = (async () => Response.json({ data: [] })) as typeof fetch;
    expect(await fetchReferenceTrack(makeEnv(kv), { title: "Unindexed" }, fetcher)).toBeNull();
    expect(kv.puts).toBe(1);
    // Cached as a definite miss, so the next clip spends no download quota.
    expect(await fetchReferenceTrack(makeEnv(kv), { title: "Unindexed" }, fetcher)).toBeNull();
    expect(kv.puts).toBe(1);
  });

  it("does not cache a transient failure as a missing title", async () => {
    const kv = new FakeKV();
    const fetcher = (async () => new Response("", { status: 503 })) as typeof fetch;
    expect(await fetchReferenceTrack(makeEnv(kv), { title: "Flaky" }, fetcher)).toBeNull();
    expect(kv.puts).toBe(0);
  });

  it("stays inert until the API key is configured", async () => {
    const kv = new FakeKV();
    const env = { SUBTITLES: kv } as unknown as Env;
    let called = false;
    const fetcher = (async () => { called = true; return Response.json({ data: [] }); }) as typeof fetch;
    expect(await fetchReferenceTrack(env, { title: "Anything" }, fetcher)).toBeNull();
    expect(called).toBe(false);
  });
});
