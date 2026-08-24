import { describe, expect, it } from "vitest";
import { resolveEpisodeMetadata } from "../src/episodeCatalog";

describe("resolveEpisodeMetadata", () => {
  it("maps an independently matched episode title to season and episode", async () => {
    const result = await resolveEpisodeMetadata({
      showTitle: "Wizards of Waverly Place",
      episodeTitle: "Misfortune at the Beach",
      fetcher: (async () => Response.json({
        name: "Wizards of Waverly Place",
        url: "https://www.tvmaze.com/shows/123/wizards-of-waverly-place",
        _embedded: {
          episodes: [{
            name: "Misfortune at the Beach",
            season: 4,
            number: 16,
            url: "https://www.tvmaze.com/episodes/456/misfortune-at-the-beach",
          }],
        },
      })) as typeof fetch,
    });

    expect(result).toEqual({
      showTitle: "Wizards of Waverly Place",
      seasonNumber: 4,
      episodeNumber: 16,
      episodeTitle: "Misfortune at the Beach",
      sourceURL: "https://www.tvmaze.com/episodes/456/misfortune-at-the-beach",
    });
  });

  it("refuses an ambiguous multi-part episode title", async () => {
    const result = await resolveEpisodeMetadata({
      showTitle: "The Office",
      episodeTitle: "Stress Relief",
      fetcher: (async () => Response.json({
        name: "The Office",
        url: "https://www.tvmaze.com/shows/1/the-office",
        _embedded: {
          episodes: [
            { name: "Stress Relief (1)", season: 5, number: 14, url: "https://www.tvmaze.com/episodes/1/a" },
            { name: "Stress Relief (2)", season: 5, number: 15, url: "https://www.tvmaze.com/episodes/2/b" },
          ],
        },
      })) as typeof fetch,
    });

    expect(result).toBeNull();
  });
});
