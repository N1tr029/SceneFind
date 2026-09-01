import { afterEach, describe, expect, it, vi } from "vitest";
import {
  evidenceParts,
  hasRemoteYouTubeVideo,
  parseTimedCaptions,
  parseWebVTT,
  retrieveEvidence,
  tiktokDurationSeconds,
} from "../src/sourceRetrieval";
import type { AnalysisRequest } from "../src/types";

const request: AnalysisRequest = {
  sourceURL: "https://youtu.be/example",
  idempotencyKey: "youtube-regression",
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("retrieveEvidence", () => {
  it("falls back to public TikTok oEmbed evidence when the page is blocked", async () => {
    const thumbnail = new Uint8Array([1, 2, 3]);
    vi.stubGlobal("fetch", vi.fn(async (input: string | URL | Request) => {
      const url = String(input);
      if (url.startsWith("https://www.tiktok.com/oembed")) {
        return Response.json({
          title: "Public clip title",
          author_name: "Public creator",
          thumbnail_url: "https://p16-sign.tiktokcdn-us.com/preview.jpeg",
        });
      }
      if (url === "https://p16-sign.tiktokcdn-us.com/preview.jpeg") {
        return new Response(thumbnail, { headers: { "content-type": "image/jpeg" } });
      }
      return new Response("blocked", { status: 403 });
    }));

    const evidence = await retrieveEvidence({
      sourceURL: "https://www.tiktok.com/t/example/",
      idempotencyKey: "blocked-tiktok-page",
    });

    expect(evidence.title).toBe("Public clip title");
    expect(evidence.author).toBe("Public creator");
    expect(evidence.thumbnailMimeType).toBe("image/jpeg");
    expect(evidence.thumbnailDataBase64).toBe("AQID");
  });
});

describe("evidenceParts", () => {
  it("passes a resolved public YouTube URL as video evidence", () => {
    const evidence = {
      finalURL: "https://www.youtube.com/watch?v=example",
      title: "Public clip",
    };

    expect(hasRemoteYouTubeVideo(evidence)).toBe(true);
    expect(evidenceParts(request, evidence)).toContainEqual({
      fileData: { fileUri: evidence.finalURL },
    });
  });

  it("prefers retrieved media bytes over a duplicate remote video", () => {
    const evidence = {
      finalURL: "https://www.youtube.com/watch?v=example",
      mediaDataBase64: "dmlkZW8=",
      mediaMimeType: "video/mp4",
    };

    expect(hasRemoteYouTubeVideo(evidence)).toBe(false);
    expect(evidenceParts(request, evidence)).toContainEqual({
      inlineData: { data: evidence.mediaDataBase64, mimeType: evidence.mediaMimeType },
    });
    expect(evidenceParts(request, evidence)).not.toContainEqual({
      fileData: { fileUri: evidence.finalURL },
    });
  });

  it("does not send arbitrary remote URLs to the provider as fileData", () => {
    const evidence = { finalURL: "https://example.com/video" };

    expect(hasRemoteYouTubeVideo(evidence)).toBe(false);
    expect(evidenceParts(request, evidence)).toHaveLength(1);
  });
});

describe("parseWebVTT", () => {
  it("retains local cue timing needed for canonical timeline alignment", () => {
    const cues = parseWebVTT(`WEBVTT

00:00:04.700 --> 00:00:07.620
What happened here?

00:01:02.077 --> 00:01:03.059
I am not scared of you.
`);

    expect(cues).toEqual([
      { startSeconds: 4.7, endSeconds: 7.62, text: "What happened here?" },
      { startSeconds: 62.077, endSeconds: 63.059, text: "I am not scared of you." },
    ]);
  });
});

describe("parseTimedCaptions", () => {
  it("parses TikTok's JSON utterance caption format", () => {
    const cues = parseTimedCaptions(JSON.stringify({ utterances: [
      { text: "You are beaten down.", start_time: 1_924, end_time: 3_386 },
      { text: "You will get through this.", start_time: 3_760, end_time: 5_159 },
    ] }));

    expect(cues).toEqual([
      { startSeconds: 1.924, endSeconds: 3.386, text: "You are beaten down." },
      { startSeconds: 3.76, endSeconds: 5.159, text: "You will get through this." },
    ]);
  });
});

describe("tiktokDurationSeconds", () => {
  it("uses the midpoint of TikTok's truncated integer duration", () => {
    expect(tiktokDurationSeconds('{"duration":59}')).toBe(59.5);
  });

  it("preserves a precise fractional duration when one is available", () => {
    expect(tiktokDurationSeconds('{"duration":59.835}')).toBe(59.835);
  });
});
