import { describe, expect, it } from "vitest";
import { parseGroqSegments, transcriptionRequest } from "../src/providers/groqTranscription";
import type { Env } from "../src/types";

describe("parseGroqSegments", () => {
  it("keeps usable timed speech and rejects low-confidence noise", () => {
    expect(parseGroqSegments([
      { start: 1.2, end: 3.8, text: "  Exact dialogue here.  ", avg_logprob: -0.2, no_speech_prob: 0.01 },
      { start: 4, end: 5, text: "noise", avg_logprob: -2, no_speech_prob: 0.1 },
      { start: 6, end: 7, text: "silence", avg_logprob: -0.1, no_speech_prob: 0.9 },
    ])).toEqual([{ startSeconds: 1.2, endSeconds: 3.8, text: "Exact dialogue here." }]);
  });
});

describe("transcriptionRequest", () => {
  const env = { GROQ_TRANSCRIPTION_MODEL: "whisper-large-v3-turbo" } as unknown as Env;

  it("uploads media as multipart with an extension Groq can read", async () => {
    const request = transcriptionRequest(env, {
      mediaDataBase64: btoa("fake-bytes"),
      mediaMimeType: "video/quicktime",
    });
    const file = request?.body.get("file") as File;
    expect(file.name).toBe("clip.mp4");
    expect(request?.body.get("model")).toBe("whisper-large-v3-turbo");
    expect(request?.body.get("response_format")).toBe("verbose_json");
  });

  it("sends a remote media URL as a form field, not JSON", () => {
    const request = transcriptionRequest(env, { mediaURL: "https://cdn.example/clip.mp4" });
    expect(request?.body).toBeInstanceOf(FormData);
    expect(request?.body.get("url")).toBe("https://cdn.example/clip.mp4");
    expect(request?.headers).toEqual({});
  });

  it("returns nothing when there is no media", () => {
    expect(transcriptionRequest(env, {})).toBeNull();
  });
});
