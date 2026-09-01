import { describe, expect, it } from "vitest";
import { isExactEpisodeRoute, knowledgeLinks, verifyCandidates, type WatchLinkQuery } from "../src/watchLinks";

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

describe("Google knowledge-panel watch links", () => {
  // Netflix answers an unauthenticated fetch of /watch/<id> with a page whose
  // only title is "Netflix" — the show name is absent — so pageConfirms can
  // never confirm one. Hulu hides episodes behind an opaque uuid the same way.
  // Google's "Watch episode" panel already carries those exact ids, so panel
  // links are taken on trust rather than verified.
  it("accepts opaque Netflix and Hulu episode ids without page verification", () => {
    const links = knowledgeLinks(
      [
        { url: "https://www.netflix.com/watch/81647019?source=35", label: "Netflix" },
        { url: "https://www.hulu.com/watch/56a33b2c-a28b-4f4b-8daf-2892e627ca6c", label: "Hulu" },
      ],
      query,
    );
    expect(links.map((link) => link.service)).toEqual(["netflix", "hulu"]);
    expect(links[0].url).toContain("/watch/81647019");
  });

  it("drops a show-level page, another country's storefront, and duplicates", () => {
    const links = knowledgeLinks(
      [
        { url: "https://www.netflix.com/title/80057281", label: "Netflix" },
        { url: "https://www.netflix.com/gb/watch/81647019", label: "Netflix" },
        { url: "https://www.netflix.com/watch/81647019", label: "Netflix" },
        { url: "https://www.netflix.com/watch/99999999", label: "Netflix" },
        { url: "https://example.com/watch/1", label: "Not a provider" },
      ],
      query,
    );
    expect(links).toHaveLength(1);
    expect(links[0].url).toBe("https://www.netflix.com/watch/81647019");
  });
});

describe("real provider episode routes from live Google panels", () => {
  // Every URL below was taken from an actual Google "Watch episode" panel.
  // Three of them were rejected by the original matcher: Disney+ uses /play/
  // not /video/, Max uses /show/<id>/s1/e1-<slug>/ not /video/watch/, and
  // Prime Video uses a bare /detail/<asin>.
  const cases: Array<[string, string]> = [
    ["netflix", "https://www.netflix.com/watch/81647019?source=35"],
    ["appleTV", "https://tv.apple.com/us/episode/the-swell/umc.cmc.44rnarngjcje0p7z2f9kllg9j"],
    ["hulu", "https://www.hulu.com/watch/dc76449b-6e42-407a-86e3-7576e4e328c8"],
    ["disneyPlus", "https://www.disneyplus.com/play/dc76449b-6e42-407a-86e3-7576e4e328c8"],
    ["paramountPlus", "https://www.paramountplus.com/shows/video/2063731264/"],
    ["peacock", "https://www.peacocktv.com/watch-online/tv/the-office/4902514835143843112/seasons/3/episodes/gay-witch-hunt-episode-1/6c15523f-edde-39b7-892a-d9db50dd020a"],
    ["primeVideo", "https://www.primevideo.com/detail/0S1FYJ3LY9KTL9C7WFFAGA9F6F"],
    ["max", "https://www.hbomax.com/show/a8484031-f244-4661-9fb7-0932bd1ba872/s1/e1-celebration/e457df99-f817-4646-b64c-8ce7afaeb405"],
  ];

  for (const [service, url] of cases) {
    it(`keeps the ${service} episode link`, () => {
      const links = knowledgeLinks([{ url, label: service }], query);
      expect(links).toHaveLength(1);
      expect(links[0].service).toBe(service);
    });
  }

  it("still drops show-level pages and other storefronts", () => {
    const links = knowledgeLinks(
      [
        { url: "https://www.netflix.com/title/80236318", label: "Netflix" },
        { url: "https://tv.apple.com/us/show/ted-lasso/umc.cmc.vtoh0mn0xn7t3c643xqonfzy", label: "Apple TV" },
        { url: "https://tv.apple.com/pl/episode/celebration/umc.cmc.4ytb59nu54zq28hytjfpqihr5", label: "Apple TV" },
      ],
      query,
    );
    expect(links).toHaveLength(0);
  });
});
