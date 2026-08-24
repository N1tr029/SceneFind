import type { TranscriptCue } from "./sourceRetrieval";

const QUODB_ORIGIN = "https://api.quodb.com";
const MAX_QUERIES = 8;
const OFFSET_TOLERANCE_SECONDS = 4;

export interface SceneTimelineResolution {
  canonicalTitle: string;
  seriesTitle: string | null;
  episodeTitle: string | null;
  seasonNumber: number | null;
  episodeNumber: number | null;
  startSeconds: number;
  endSeconds: number;
  matchedDialogue: string;
  anchorCount: number;
  maximumAnchorDeviationSeconds: number;
  averageAnchorSimilarity: number;
  endExtrapolationSeconds: number;
  endAnchorDeviationSeconds: number;
  heldOutEndAnchorErrorSeconds: number | null;
  tailOffsetSeconds: number;
  confidence: number;
}

interface SearchPhrase {
  cueIndex: number;
  startSeconds: number;
  endSeconds: number;
  text: string;
  wordCount: number;
}

interface QuoDBDocument {
  title?: string | null;
  serie?: string | null;
  phrase?: string | null;
  time?: number | null;
}

interface TimelineHit extends SearchPhrase {
  canonicalTitle: string;
  seriesTitle: string | null;
  episodeTitle: string | null;
  seasonNumber: number | null;
  episodeNumber: number | null;
  canonicalSeconds: number;
  offsetSeconds: number;
  similarity: number;
}

interface HitCluster {
  hits: TimelineHit[];
  offsetSeconds: number;
  maximumDeviationSeconds: number;
  averageSimilarity: number;
}

export async function resolveSceneTimeline(options: {
  cues: TranscriptCue[];
  durationSeconds?: number;
  expectedTitle?: string;
  fetcher?: typeof fetch;
}): Promise<SceneTimelineResolution | null> {
  const phrases = searchablePhrases(options.cues);
  if (phrases.length === 0) return null;
  const fetcher = options.fetcher ?? fetch;
  const results = await Promise.all(phrases.map(async (phrase) => ({
    phrase,
    documents: await searchQuoDB(fetcher, phrase.text, options.expectedTitle),
  })));

  const hits: TimelineHit[] = [];
  for (const { phrase, documents } of results) {
    for (const document of documents) {
      const title = document.title?.trim();
      const series = document.serie?.trim() || null;
      const matchedPhrase = document.phrase?.trim();
      const timeMs = Number(document.time);
      if (!title || !matchedPhrase || !Number.isFinite(timeMs) || timeMs <= 0) continue;
      if (options.expectedTitle && ![title, series].some(
        (candidate) => candidate && titlesMatch(candidate, options.expectedTitle!),
      )) continue;
      const similarity = phraseSimilarity(phrase.text, matchedPhrase);
      // The upstream identifier has already constrained the title, so tolerate
      // a little auto-caption noise. Unscoped discovery retains the stricter
      // floor, and a single-anchor result still needs 0.9 below.
      if (similarity < (options.expectedTitle ? 0.58 : 0.62)) continue;
      const canonicalSeconds = timeMs / 1_000;
      hits.push({
        ...phrase,
        canonicalTitle: series ?? title,
        seriesTitle: series,
        episodeTitle: series ? title : null,
        seasonNumber: null,
        episodeNumber: null,
        canonicalSeconds,
        offsetSeconds: canonicalSeconds - phrase.startSeconds,
        similarity,
      });
    }
  }
  if (hits.length === 0) return null;

  const grouped = new Map<string, TimelineHit[]>();
  for (const hit of hits) {
    const key = `${normalized(hit.canonicalTitle)}|${normalized(hit.episodeTitle ?? "")}`;
    grouped.set(key, [...(grouped.get(key) ?? []), hit]);
  }
  const clusters = [...grouped.values()]
    .map(bestCluster)
    .filter((cluster): cluster is HitCluster => cluster !== null)
    .sort(compareClusters);
  const best = clusters[0];
  if (!best) return null;
  const minimumAnchors = options.expectedTitle ? 1 : 2;
  if (best.hits.length < minimumAnchors) return null;
  const runnerUp = clusters[1];
  if (!options.expectedTitle && runnerUp &&
      runnerUp.hits.length === best.hits.length &&
      runnerUp.averageSimilarity >= best.averageSimilarity - 0.05) return null;

  const representative = best.hits[0];
  const duration = options.durationSeconds && options.durationSeconds > 0
    ? options.durationSeconds
    : Math.max(...options.cues.map((cue) => cue.endSeconds));
  const startSeconds = Math.max(0, best.offsetSeconds);
  const orderedHits = [...best.hits].sort((left, right) => left.startSeconds - right.startSeconds);
  const lastAnchor = orderedHits.at(-1)!;
  const lastAnchorEndSeconds = lastAnchor.endSeconds;
  const endExtrapolationSeconds = Math.max(0, duration - lastAnchorEndSeconds);
  const tailHits = orderedHits.slice(-3);
  const tailOffsetSeconds = median(tailHits.map((hit) => hit.offsetSeconds));
  const endAnchorDeviationSeconds = Math.abs(lastAnchor.offsetSeconds - tailOffsetSeconds);
  const heldOutEndAnchorErrorSeconds = orderedHits.length >= 3
    ? Math.abs(
        lastAnchor.offsetSeconds -
        median(orderedHits.slice(0, -1).map((hit) => hit.offsetSeconds)),
      )
    : null;
  const endSeconds = Math.max(startSeconds, tailOffsetSeconds + duration);
  if (best.hits.length >= 2 && endExtrapolationSeconds > 20) return null;
  if (heldOutEndAnchorErrorSeconds !== null && heldOutEndAnchorErrorSeconds > 4) return null;
  if (best.hits.length === 1 && (
    best.averageSimilarity < 0.9 ||
    best.hits[0].wordCount < 8 ||
    endExtrapolationSeconds > 8
  )) return null;
  const confidence = best.hits.length >= 3
    ? 0.97
    : best.hits.length === 2
      ? 0.91
      : 0.8;
  return {
    canonicalTitle: representative.canonicalTitle,
    seriesTitle: representative.seriesTitle,
    episodeTitle: representative.episodeTitle,
    seasonNumber: representative.seasonNumber,
    episodeNumber: representative.episodeNumber,
    startSeconds,
    endSeconds,
    matchedDialogue: best.hits
      .sort((left, right) => left.startSeconds - right.startSeconds)
      .map((hit) => hit.text)
      .join(" … ")
      .slice(0, 600),
    anchorCount: best.hits.length,
    maximumAnchorDeviationSeconds: best.maximumDeviationSeconds,
    averageAnchorSimilarity: best.averageSimilarity,
    endExtrapolationSeconds,
    endAnchorDeviationSeconds,
    heldOutEndAnchorErrorSeconds,
    tailOffsetSeconds,
    confidence,
  };
}

export function searchablePhrases(cues: TranscriptCue[]): SearchPhrase[] {
  const candidates: Array<SearchPhrase & { score: number }> = [];
  for (let start = 0; start < cues.length; start += 1) {
    let text = "";
    let endSeconds = cues[start].endSeconds;
    for (let length = 1; length <= 3 && start + length <= cues.length; length += 1) {
      const cue = cues[start + length - 1];
      if (length > 1 && cue.startSeconds - endSeconds > 2.5) break;
      text = `${text} ${cue.text}`.replace(/\s+/g, " ").trim();
      endSeconds = cue.endSeconds;
      const words = tokens(text);
      if (words.length < 6 || words.length > 26 || text.length > 220) continue;
      const lengthPenalty = Math.abs(words.length - 11) * 0.65 + (length - 1) * 2;
      candidates.push({
        cueIndex: start,
        startSeconds: cues[start].startSeconds,
        endSeconds,
        text,
        wordCount: words.length,
        // QuoDB is strongest on a single subtitle sentence. Prefer roughly
        // 8–14 words and combine adjacent cues only when TikTok split one line
        // into fragments.
        score: 30 + new Set(words).size * 0.15 - lengthPenalty,
      });
    }
  }
  if (candidates.length === 0) return [];
  const byQuality = [...candidates].sort((left, right) => right.score - left.score);
  const selected: SearchPhrase[] = [];
  const firstStart = Math.min(...candidates.map((candidate) => candidate.startSeconds));
  const lastStart = Math.max(...candidates.map((candidate) => candidate.startSeconds));
  const span = Math.max(1, lastStart - firstStart);
  if (span <= 300) {
    for (const candidate of byQuality) {
      if (selected.some((item) => Math.abs(item.startSeconds - candidate.startSeconds) < 3)) continue;
      const { score: _, ...phrase } = candidate;
      selected.push(phrase);
      if (selected.length === MAX_QUERIES) break;
    }
    return selected.sort((left, right) => left.startSeconds - right.startSeconds);
  }
  // Exact clip-end handoff needs evidence close to the end, while global
  // quality-only ranking tends to spend every query on early dialogue. Pick
  // one strong phrase from each temporal slice before filling spare slots.
  for (let bucket = 0; bucket < MAX_QUERIES; bucket += 1) {
    const lower = firstStart + span * (bucket / MAX_QUERIES);
    const upper = bucket === MAX_QUERIES - 1
      ? lastStart + 0.001
      : firstStart + span * ((bucket + 1) / MAX_QUERIES);
    const candidate = byQuality
      .filter((item) =>
        item.startSeconds >= lower &&
        item.startSeconds < upper &&
        !selected.some((selectedItem) => Math.abs(selectedItem.startSeconds - item.startSeconds) < 3)
      )
      .sort((left, right) => right.startSeconds - left.startSeconds || right.score - left.score)[0];
    if (!candidate) continue;
    const { score: _, ...phrase } = candidate;
    selected.push(phrase);
  }
  for (const candidate of byQuality) {
    if (selected.length === MAX_QUERIES) break;
    if (selected.some((item) => Math.abs(item.startSeconds - candidate.startSeconds) < 3)) continue;
    const { score: _, ...phrase } = candidate;
    selected.push(phrase);
  }
  return selected.sort((left, right) => left.startSeconds - right.startSeconds);
}

async function searchQuoDB(
  fetcher: typeof fetch,
  phrase: string,
  expectedTitle?: string,
): Promise<QuoDBDocument[]> {
  const exact = await searchQuoDBOnce(fetcher, phrase, 8);
  if (!expectedTitle || exact.some((document) => [document.title, document.serie].some(
    (candidate) => candidate && titlesMatch(candidate, expectedTitle),
  ))) return exact;

  // TikTok auto-captions frequently attach a bad word or speaker label to an
  // otherwise exact subtitle. Search bounded leading/trailing windows only
  // after the full line fails for the identified title, then retain the normal
  // title and similarity checks in the caller.
  const words = phrase.trim().split(/\s+/);
  const variants = [...new Set([
    words.slice(0, 6).join(" "),
    words.slice(-6).join(" "),
    words.slice(0, 4).join(" "),
    words.slice(-4).join(" "),
  ])].filter((query) => query && query !== phrase);
  const fallback = await Promise.all(
    variants.map((query) => searchQuoDBOnce(fetcher, query, 20)),
  );
  const unique = new Map<string, QuoDBDocument>();
  for (const document of [exact, ...fallback].flat()) {
    const key = `${document.serie ?? ""}|${document.title ?? ""}|${document.time ?? ""}|${document.phrase ?? ""}`;
    unique.set(key, document);
  }
  return [...unique.values()];
}

async function searchQuoDBOnce(
  fetcher: typeof fetch,
  phrase: string,
  titlesPerPage: number,
): Promise<QuoDBDocument[]> {
  const url = new URL(`/search/${encodeURIComponent(phrase)}`, QUODB_ORIGIN);
  url.searchParams.set("titles_per_page", String(titlesPerPage));
  url.searchParams.set("phrases_per_title", "4");
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await fetcher(url, {
        headers: { "user-agent": "SceneFind/1.0" },
        signal: AbortSignal.timeout(6_000),
      });
      if (response.ok) {
        const body = await response.json() as { docs?: QuoDBDocument[] };
        return Array.isArray(body.docs) ? body.docs.slice(0, 32) : [];
      }
      if (response.status !== 429 && response.status < 500) return [];
    } catch {
      // One bounded retry handles a transient timeout without turning scene
      // matching into an unbounded external dependency.
    }
    if (attempt === 0) await new Promise((resolve) => setTimeout(resolve, 150));
  }
  return [];
}

function bestCluster(hits: TimelineHit[]): HitCluster | null {
  let best: HitCluster | null = null;
  for (const center of hits) {
    const byCue = new Map<number, TimelineHit>();
    for (const hit of hits) {
      if (Math.abs(hit.offsetSeconds - center.offsetSeconds) > OFFSET_TOLERANCE_SECONDS) continue;
      const existing = byCue.get(hit.cueIndex);
      if (!existing || hit.similarity > existing.similarity) byCue.set(hit.cueIndex, hit);
    }
    const inliers = [...byCue.values()];
    if (inliers.length === 0) continue;
    const offsetSeconds = median(inliers.map((hit) => hit.offsetSeconds));
    const maximumDeviationSeconds = Math.max(
      ...inliers.map((hit) => Math.abs(hit.offsetSeconds - offsetSeconds)),
    );
    const averageSimilarity = inliers.reduce((sum, hit) => sum + hit.similarity, 0) / inliers.length;
    const cluster = { hits: inliers, offsetSeconds, maximumDeviationSeconds, averageSimilarity };
    if (!best || compareClusters(cluster, best) < 0) best = cluster;
  }
  return best;
}

function compareClusters(left: HitCluster, right: HitCluster): number {
  return right.hits.length - left.hits.length ||
    right.averageSimilarity - left.averageSimilarity ||
    left.maximumDeviationSeconds - right.maximumDeviationSeconds;
}

export function titlesMatch(left: string, right: string): boolean {
  const lhs = normalized(left);
  const rhs = normalized(right);
  return Boolean(lhs && rhs && (lhs === rhs || lhs.includes(rhs) || rhs.includes(lhs)));
}

function phraseSimilarity(left: string, right: string): number {
  const lhs = new Set(tokens(left));
  const rhs = new Set(tokens(right));
  if (lhs.size === 0 || rhs.size === 0) return 0;
  let intersection = 0;
  for (const word of lhs) if (rhs.has(word)) intersection += 1;
  return (2 * intersection) / (lhs.size + rhs.size);
}

function tokens(value: string): string[] {
  return normalized(value).split(" ").filter(Boolean);
}

function normalized(value: string): string {
  return value
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function median(values: number[]): number {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}
