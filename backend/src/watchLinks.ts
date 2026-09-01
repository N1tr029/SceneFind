// Shared "open in <service>" link resolution.
//
// Streaming services hide episode pages behind ids that cannot be derived from a
// title — Apple TV's `umc.cmc…`, Peacock's per-episode UUID. Those ids are in
// public search results, because providers publish crawlable episode pages, so
// the way to get one is to search for the episode and then confirm the page.
//
// This lives on the Worker rather than in the app for one reason: cost. A search
// costs quota (SerpApi's free plan allows 250 a month), but an episode's page URL
// never changes and popular clips concentrate on the same episodes. Resolving
// here means the *first* device to ask pays for the lookup and every other device
// is served from KV — so spend scales with distinct episodes, not with users.

import type { Env, PublicError, PublicErrorCode, WatchLink, WatchLinksResponse } from "./types";
import { searchWebDetailed, type KnowledgeWatchLink, type WebSearchResult } from "./webSearch";

/** Hosts we are willing to hand a viewer, and the service each one is. */
const PROVIDER_HOSTS: ReadonlyArray<readonly [string, WatchLink["service"], string]> = [
  ["netflix.com", "netflix", "Netflix"],
  ["tv.apple.com", "appleTV", "Apple TV"],
  ["disneyplus.com", "disneyPlus", "Disney+"],
  ["hulu.com", "hulu", "Hulu"],
  ["primevideo.com", "primeVideo", "Prime Video"],
  ["hbomax.com", "max", "Max"],
  ["max.com", "max", "Max"],
  ["peacocktv.com", "peacock", "Peacock"],
  ["paramountplus.com", "paramountPlus", "Paramount+"],
];

/** Verified links effectively never change. Misses are retried sooner in case a
 *  title only just landed on a service. */
const HIT_TTL_SECONDS = 60 * 60 * 24 * 90;
const MISS_TTL_SECONDS = 60 * 60 * 24 * 7;

/** Enough to cover the services people actually subscribe to, while keeping the
 *  verification fan-out small. */
const MAX_SERVICES = 5;

export interface WatchLinkQuery {
  title: string;
  mediaType: "movie" | "tv" | "other";
  releaseYear?: number;
  seasonNumber?: number;
  episodeNumber?: number;
  episodeTitle?: string;
  region: string;
}

export async function handleWatchLinks(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const query = parseQuery(url);
  if (!query) {
    return errorResponse("invalid_request", "A title is required.", 400);
  }

  const key = cacheKey(query);
  const cached = await env.WATCH_LINKS.get<WatchLinksResponse>(key, "json");
  if (cached) {
    return json({ ...cached, source: "cache" } satisfies WatchLinksResponse);
  }

  const { results, knowledge, ok } = await search(query, env);
  const trusted = knowledgeLinks(knowledge, query);
  const verified = await verifyCandidates(results, query);
  // Google's panel wins per service: it carries the exact playback id, where a
  // verified organic result is at best the right episode page.
  const links = [
    ...trusted,
    ...verified.filter((link) => !trusted.some((entry) => entry.service === link.service)),
  ].slice(0, MAX_SERVICES);
  const body: WatchLinksResponse = { links, source: "resolved" };

  // Cache misses too: without that, a title with no findable link would spend a
  // search on every request forever. But only when the search actually ran —
  // caching a transport failure would blank the episode for the miss TTL.
  if (ok || links.length > 0) {
    await env.WATCH_LINKS.put(key, JSON.stringify({ links, source: "cache" }), {
      expirationTtl: links.length > 0 ? HIT_TTL_SECONDS : MISS_TTL_SECONDS,
    });
  }

  return json(body);
}

function parseQuery(url: URL): WatchLinkQuery | null {
  const title = url.searchParams.get("title")?.trim();
  if (!title) return null;
  const number = (name: string): number | undefined => {
    const raw = url.searchParams.get(name);
    if (!raw) return undefined;
    const value = Number.parseInt(raw, 10);
    return Number.isFinite(value) ? value : undefined;
  };
  const rawType = url.searchParams.get("type");
  return {
    title,
    mediaType: rawType === "movie" || rawType === "other" ? rawType : "tv",
    releaseYear: number("year"),
    seasonNumber: number("season"),
    episodeNumber: number("episode"),
    episodeTitle: url.searchParams.get("episodeTitle")?.trim() || undefined,
    region: normalizedRegion(url.searchParams.get("region")),
  };
}

function cacheKey(query: WatchLinkQuery): string {
  const normalized = query.title.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  return [
    "wl:v2",
    normalized,
    query.seasonNumber ?? "-",
    query.episodeNumber ?? "-",
    query.releaseYear ?? "-",
    query.region,
  ].join("|");
}

/** Phrased the way a person searches, because that is how provider pages are
 *  titled and therefore indexed. */
export function searchQuery(query: WatchLinkQuery): string {
  const parts = [query.title];
  if (query.mediaType === "tv" && query.seasonNumber && query.episodeNumber) {
    parts.push(`season ${query.seasonNumber} episode ${query.episodeNumber}`);
    if (query.episodeTitle) parts.push(query.episodeTitle);
  } else if (query.mediaType === "movie" && query.releaseYear) {
    parts.push(String(query.releaseYear));
  }
  parts.push("watch");
  return parts.join(" ");
}

// --- search ----------------------------------------------------------------

/** Accepts a SerpApi key (64 hex chars) or a Brave key (`BSA…`), told apart by
 *  shape so the deployment only has to set one secret. */
async function search(
  query: WatchLinkQuery,
  env: Env,
): Promise<{ results: WebSearchResult[]; knowledge: KnowledgeWatchLink[]; ok: boolean }> {
  const ask = (value: string) => searchWebDetailed({
    apiKey: env.SEARCH_API_KEY,
    query: value,
    region: query.region,
  });

  // Ask the way a person would first. Plain-language episode phrasing is what
  // triggers Google's "Watch episode" panel, and the panel carries each
  // provider's exact playback id — the thing Netflix and Hulu cannot be
  // verified into. When it answers we are done, which makes the common episode
  // cost one search rather than three. SerpApi's free tier is 250 a month, so
  // that difference is the difference between ~80 episodes and ~250.
  if (query.mediaType === "tv" && query.seasonNumber && query.episodeNumber) {
    const panel = await ask(`${query.title} s${query.seasonNumber} episode ${query.episodeNumber}`);
    if (knowledgeLinks(panel.knowledge, query).length > 0) {
      return { results: panel.results, knowledge: panel.knowledge, ok: true };
    }
    const fallbacks = await Promise.all([
      ask(searchQuery(query)),
      // Netflix's generic title page routinely outranks the episode /watch
      // page. Ask for the route shape explicitly so the opaque id is present.
      ask([
        "site:netflix.com/watch",
        `"${query.title.replaceAll('"', "")}"`,
        query.episodeTitle
          ? `"${query.episodeTitle.replaceAll('"', "")}"`
          : `"season ${query.seasonNumber} episode ${query.episodeNumber}"`,
      ].join(" ")),
    ]);
    return merge([panel, ...fallbacks]);
  }

  return merge([await ask(searchQuery(query))]);
}

function merge(
  batches: Array<{ results: WebSearchResult[]; knowledge: KnowledgeWatchLink[]; ok: boolean }>,
): { results: WebSearchResult[]; knowledge: KnowledgeWatchLink[]; ok: boolean } {
  const unique = new Map<string, WebSearchResult>();
  for (const result of batches.flatMap((batch) => batch.results)) unique.set(result.url, result);
  return {
    results: [...unique.values()],
    knowledge: batches.flatMap((batch) => batch.knowledge),
    // If every query failed we know nothing; caching that as "no links" would
    // blank this episode for a week.
    ok: batches.some((batch) => batch.ok),
  };
}

/** Provider links Google published for this episode. Google resolved the exact
 *  playback id, so these need no page verification — which is what makes them
 *  the only workable path for Netflix and Hulu. */
/** Route shapes providers actually use for a single episode, taken from live
 *  Google "Watch episode" panels rather than guessed:
 *
 *    Netflix      /watch/81647019
 *    Apple TV     /us/episode/the-swell/umc.cmc…
 *    Hulu         /watch/<uuid>
 *    Disney+      /play/<uuid>                    (not /video/)
 *    Max          /show/<id>/s1/e1-celebration/…  (not /video/watch/)
 *    Peacock      /watch-online/tv/…/episodes/…
 *    Paramount+   /shows/video/<id>/
 *    Prime Video  /detail/<asin>
 *
 *  These are only applied to panel links. A panel entry is episode-scoped by
 *  provenance — Google emitted it for an episode query — which is what makes
 *  Prime Video's `/detail/<asin>` usable here and not from an organic result,
 *  where the same shape is just as likely to be the series page. */
function isPanelEpisodeRoute(url: URL, service: WatchLink["service"]): boolean {
  const path = url.pathname.toLowerCase();
  switch (service) {
    case "netflix": return /^\/watch\/[^/]+/.test(path);
    case "appleTV": return path.includes("/episode/");
    case "disneyPlus": return path.includes("/play/") || path.includes("/video/");
    case "hulu": return path.includes("/watch/") || path.includes("/videos/");
    case "primeVideo": return path.includes("/detail/");
    case "max": return /\/s\d+\/e\d+/.test(path) || path.includes("/video/watch/") || path.includes("/episode/");
    case "peacock": return path.includes("/episodes/") || path.includes("/watch/playback/");
    case "paramountPlus": return path.includes("/video/") || url.hostname === "link.us.paramountplus.com";
  }
}

export function knowledgeLinks(entries: KnowledgeWatchLink[], query: WatchLinkQuery): WatchLink[] {
  const bySerice = new Map<WatchLink["service"], WatchLink>();
  for (const entry of entries) {
    let url: URL;
    try {
      url = new URL(entry.url);
    } catch {
      continue;
    }
    const match = PROVIDER_HOSTS.find(
      ([host]) => url.hostname === host || url.hostname.endsWith(`.${host}`),
    );
    if (!match) continue;
    if (isForeignStorefront(url, query.region)) continue;
    if (query.mediaType === "tv" && !isPanelEpisodeRoute(url, match[1])) continue;
    if (bySerice.has(match[1])) continue;
    bySerice.set(match[1], { url: url.toString(), service: match[1], serviceName: match[2] });
  }
  return [...bySerice.values()];
}

// --- verification ----------------------------------------------------------

/** Keeps only links whose own page confirms the show and season/episode.
 *
 *  This is the step that makes a link trustworthy: a stale or wrong id is
 *  dropped rather than handed to a viewer as a button that opens to "not found".
 */
export async function verifyCandidates(
  results: WebSearchResult[],
  query: WatchLinkQuery,
  fetcher: typeof fetch = fetch,
): Promise<WatchLink[]> {
  const candidatesPerService = new Map<
    WatchLink["service"],
    Array<{ url: URL; serviceName: string; result: WebSearchResult }>
  >();
  for (const result of rank(results, query.region)) {
    let url: URL;
    try {
      url = new URL(result.url);
    } catch {
      continue;
    }
    const match = PROVIDER_HOSTS.find(
      ([host]) => url.hostname === host || url.hostname.endsWith(`.${host}`),
    );
    if (!match || (query.mediaType === "tv" && !isExactEpisodeRoute(url, match[1]))) continue;
    const existing = candidatesPerService.get(match[1]) ?? [];
    if (existing.length >= 4) continue;
    existing.push({ url, serviceName: match[2], result });
    candidatesPerService.set(match[1], existing);
  }

  const checked = await Promise.all(
    [...candidatesPerService].slice(0, MAX_SERVICES).map(async ([service, entries]) => {
      // Do not discard a whole service because its first search result was a
      // generic show page or stale id. Verify several ranked exact routes and
      // keep the first one whose page or provider-indexed metadata matches.
      for (const entry of entries) {
        const confirmed = await pageConfirms(entry.url, query, fetcher)
          || indexedResultConfirms(entry.result, query);
        if (confirmed) {
          return { url: entry.url.toString(), service, serviceName: entry.serviceName };
        }
      }
      return null;
    }),
  );
  return checked.filter((link): link is WatchLink => link !== null);
}

/** Episode-specific paths first, and no other country's storefront — a `/ca/`
 *  page will not play for a US viewer even though it verifies. */
function rank(results: WebSearchResult[], region: string): WebSearchResult[] {
  const markers = ["/episode", "/watch", "/video", "/movie", "/play", "/detail"];
  return results
    .filter((result) => {
      try {
        return !isForeignStorefront(new URL(result.url), region);
      } catch {
        return false;
      }
    })
    .sort((a, b) => {
      const score = (value: WebSearchResult) =>
        markers.some((marker) => new URL(value.url).pathname.toLowerCase().includes(marker)) ? 1 : 0;
      const diff = score(b) - score(a);
      return diff !== 0 ? diff : b.url.length - a.url.length;
    });
}

export function isExactEpisodeRoute(url: URL, service: WatchLink["service"]): boolean {
  const path = url.pathname.toLowerCase();
  switch (service) {
    case "netflix": return /^\/watch\/[^/]+/.test(path);
    case "appleTV": return path.includes("/episode/");
    case "disneyPlus": return path.includes("/video/");
    case "hulu": return path.includes("/watch/") || path.includes("/videos/");
    case "primeVideo": return path.includes("/video/detail/") || path.includes("/gp/video/detail/");
    case "max": return path.includes("/video/watch/") || path.includes("/episode/");
    case "peacock": return path.includes("/episodes/") || path.includes("/watch/playback/");
    case "paramountPlus": return path.includes("/video/") || url.hostname === "link.us.paramountplus.com";
  }
}

export function isForeignStorefront(url: URL, region = "US"): boolean {
  const first = url.pathname.split("/").filter(Boolean)[0]?.toLowerCase();
  if (!first || first.length !== 2 || !/^[a-z]{2}$/.test(first)) return false;
  return first !== region.toLowerCase() && first !== "en";
}

function normalizedRegion(raw: string | null): string {
  const value = raw?.trim().toUpperCase();
  return value && /^[A-Z]{2}$/.test(value) ? value : "US";
}

async function pageConfirms(
  url: URL,
  query: WatchLinkQuery,
  fetcher: typeof fetch,
): Promise<boolean> {
  let html: string;
  try {
    const response = await fetcher(url, {
      headers: {
        "user-agent":
          "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
          "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "accept-language": "en-US,en;q=0.9",
      },
    });
    if (!response.ok) return false;
    html = await response.text();
  } catch {
    return false;
  }

  const titles = [metaContent(html, "og:title"), metaContent(html, "twitter:title"), pageTitle(html)]
    .filter((value): value is string => Boolean(value));
  return evidenceTextConfirms(titles, query);
}

function indexedResultConfirms(result: WebSearchResult, query: WatchLinkQuery): boolean {
  return evidenceTextConfirms([result.title, result.snippet], query);
}

function evidenceTextConfirms(values: string[], query: WatchLinkQuery): boolean {
  const normalizedValues = values.filter(Boolean).map(normalize);
  if (normalizedValues.length === 0) return false;
  const showMatch = normalizedValues.some((value) => value.includes(normalize(query.title)));
  if (query.mediaType !== "tv") return showMatch;

  const episodeMatch = query.episodeTitle
    ? normalizedValues.some((value) => value.includes(normalize(query.episodeTitle!)))
    : false;
  const numberMatch =
    query.seasonNumber !== undefined &&
    query.episodeNumber !== undefined &&
    normalizedValues.some((value) =>
      [
        `s${query.seasonNumber} e${query.episodeNumber}`,
        `${query.seasonNumber}x${query.episodeNumber}`,
        `season ${query.seasonNumber} episode ${query.episodeNumber}`,
      ].some((pattern) => value.includes(pattern)),
    );

  // Either the episode is named, or the show plus its numbering lines up.
  return (episodeMatch && showMatch) || (showMatch && numberMatch);
}

function metaContent(html: string, property: string): string | null {
  const escaped = property.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  for (const pattern of [
    new RegExp(`<meta[^>]*?(?:property|name)=["']${escaped}["'][^>]*?content=["']([^"']*)["']`, "i"),
    new RegExp(`<meta[^>]*?content=["']([^"']*)["'][^>]*?(?:property|name)=["']${escaped}["']`, "i"),
  ]) {
    const match = html.match(pattern);
    if (match?.[1]) return decodeEntities(match[1]);
  }
  return null;
}

function pageTitle(html: string): string | null {
  const match = html.match(/<title[^>]*>([^<]+)<\/title>/i);
  return match?.[1] ? decodeEntities(match[1]) : null;
}

function decodeEntities(value: string): string {
  return value
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, " ");
}

function normalize(value: string): string {
  return value
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

// --- helpers ---------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function errorResponse(code: PublicErrorCode, message: string, status: number): Response {
  const body: PublicError = { error: { code, message } };
  return json(body, status);
}
