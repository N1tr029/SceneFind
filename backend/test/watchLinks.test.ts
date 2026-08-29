import { describe, expect, it } from "vitest";
import { isExactEpisodeRoute, verifyCandidates, type WatchLinkQuery } from "../src/watchLinks";

const query: WatchLinkQuery = {
  title: "All American",
  mediaType: "tv",
  seasonNumber: 8,
  episodeNumber: 1,
  episodeTitle: "The First Time",
  region: "US",
};

describe("Netflix exact episode resolution", () => {
  it("tries later Netflix watch ids when the first result is the wrong episode", async () => {
    const results = [
      {
        url: "https://www.netflix.com/watch/11111111",
        title: "Random Special | Netflix",
        snippet: "A different title",
      },
      {
        url: "https://www.netflix.com/watch/81012998",
        title: "The First Time - All American | Netflix",
        snippet: "Season 8 episode 1",
      },
    ];
    const links = await verifyCandidates(results, query, (async (input: RequestInfo | URL) => {
      const url = new URL(String(input));
      const title = url.pathname.endsWith("81012998")
        ? "The First Time - All American (Season 8, Episode 1) | Netflix"
        : "Random Comedy Special | Netflix";
      return new Response(`<meta property="og:title" content="${title}">`, {
        status: 200,
        headers: { "content-type": "text/html" },
      });
    }) as typeof fetch);

    expect(links).toHaveLength(1);
    expect(links[0].url).toBe("https://www.netflix.com/watch/81012998");
  });

  it("uses exact indexed Netflix metadata when its login shell cannot be scraped", async () => {
    const links = await verifyCandidates([{
      url: "https://www.netflix.com/watch/81012998",
      title: "The First Time - All American | Netflix",
      snippet: "Watch All American season 8 episode 1",
    }], query, (async () => new Response("login required", { status: 403 })) as typeof fetch);

    expect(links[0]?.url).toBe("https://www.netflix.com/watch/81012998");
  });

  it("never labels a Netflix title page as an exact TV episode", () => {
    expect(isExactEpisodeRoute(new URL("https://www.netflix.com/title/80057281"), "netflix"))
      .toBe(false);
    expect(isExactEpisodeRoute(new URL("https://www.netflix.com/watch/81012998"), "netflix"))
      .toBe(true);
  });
});
