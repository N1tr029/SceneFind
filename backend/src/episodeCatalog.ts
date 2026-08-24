const TVMAZE_ORIGIN = "https://api.tvmaze.com";

export interface EpisodeCatalogMatch {
  showTitle: string;
  seasonNumber: number;
  episodeNumber: number;
  episodeTitle: string;
  sourceURL: string;
}

export interface EpisodeCatalogEntry {
  seasonNumber: number;
  episodeNumber: number;
  episodeTitle: string;
  summary: string;
  sourceURL: string;
}

export interface EpisodeGuide {
  showTitle: string;
  sourceURL: string;
  episodes: EpisodeCatalogEntry[];
}

interface TVMazeEpisode {
  name?: string | null;
  season?: number | null;
  number?: number | null;
  url?: string | null;
  summary?: string | null;
}

interface TVMazeShow {
  name?: string | null;
  url?: string | null;
  _embedded?: { episodes?: TVMazeEpisode[] };
}

export async function resolveEpisodeMetadata(options: {
  showTitle: string;
  episodeTitle: string;
  fetcher?: typeof fetch;
}): Promise<EpisodeCatalogMatch | null> {
  const guide = await fetchEpisodeGuide(options);
  if (!guide) return null;
  const expectedEpisode = normalized(options.episodeTitle);
  const matches = guide.episodes.filter((episode) => {
    const candidate = normalized(episode.episodeTitle);
    return candidate === expectedEpisode ||
      stripPartSuffix(candidate) === expectedEpisode ||
      candidate === stripPartSuffix(expectedEpisode);
  });
  // Episode names such as "Stress Relief (1)" and "Stress Relief (2)"
  // deliberately remain unresolved when the dialogue index supplies only the
  // shared base title. Guessing the part would corrupt season/episode accuracy.
  if (matches.length !== 1) return null;
  const episode = matches[0];
  return {
    showTitle: guide.showTitle,
    seasonNumber: episode.seasonNumber,
    episodeNumber: episode.episodeNumber,
    episodeTitle: episode.episodeTitle,
    sourceURL: episode.sourceURL,
  };
}

export async function fetchEpisodeGuide(options: {
  showTitle: string;
  fetcher?: typeof fetch;
}): Promise<EpisodeGuide | null> {
  const fetcher = options.fetcher ?? fetch;
  const url = new URL("/singlesearch/shows", TVMAZE_ORIGIN);
  url.searchParams.set("q", options.showTitle);
  url.searchParams.set("embed", "episodes");
  let response: Response;
  try {
    response = await fetcher(url, {
      headers: { "user-agent": "SceneFind/1.0 (episode metadata via TVMaze)" },
      signal: AbortSignal.timeout(8_000),
    });
  } catch {
    return null;
  }
  if (!response.ok) return null;
  let show: TVMazeShow;
  try {
    show = await response.json() as TVMazeShow;
  } catch {
    return null;
  }
  if (!show.name || !equivalentTitle(show.name, options.showTitle)) return null;
  const showURL = safeTVMazeURL(show.url);
  if (!showURL) return null;
  const episodes = (show._embedded?.episodes ?? []).flatMap((episode): EpisodeCatalogEntry[] => {
    if (!Number.isSafeInteger(episode.season) || !Number.isSafeInteger(episode.number) || !episode.name) {
      return [];
    }
    const sourceURL = safeTVMazeURL(episode.url) ?? showURL;
    return [{
      seasonNumber: episode.season!,
      episodeNumber: episode.number!,
      episodeTitle: episode.name,
      summary: plainText(episode.summary ?? ""),
      sourceURL,
    }];
  });
  if (episodes.length === 0) return null;
  return {
    showTitle: show.name,
    sourceURL: showURL,
    episodes,
  };
}

function equivalentTitle(left: string, right: string): boolean {
  const lhs = normalized(left);
  const rhs = normalized(right);
  return Boolean(lhs && rhs && (lhs === rhs || lhs.includes(rhs) || rhs.includes(lhs)));
}

function normalized(value: string): string {
  return value
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function stripPartSuffix(value: string): string {
  return value.replace(/\s+(?:part\s*)?\d+$/, "").trim();
}

function plainText(value: string): string {
  return value.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
}

function safeTVMazeURL(value?: string | null): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    return (url.protocol === "https:" && (url.hostname === "tvmaze.com" || url.hostname.endsWith(".tvmaze.com")))
      ? url.toString()
      : null;
  } catch {
    return null;
  }
}
