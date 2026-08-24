import type { TranscriptCue } from "./sourceRetrieval";
import type { Env } from "./types";
import { fetchEpisodeGuide, type EpisodeCatalogEntry } from "./episodeCatalog";
import { verifyEpisode, type EpisodeVerification } from "./providers/groq";
import { searchablePhrases } from "./timestampResolver";
import { searchWeb, type WebSearchResult } from "./webSearch";

interface EpisodeCoordinate { season: number; episode: number }

interface SearchSupport extends EpisodeCoordinate {
  episodeTitle: string;
  anchor: string;
  sourceURL: string;
  titleMentioned: boolean;
  excerpt: string;
}

export interface EpisodeEvidenceDependencies {
  fetcher?: typeof fetch;
  searcher?: typeof searchWeb;
  verifier?: typeof verifyEpisode;
}

/**
 * Resolves every TV result, even when the identifier did not guess S/E.
 * Social captions generate candidates; quoted transcript search and canonical
 * guide facts decide whether a candidate is allowed to pass.
 */
export async function resolveEpisodeEvidence(
  env: Env,
  args: {
    showTitle: string;
    detectedDialogue: string;
    transcriptCues?: TranscriptCue[];
    visualEvidence: string[];
    captionEvidence: string;
    candidateSeason: number | null;
    candidateEpisode: number | null;
  },
  dependencies: EpisodeEvidenceDependencies = {},
): Promise<EpisodeVerification> {
  const guide = await fetchEpisodeGuide({
    showTitle: args.showTitle,
    fetcher: dependencies.fetcher,
  });
  if (!guide) return unverified("No canonical episode guide was available.");

  const phrases = dialoguePhrases(args.transcriptCues, args.detectedDialogue);
  const searcher = dependencies.searcher ?? searchWeb;
  const batches = await Promise.all(phrases.map(async (anchor) => {
    const results = await searcher({
      apiKey: env.SEARCH_API_KEY,
      query: `"${anchor.replaceAll('"', "")}" "${guide.showTitle}" episode transcript`,
      region: "US",
      fetcher: dependencies.fetcher,
    });
    return searchSupports(results.slice(0, 12), guide.showTitle, anchor, guide.episodes);
  }));
  const captionHints = parseEpisodeCoordinates(args.captionEvidence);
  let supports = deduplicateSupports(batches.flat());
  let deterministic = strongSearchResolution(supports, captionHints, guide.episodes);

  // A caption S/E is not proof, but it gives us a canonical episode title to
  // investigate. Search for that episode's transcript page and verify the
  // social clip's actual dialogue inside the page. This is deterministic
  // evidence and does not require an LLM provider to be online.
  if (!deterministic && phrases.length > 0) {
    const candidateCoordinates = new Set(captionHints);
    if (args.candidateSeason && args.candidateEpisode) {
      candidateCoordinates.add(coordinateKey({
        season: args.candidateSeason,
        episode: args.candidateEpisode,
      }));
    }
    const candidates = guide.episodes.filter((episode) => candidateCoordinates.has(coordinateKey({
      season: episode.seasonNumber,
      episode: episode.episodeNumber,
    }))).slice(0, 3);
    const pageSupports = await Promise.all(candidates.map((episode) =>
      candidateTranscriptSupports({
        episode,
        showTitle: guide.showTitle,
        anchors: phrases,
        apiKey: env.SEARCH_API_KEY,
        searcher,
        fetcher: dependencies.fetcher ?? fetch,
      })
    ));
    supports = deduplicateSupports([...supports, ...pageSupports.flat()]);
    deterministic = strongSearchResolution(supports, captionHints, guide.episodes);
  }

  // Do not make an already-proven result depend on Groq availability. The
  // verifier remains useful only when deterministic sources leave a tie.
  if (deterministic) return deterministic;
  if (!env.GROQ_API_KEY?.trim()) {
    return unverified("Deterministic transcript evidence was insufficient; the optional episode tie-breaker was not configured.");
  }

  const clipEvidence = [args.detectedDialogue, ...args.visualEvidence].join(" ");
  const rankedGuide = shortlistGuide(
    guide.episodes,
    clipEvidence,
    supports,
    captionHints,
    args.candidateSeason,
    args.candidateEpisode,
  );
  const verifier = dependencies.verifier ?? verifyEpisode;
  let model: EpisodeVerification;
  try {
    model = await verifier(env, {
      showTitle: guide.showTitle,
      detectedDialogue: args.detectedDialogue,
      visualEvidence: args.visualEvidence,
      captionClaims: [...captionHints].map(parseCoordinateKey),
      candidateSeason: args.candidateSeason,
      candidateEpisode: args.candidateEpisode,
      episodeGuide: rankedGuide,
      webEvidence: supports.map((support) => ({
        seasonNumber: support.season,
        episodeNumber: support.episode,
        episodeTitle: support.episodeTitle,
        anchor: support.anchor,
        excerpt: support.excerpt,
        sourceURL: support.sourceURL,
      })),
    });
  } catch {
    return unverified("The episode verifier was unavailable and deterministic transcript evidence was insufficient.");
  }

  const canonical = validateModelResolution(model, guide.episodes, supports, clipEvidence, captionHints);
  return canonical ?? unverified(
    "No episode had independent transcript or visual/guide corroboration.",
  );
}

async function candidateTranscriptSupports(options: {
  episode: EpisodeCatalogEntry;
  showTitle: string;
  anchors: string[];
  apiKey?: string;
  searcher: typeof searchWeb;
  fetcher: typeof fetch;
}): Promise<SearchSupport[]> {
  const results = await options.searcher({
    apiKey: options.apiKey,
    query: `"${options.showTitle}" "${options.episode.episodeTitle}" transcript`,
    region: "US",
    fetcher: options.fetcher,
  });
  const expectedShow = normalize(options.showTitle);
  const expectedEpisode = normalize(options.episode.episodeTitle);
  const supports: SearchSupport[] = [];
  for (const result of results.slice(0, 8)) {
    const resultIdentity = normalize(
      `${result.title} ${result.snippet} ${decodeURIComponentSafe(result.url)}`,
    );
    if (!resultIdentity.includes(expectedShow) || !resultIdentity.includes(expectedEpisode)) continue;
    const sourceURL = publicHTTPSURL(result.url);
    if (!sourceURL) continue;
    const page = await fetchTranscriptPage(sourceURL, options.fetcher);
    if (!page) continue;
    const searchable = normalize(`${result.title} ${result.snippet} ${page}`);
    for (const anchor of options.anchors) {
      const anchorTokens = tokens(anchor);
      if (anchorTokens.size < 4) continue;
      const overlap = intersectionSize(anchorTokens, tokens(searchable));
      const exact = searchable.includes(normalize(anchor));
      if (!exact && overlap / anchorTokens.size < 0.75) continue;
      supports.push({
        season: options.episode.seasonNumber,
        episode: options.episode.episodeNumber,
        episodeTitle: options.episode.episodeTitle,
        anchor,
        sourceURL,
        titleMentioned: true,
        excerpt: `${result.title} — full transcript page matched clip dialogue`.slice(0, 600),
      });
    }
    if (distinctAnchors(supports) >= 2) break;
  }
  return supports;
}

async function fetchTranscriptPage(rawURL: string, fetcher: typeof fetch): Promise<string | null> {
  const publicURL = publicHTTPSURL(rawURL);
  if (!publicURL) return null;
  let url = new URL(publicURL);
  try {
    let response: Response | null = null;
    for (let redirects = 0; redirects <= 3; redirects += 1) {
      response = await fetcher(url, {
        headers: {
          "user-agent": "Mozilla/5.0 (compatible; SceneFind/1.0; transcript verification)",
          "accept-language": "en-US,en;q=0.9",
        },
        redirect: "manual",
        signal: AbortSignal.timeout(8_000),
      });
      if (![301, 302, 303, 307, 308].includes(response.status)) break;
      const location = response.headers.get("location");
      if (!location || redirects === 3) return null;
      url = new URL(location, url);
      if (url.protocol !== "https:" || unsafeSearchHost(url.hostname)) return null;
    }
    if (!response) return null;
    if (!response.ok) return null;
    const contentType = response.headers.get("content-type")?.toLowerCase() ?? "";
    if (contentType && !contentType.includes("text/") && !contentType.includes("json")) return null;
    return (await response.text()).slice(0, 1_500_000);
  } catch {
    return null;
  }
}

function publicHTTPSURL(rawURL: string): string | null {
  let url: URL;
  try {
    url = new URL(rawURL);
  } catch {
    return null;
  }
  // Search indexes still contain old HTTP transcript links. Upgrade rather
  // than transmit any clip evidence over cleartext; never downgrade.
  if (url.protocol === "http:") url.protocol = "https:";
  if (url.protocol !== "https:" || unsafeSearchHost(url.hostname)) return null;
  return url.toString();
}

function unsafeSearchHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".local")) return true;
  if (/^(?:127|0|10|192\.168)\./.test(host)) return true;
  const match = host.match(/^172\.(\d{1,3})\./);
  if (match && Number(match[1]) >= 16 && Number(match[1]) <= 31) return true;
  return host === "::1" || host.startsWith("fc") || host.startsWith("fd") || host.startsWith("fe80:");
}

function dialoguePhrases(cues: TranscriptCue[] | undefined, dialogue: string): string[] {
  if (cues?.length) return searchablePhrases(cues).slice(0, 3).map((phrase) => phrase.text);
  return dialogue.split(/[.!?\n]+/)
    .map((line) => line.trim())
    .filter((line) => line.split(/\s+/).length >= 6)
    .sort((left, right) => right.length - left.length)
    .slice(0, 3);
}

function searchSupports(
  results: WebSearchResult[],
  showTitle: string,
  anchor: string,
  guide: EpisodeCatalogEntry[],
): SearchSupport[] {
  const show = normalize(showTitle);
  const anchorNormalized = normalize(anchor);
  const anchorTokens = tokens(anchor);
  if (!show || anchorTokens.size < 4) return [];
  return results.flatMap((result): SearchSupport[] => {
    const text = `${result.title} ${result.snippet} ${decodeURIComponentSafe(result.url)}`;
    const normalizedText = normalize(text);
    if (!normalizedText.includes(show)) return [];
    const overlap = intersectionSize(anchorTokens, tokens(text));
    if (!normalizedText.includes(anchorNormalized) && overlap / anchorTokens.size < 0.7) return [];

    const numbered = parseEpisodeCoordinates(text);
    let matches = guide.filter((episode) => numbered.has(coordinateKey({
      season: episode.seasonNumber,
      episode: episode.episodeNumber,
    })));
    if (matches.length === 0) {
      matches = guide.filter((episode) => {
        const title = normalize(episode.episodeTitle);
        return title.length >= 6 && normalizedText.includes(title);
      });
    }
    const unique = new Map(matches.map((episode) => [
      coordinateKey({ season: episode.seasonNumber, episode: episode.episodeNumber }),
      episode,
    ]));
    if (unique.size !== 1) return [];
    const episode = [...unique.values()][0];
    return [{
      season: episode.seasonNumber,
      episode: episode.episodeNumber,
      episodeTitle: episode.episodeTitle,
      anchor,
      sourceURL: result.url,
      titleMentioned: normalizedText.includes(normalize(episode.episodeTitle)),
      excerpt: `${result.title} — ${result.snippet}`.slice(0, 600),
    }];
  });
}

function parseEpisodeCoordinates(text: string): Set<string> {
  const patterns = [
    /\bs(?:eason)?\s*0*(\d{1,2})\s*[-.: ]*e(?:p(?:isode)?)?\s*0*(\d{1,3})\b/gi,
    /\bseason\s*0*(\d{1,2})\s*[,.: -]+\s*episode\s*0*(\d{1,3})\b/gi,
    /\b0*(\d{1,2})\s*x\s*0*(\d{1,3})\b/gi,
    /\bseason[-_/ ]0*(\d{1,2})[-_/ ]episode[-_/ ]0*(\d{1,3})\b/gi,
  ];
  const found = new Set<string>();
  for (const pattern of patterns) {
    for (const match of text.matchAll(pattern)) {
      const season = Number(match[1]);
      const episode = Number(match[2]);
      if (season > 0 && episode > 0) found.add(coordinateKey({ season, episode }));
    }
  }
  return found;
}

function shortlistGuide(
  guide: EpisodeCatalogEntry[],
  clipEvidence: string,
  supports: SearchSupport[],
  captionHints: Set<string>,
  candidateSeason: number | null,
  candidateEpisode: number | null,
): EpisodeCatalogEntry[] {
  const evidenceTokens = tokens(clipEvidence);
  const priorities = new Set([
    ...supports.map(coordinateKey),
    ...captionHints,
    candidateSeason && candidateEpisode
      ? coordinateKey({ season: candidateSeason, episode: candidateEpisode })
      : "",
  ]);
  return [...guide].sort((left, right) => {
    const score = (episode: EpisodeCatalogEntry) =>
      intersectionSize(evidenceTokens, tokens(`${episode.episodeTitle} ${episode.summary}`))
      + (priorities.has(coordinateKey({
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
      })) ? 100 : 0);
    return score(right) - score(left);
  }).slice(0, 20);
}

function strongSearchResolution(
  supports: SearchSupport[],
  captionHints: Set<string>,
  guide: EpisodeCatalogEntry[],
): EpisodeVerification | null {
  const groups = new Map<string, SearchSupport[]>();
  for (const support of supports) {
    const key = coordinateKey(support);
    groups.set(key, [...(groups.get(key) ?? []), support]);
  }
  const winner = [...groups].sort((left, right) =>
    distinctAnchors(right[1]) - distinctAnchors(left[1]) || right[1].length - left[1].length,
  )[0];
  if (!winner) return null;
  const anchors = distinctAnchors(winner[1]);
  if (anchors < 2 && !captionHints.has(winner[0]) && !winner[1].some((item) => item.titleMentioned)) {
    return null;
  }
  const coordinate = parseCoordinateKey(winner[0]);
  const canonical = guide.find((episode) =>
    episode.seasonNumber === coordinate.season && episode.episodeNumber === coordinate.episode,
  );
  if (!canonical) return null;
  return {
    verified: true,
    seasonNumber: canonical.seasonNumber,
    episodeNumber: canonical.episodeNumber,
    episodeTitle: canonical.episodeTitle,
    evidence: `Independent transcript search matched ${anchors} anchor(s): ${winner[1].slice(0, 3).map((item) => item.sourceURL).join(", ")}`,
    confidence: anchors >= 2 ? 0.96 : 0.9,
  };
}

function validateModelResolution(
  value: EpisodeVerification,
  guide: EpisodeCatalogEntry[],
  supports: SearchSupport[],
  clipEvidence: string,
  captionHints: Set<string>,
): EpisodeVerification | null {
  if (!value.verified || value.seasonNumber === null || value.episodeNumber === null) return null;
  const canonical = guide.find((episode) =>
    episode.seasonNumber === value.seasonNumber && episode.episodeNumber === value.episodeNumber,
  );
  if (!canonical) return null;
  const coordinate = coordinateKey({ season: canonical.seasonNumber, episode: canonical.episodeNumber });
  const webAnchors = distinctAnchors(supports.filter((support) => coordinateKey(support) === coordinate));
  const guideOverlap = intersectionSize(
    tokens(clipEvidence),
    tokens(`${canonical.episodeTitle} ${canonical.summary}`),
  );
  if (webAnchors < 1 && guideOverlap < 2) return null;
  return {
    ...value,
    seasonNumber: canonical.seasonNumber,
    episodeNumber: canonical.episodeNumber,
    episodeTitle: canonical.episodeTitle,
    evidence: `${value.evidence} Independent support: ${webAnchors} dialogue anchor(s), ${guideOverlap} guide-detail token(s).${captionHints.has(coordinate) ? " Caption agrees but was not treated as proof." : ""}`,
    confidence: Math.max(value.confidence, webAnchors > 0 ? 0.9 : 0.82),
  };
}

function deduplicateSupports(values: SearchSupport[]): SearchSupport[] {
  const seen = new Set<string>();
  return values.filter((support) => {
    const key = `${coordinateKey(support)}|${normalize(support.anchor)}|${support.sourceURL}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function distinctAnchors(values: SearchSupport[]): number {
  return new Set(values.map((value) => normalize(value.anchor))).size;
}

function unverified(evidence: string): EpisodeVerification {
  return {
    verified: false,
    seasonNumber: null,
    episodeNumber: null,
    episodeTitle: null,
    evidence,
    confidence: 0,
  };
}

function coordinateKey(value: EpisodeCoordinate): string {
  return `${value.season}|${value.episode}`;
}

function parseCoordinateKey(value: string): EpisodeCoordinate {
  const [season, episode] = value.split("|").map(Number);
  return { season, episode };
}

function normalize(value: string): string {
  return value.normalize("NFKD").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function tokens(value: string): Set<string> {
  const stop = new Set(["about", "after", "again", "before", "from", "have", "just", "that", "their", "there", "these", "they", "this", "those", "what", "when", "where", "which", "with", "would", "your"]);
  return new Set(normalize(value).split(" ").filter((word) => word.length >= 4 && !stop.has(word)));
}

function intersectionSize(left: Set<string>, right: Set<string>): number {
  let count = 0;
  for (const value of left) if (right.has(value)) count += 1;
  return count;
}

function decodeURIComponentSafe(value: string): string {
  try { return decodeURIComponent(value); } catch { return value; }
}
