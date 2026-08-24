import { describe, expect, it } from "vitest";
import { parseGroqSegments } from "../src/providers/groqTranscription";

describe("parseGroqSegments", () => {
  it("keeps usable timed speech and rejects low-confidence noise", () => {
    expect(parseGroqSegments([
      { start: 1.2, end: 3.8, text: "  Exact dialogue here.  ", avg_logprob: -0.2, no_speech_prob: 0.01 },
      { start: 4, end: 5, text: "noise", avg_logprob: -2, no_speech_prob: 0.1 },
      { start: 6, end: 7, text: "silence", avg_logprob: -0.1, no_speech_prob: 0.9 },
    ])).toEqual([{ startSeconds: 1.2, endSeconds: 3.8, text: "Exact dialogue here." }]);
  });
});
