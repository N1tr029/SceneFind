import type { TranscriptCue } from "./sourceRetrieval";

const QUODB_ORIGIN = "https://api.quodb.com";
const MAX_QUERIES = 8;
const OFFSET_TOLERANCE_SECONDS = 4;
// The title is already fixed when a reference track is used, so this plays the
// same role as the scoped QuoDB floor: tolerate auto-caption noise, and leave
// the single-anchor case to the stricter 0.9 check in finalizeTimeline.
const REFERENCE_SIMILARITY_FLOOR = 0.58;
const REFERENCE_SCAN_LIMIT = 4_000;

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
  return finalizeTimeline(hits, options.cues, options.durationSeconds, Boolean(options.expectedTitle));
}

/// Turns dialogue anchors into a clip window, or refuses. Both subtitle sources
/// end here so a QuoDB match and an OpenSubtitles match are held to the same
/// evidence bar. `scoped` means the title is already known, which is what makes
/// a single strong anchor admissible.
function finalizeTimeline(
  hits: TimelineHit[],
  cues: TranscriptCue[],
  durationSecondsHint: number | undefined,
  scoped: boolean,
): SceneTimelineResolution | null {
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
  const minimumAnchors = scoped ? 1 : 2;
  if (best.hits.length < minimumAnchors) return null;
  const runnerUp = clusters[1];
  if (!scoped && runnerUp &&
      runnerUp.hits.length === best.hits.length &&
      runnerUp.averageSimilarity >= best.averageSimilarity - 0.05) return null;

  const representative = best.hits[0];
  const duration = durationSecondsHint && durationSecondsHint > 0
    ? durationSecondsHint
    : Math.max(...cues.map((cue) => cue.endSeconds));
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

/**
 * Places the clip inside a full subtitle track for an already-identified title.
 *
 * QuoDB is asked which title contains a line, so a title it never indexed can
 * never be placed. Once identification has named the title, a downloaded track
 * answers the narrower question directly, and the anchors it produces go
 * through the same clustering and refusal rules as QuoDB's.
 */
export function resolveSceneTimelineFromReference(options: {
  cues: TranscriptCue[];
  referenceCues: TranscriptCue[];
  durationSeconds?: number;
  canonicalTitle: string;
  seriesTitle?: string | null;
  episodeTitle?: string | null;
  seasonNumber?: number | null;
  episodeNumber?: number | null;
}): SceneTimelineResolution | null {
  if (options.referenceCues.length === 0) return null;
  const phrases = searchablePhrases(options.cues);
  if (phrases.length === 0) return null;

  const index = buildReferenceIndex(options.referenceCues);
  const hits: TimelineHit[] = [];
  for (const phrase of phrases) {
    const match = bestReferenceMatch(phrase, index);
    if (!match) continue;
    hits.push({
      ...phrase,
      canonicalTitle: options.canonicalTitle,
      seriesTitle: options.seriesTitle ?? null,
      episodeTitle: options.episodeTitle ?? null,
      seasonNumber: options.seasonNumber ?? null,
      episodeNumber: options.episodeNumber ?? null,
      canonicalSeconds: match.startSeconds,
      offsetSeconds: match.startSeconds - phrase.startSeconds,
      similarity: match.similarity,
    });
  }
  if (hits.length === 0) return null;
  return finalizeTimeline(hits, options.cues, options.durationSeconds, true);
}

interface ReferenceWindow {
  startSeconds: number;
  tokens: Set<string>;
}

interface ReferenceIndex {
  windows: ReferenceWindow[];
  byToken: Map<string, number[]>;
}

/// A feature's track runs to a couple of thousand cues and one spoken sentence
/// is routinely split across two or three of them, so windows of up to three
/// adjacent cues are indexed — the same shape searchablePhrases builds from the
/// clip side, which is what lets the two be compared directly.
function buildReferenceIndex(cues: TranscriptCue[]): ReferenceIndex {
  const windows: ReferenceWindow[] = [];
  for (let start = 0; start < cues.length; start += 1) {
    let text = "";
    let endSeconds = cues[start].endSeconds;
    for (let length = 1; length <= 3 && start + length <= cues.length; length += 1) {
      const cue = cues[start + length - 1];
      if (length > 1 && cue.startSeconds - endSeconds > 2.5) break;
      text = `${text} ${cue.text}`.replace(/\s+/g, " ").trim();
      endSeconds = cue.endSeconds;
      const words = tokens(text);
      if (words.length === 0 || words.length > 40) continue;
      windows.push({ startSeconds: cues[start].startSeconds, tokens: new Set(words) });
    }
  }
  const byToken = new Map<string, number[]>();
  windows.forEach((window, index) => {
    for (const token of window.tokens) {
      const bucket = byToken.get(token);
      if (bucket) bucket.push(index);
      else byToken.set(token, [index]);
    }
  });
  return { windows, byToken };
}

/// Scoring every phrase against every window would be tens of millions of set
/// operations on a request's CPU budget. A window that clears the similarity
/// floor must share most of the phrase's words, so it is certain to appear in
/// the phrase's rarest token buckets, and only those are scored.
function bestReferenceMatch(
  phrase: SearchPhrase,
  index: ReferenceIndex,
): { startSeconds: number; similarity: number } | null {
  const phraseTokens = new Set(tokens(phrase.text));
  if (phraseTokens.size === 0) return null;
  const buckets = [...phraseTokens]
    .map((token) => index.byToken.get(token) ?? [])
    .filter((bucket) => bucket.length > 0)
    .sort((left, right) => left.length - right.length)
    .slice(0, 4);

  const seen = new Set<number>();
  let best: { startSeconds: number; similarity: number } | null = null;
  for (const bucket of buckets) {
    for (const windowIndex of bucket) {
      if (seen.has(windowIndex)) continue;
      seen.add(windowIndex);
      if (seen.size > REFERENCE_SCAN_LIMIT) return best;
      const window = index.windows[windowIndex];
      const similarity = setSimilarity(phraseTokens, window.tokens);
      if (similarity < REFERENCE_SIMILARITY_FLOOR) continue;
      if (!best || similarity > best.similarity) {
        best = { startSeconds: window.startSeconds, similarity };
      }
    }
  }
  return best;
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
  const lastEnd = Math.max(...candidates.map((candidate) => candidate.endSeconds));
  const lastStart = Math.max(...candidates.map((candidate) => candidate.startSeconds));
  const span = Math.max(1, lastStart - firstStart);

  const append = (candidate: typeof candidates[number] | undefined) => {
    if (!candidate || selected.length >= MAX_QUERIES) return;
    if (selected.some((item) =>
      item.startSeconds === candidate.startSeconds && item.endSeconds === candidate.endSeconds
    )) return;
    const { score: _, ...phrase } = candidate;
    selected.push(phrase);
  };
  // Reserve the clip boundaries before quality ranking. Matching the first and
  // last searchable sentences to the full-episode subtitle clock gives the
  // actual shared window; spending all eight queries on middle dialogue can
  // identify an episode while still leaving its beginning or ending unmeasured.
  append(byQuality.find((candidate) => candidate.startSeconds === firstStart));
  append(byQuality.find((candidate) => candidate.endSeconds === lastEnd));

  if (span <= 300) {
    for (const candidate of byQuality) {
      if (selected.some((item) => Math.abs(item.startSeconds - candidate.startSeconds) < 3)) continue;
      append(candidate);
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
    append(candidate);
  }
  for (const candidate of byQuality) {
    if (selected.length === MAX_QUERIES) break;
    if (selected.some((item) => Math.abs(item.startSeconds - candidate.startSeconds) < 3)) continue;
    append(candidate);
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
  return setSimilarity(new Set(tokens(left)), new Set(tokens(right)));
}

function setSimilarity(left: Set<string>, right: Set<string>): number {
  if (left.size === 0 || right.size === 0) return 0;
  let intersection = 0;
  for (const word of left) if (right.has(word)) intersection += 1;
  return (2 * intersection) / (left.size + right.size);
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
