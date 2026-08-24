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
import { searchWeb } from "./webSearch";

/** Hosts we are willing to hand a viewer, and the service each one is. */
const PROVIDER_HOSTS: ReadonlyArray<readonly [string, WatchLink["service"], string]> = [
  ["netflix.com", "netflix", "Netflix"],
  ["tv.apple.com", "appleTV", "Apple TV"],
  ["disneyplus.com", "disneyPlus", "Disney+"],
  ["hulu.com", "hulu", "Hulu"],
  ["primevideo.com", "primeVideo", "Prime Video"],
  ["hbomax.com", "max", "Max"],
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

  const results = await search(query, env);
  const links = await verifyCandidates(results, query);
  const body: WatchLinksResponse = { links, source: "resolved" };

  // Cache misses too: without that, a title with no findable link would spend a
  // search on every request forever.
  await env.WATCH_LINKS.put(key, JSON.stringify({ links, source: "cache" }), {
    expirationTtl: links.length > 0 ? HIT_TTL_SECONDS : MISS_TTL_SECONDS,
  });

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
    "wl:v1",
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
async function search(query: WatchLinkQuery, env: Env): Promise<string[]> {
  return (await searchWeb({
    apiKey: env.SEARCH_API_KEY,
    query: searchQuery(query),
    region: query.region,
  })).map((result) => result.url);
}

// --- verification ----------------------------------------------------------

/** Keeps only links whose own page confirms the show and season/episode.
 *
 *  This is the step that makes a link trustworthy: a stale or wrong id is
 *  dropped rather than handed to a viewer as a button that opens to "not found".
 */
async function verifyCandidates(
  results: string[],
  query: WatchLinkQuery,
): Promise<WatchLink[]> {
  const bestPerService = new Map<WatchLink["service"], { url: URL; serviceName: string }>();
  for (const raw of rank(results, query.region)) {
    let url: URL;
    try {
      url = new URL(raw);
    } catch {
      continue;
    }
    const match = PROVIDER_HOSTS.find(
      ([host]) => url.hostname === host || url.hostname.endsWith(`.${host}`),
    );
    if (!match || bestPerService.has(match[1])) continue;
    bestPerService.set(match[1], { url, serviceName: match[2] });
    if (bestPerService.size >= MAX_SERVICES) break;
  }

  const checked = await Promise.all(
    [...bestPerService].map(async ([service, entry]) => {
      const ok = await pageConfirms(entry.url, query);
      return ok ? ({ url: entry.url.toString(), service, serviceName: entry.serviceName }) : null;
    }),
  );
  return checked.filter((link): link is WatchLink => link !== null);
}

/** Episode-specific paths first, and no other country's storefront — a `/ca/`
 *  page will not play for a US viewer even though it verifies. */
function rank(results: string[], region: string): string[] {
  const markers = ["/episode", "/watch", "/video", "/movie", "/play", "/detail"];
  return results
    .filter((raw) => {
      try {
        return !isForeignStorefront(new URL(raw), region);
      } catch {
        return false;
      }
    })
    .sort((a, b) => {
      const score = (value: string) => (markers.some((m) => value.includes(m)) ? 1 : 0);
      const diff = score(b) - score(a);
      return diff !== 0 ? diff : b.length - a.length;
    });
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

async function pageConfirms(url: URL, query: WatchLinkQuery): Promise<boolean> {
  let html: string;
  try {
    const response = await fetch(url, {
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
    .filter((value): value is string => Boolean(value))
    .map(normalize);
  if (titles.length === 0) return false;

  const showMatch = titles.some((value) => value.includes(normalize(query.title)));
  if (query.mediaType !== "tv") return showMatch;

  const episodeMatch = query.episodeTitle
    ? titles.some((value) => value.includes(normalize(query.episodeTitle!)))
    : false;
  const numberMatch =
    query.seasonNumber !== undefined &&
    query.episodeNumber !== undefined &&
    titles.some((value) =>
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
