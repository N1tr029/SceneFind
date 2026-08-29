import { describe, expect, it } from "vitest";
import { searchWeb } from "../src/webSearch";

describe("searchWeb result URL normalization", () => {
  it("decodes double-escaped query delimiters before transcript fetching", async () => {
    const results = await searchWeb({
      apiKey: "BSA-test",
      query: "episode transcript",
      fetcher: (async () => Response.json({ web: { results: [{
        url: "https://example.com/script?nav\\u003dscript\\u0026episode\\u003d16",
        title: "Episode transcript",
        description: "Dialogue",
      }] } })) as typeof fetch,
    });

    expect(results[0].url).toBe("https://example.com/script?nav=script&episode=16");
  });
});
