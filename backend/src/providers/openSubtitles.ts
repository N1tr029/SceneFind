import type { TranscriptCue } from "../sourceRetrieval";
import type { Env } from "../types";

const API_ORIGIN = "https://api.opensubtitles.com/api/v1";
// OpenSubtitles rejects generic agents and asks that each consumer identify
// itself by name and version.
const USER_AGENT = "SceneFind v1.0";
const REQUEST_TIMEOUT_MS = 8_000;
const TRACK_TTL_SECONDS = 60 * 60 * 24 * 30;
const ABSENT_TTL_SECONDS = 60 * 60 * 24 * 3;
const TOKEN_TTL_SECONDS = 60 * 60 * 20;
const TOKEN_KEY = "opensubtitles:token";
const MAX_TRACK_CHARACTERS = 1_200_000;

export interface ReferenceTrackQuery {
  title: string;
  year?: number | null;
  seasonNumber?: number | null;
  episodeNumber?: number | null;
}

/** Separated so a title OpenSubtitles genuinely lacks can be remembered, while
 *  a timeout or an exhausted quota is retried on the next analysis. */
type TrackOutcome =
  | { kind: "track"; cues: TranscriptCue[] }
  | { kind: "absent" }
  | { kind: "unavailable" };

interface SubtitleEntry {
  attributes?: {
    download_count?: number | null;
    from_trusted?: boolean | null;
    feature_details?: { year?: number | null } | null;
    files?: Array<{ file_id?: number | null }> | null;
  } | null;
}

/**
 * The full subtitle track for one title, as timed cues.
 *
 * QuoDB answers "which title contains this line", which fails outright for a
 * title it never indexed. This answers "where does this line fall inside a
 * title we have already identified", so it only runs once identification has
 * produced a name. Searches are effectively unmetered but downloads are not —
 * five per day on an API key alone, a thousand on a VIP account — so every
 * track is cached and the quota is spent per title rather than per clip.
 */
export async function fetchReferenceTrack(
  env: Env,
  query: ReferenceTrackQuery,
  fetcher: typeof fetch = fetch,
): Promise<TranscriptCue[] | null> {
  if (!query.title.trim() || !env.OPENSUBTITLES_API_KEY) return null;
  const key = cacheKey(query);
  const cached = await env.SUBTITLES?.get(key, "json").catch(() => null) as
    { cues: TranscriptCue[] | null } | null;
  if (cached) return cached.cues;

  const outcome = await loadTrack(env, query, fetcher);
  if (outcome.kind === "unavailable") return null;
  const cues = outcome.kind === "track" ? outcome.cues : null;
  await env.SUBTITLES?.put(key, JSON.stringify({ cues }), {
    expirationTtl: cues ? TRACK_TTL_SECONDS : ABSENT_TTL_SECONDS,
  }).catch(() => undefined);
  return cues;
}

async function loadTrack(
  env: Env,
  query: ReferenceTrackQuery,
  fetcher: typeof fetch,
): Promise<TrackOutcome> {
  let fileID: number | null;
  try {
    fileID = await searchBestFile(env, query, fetcher);
  } catch {
    return { kind: "unavailable" };
  }
  if (fileID === null) return { kind: "absent" };

  try {
    const link = await requestDownloadLink(env, fileID, fetcher);
    if (!link) return { kind: "unavailable" };
    const response = await fetcher(link, {
      headers: { "user-agent": USER_AGENT },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) return { kind: "unavailable" };
    const body = await response.text();
    if (body.length > MAX_TRACK_CHARACTERS) return { kind: "absent" };
    const cues = parseSubRip(body);
    // A handful of cues means a trailer or a broken upload, not a feature.
    return cues.length >= 20 ? { kind: "track", cues } : { kind: "absent" };
  } catch {
    return { kind: "unavailable" };
  }
}

async function searchBestFile(
  env: Env,
  query: ReferenceTrackQuery,
  fetcher: typeof fetch,
): Promise<number | null> {
  const url = new URL(`${API_ORIGIN}/subtitles`);
  const episodic = query.seasonNumber != null && query.episodeNumber != null;
  url.searchParams.set("query", query.title);
  url.searchParams.set("languages", "en");
  url.searchParams.set("type", episodic ? "episode" : "movie");
  if (episodic) {
    url.searchParams.set("season_number", String(query.seasonNumber));
    url.searchParams.set("episode_number", String(query.episodeNumber));
  }
  if (query.year) url.searchParams.set("year", String(query.year));

  const response = await fetcher(url, {
    headers: authHeaders(env),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!response.ok) {
    if (response.status >= 500 || response.status === 429) throw new Error("search unavailable");
    return null;
  }
  const body = await response.json() as { data?: SubtitleEntry[] };
  const entries = (body.data ?? []).filter((entry) => fileIDOf(entry) !== null);
  if (entries.length === 0) return null;
  // A stated year that disagrees is a different film sharing the name, so it is
  // dropped outright. A missing year is not evidence of anything and stays in,
  // ranked below the entries that do match.
  const pool = query.year
    ? entries.filter((entry) => {
        const year = entry.attributes?.feature_details?.year;
        return year == null || year === query.year;
      })
    : entries;
  if (pool.length === 0) return null;
  const best = [...pool].sort((left, right) =>
    Number(matchesYear(right, query.year)) - Number(matchesYear(left, query.year)) ||
    Number(right.attributes?.from_trusted ?? false) - Number(left.attributes?.from_trusted ?? false) ||
    (right.attributes?.download_count ?? 0) - (left.attributes?.download_count ?? 0),
  )[0];
  return fileIDOf(best);
}

async function requestDownloadLink(
  env: Env,
  fileID: number,
  fetcher: typeof fetch,
): Promise<string | null> {
  const token = await loginToken(env, fetcher);
  const response = await fetcher(`${API_ORIGIN}/download`, {
    method: "POST",
    headers: { ...authHeaders(env, token), "content-type": "application/json" },
    body: JSON.stringify({ file_id: fileID }),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!response.ok) {
    // 406 is the daily download quota. Logging the status alone keeps clip
    // content out of the logs while still making an exhausted quota visible.
    console.error("subtitle download rejected", response.status);
    return null;
  }
  const body = await response.json() as { link?: string | null };
  return body.link ?? null;
}

/// The API key alone allows five downloads per IP per day, which is a test
/// budget, not a production one. An account token spends that account's quota
/// instead and stays valid for a day, so it is cached rather than minted per
/// analysis.
async function loginToken(env: Env, fetcher: typeof fetch): Promise<string | undefined> {
  if (!env.OPENSUBTITLES_USERNAME || !env.OPENSUBTITLES_PASSWORD) return undefined;
  const cached = await env.SUBTITLES?.get(TOKEN_KEY).catch(() => null);
  if (cached) return cached;
  try {
    const response = await fetcher(`${API_ORIGIN}/login`, {
      method: "POST",
      headers: { ...authHeaders(env), "content-type": "application/json" },
      body: JSON.stringify({
        username: env.OPENSUBTITLES_USERNAME,
        password: env.OPENSUBTITLES_PASSWORD,
      }),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok) {
      console.error("subtitle login rejected", response.status);
      return undefined;
    }
    const body = await response.json() as { token?: string | null };
    if (!body.token) return undefined;
    await env.SUBTITLES?.put(TOKEN_KEY, body.token, { expirationTtl: TOKEN_TTL_SECONDS })
      .catch(() => undefined);
    return body.token;
  } catch {
    return undefined;
  }
}

function authHeaders(env: Env, token?: string): Record<string, string> {
  return {
    "Api-Key": env.OPENSUBTITLES_API_KEY ?? "",
    "user-agent": USER_AGENT,
    accept: "application/json",
    ...(token ? { authorization: `Bearer ${token}` } : {}),
  };
}

function matchesYear(entry: SubtitleEntry, year?: number | null): boolean {
  return Boolean(year) && entry.attributes?.feature_details?.year === year;
}

function fileIDOf(entry: SubtitleEntry): number | null {
  const id = entry.attributes?.files?.[0]?.file_id;
  return typeof id === "number" && Number.isFinite(id) ? id : null;
}

function cacheKey(query: ReferenceTrackQuery): string {
  const episode = query.seasonNumber != null && query.episodeNumber != null
    ? `:s${query.seasonNumber}e${query.episodeNumber}`
    : "";
  const year = query.year ? `:${query.year}` : "";
  const title = query.title.normalize("NFKD").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  return `track:${title}${year}${episode}`;
}

export function parseSubRip(value: string): TranscriptCue[] {
  const cues: TranscriptCue[] = [];
  for (const block of value.replace(/\r/g, "").split(/\n{2,}/)) {
    const lines = block.split("\n").map((line) => line.trim()).filter(Boolean);
    const timingIndex = lines.findIndex((line) => line.includes("-->"));
    if (timingIndex === -1 || timingIndex === lines.length - 1) continue;
    const [from, to] = lines[timingIndex].split("-->").map((part) => part.trim());
    const startSeconds = parseTimecode(from);
    const endSeconds = parseTimecode(to);
    if (startSeconds === null || endSeconds === null || endSeconds < startSeconds) continue;
    const text = lines.slice(timingIndex + 1).join(" ")
      // Styling tags and {\an8} positioning are not dialogue, and a stray
      // "- " speaker dash would otherwise become a token of its own.
      .replace(/<[^>]*>/g, " ")
      .replace(/\{[^}]*\}/g, " ")
      .replace(/\s+/g, " ")
      .trim();
    if (!text) continue;
    cues.push({ startSeconds, endSeconds, text });
  }
  return cues;
}

function parseTimecode(value: string): number | null {
  const match = /^(\d{1,3}):([0-5]\d):([0-5]\d)[,.](\d{1,3})/.exec(value);
  if (!match) return null;
  return Number(match[1]) * 3_600 +
    Number(match[2]) * 60 +
    Number(match[3]) +
    Number(match[4].padEnd(3, "0")) / 1_000;
}
