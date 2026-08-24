import {
  parseWebVTT,
  tiktokDurationSeconds,
  tiktokTranscriptURL,
} from "../src/sourceRetrieval.ts";
import { resolveSceneTimeline, titlesMatch } from "../src/timestampResolver.ts";

const corpus = [
  ["I Am Sam", "https://www.tiktok.com/@salvadorlerma/video/7609423841747684622"],
  ["Serendipity", "https://www.tiktok.com/@deenk54/video/7301881307280280875"],
  ["Spider-Man: No Way Home", "https://www.tiktok.com/@movieclips/video/7668011828550667533"],
  ["Desert Flower", "https://www.tiktok.com/@carparkmovies/video/7567803945897364758"],
  ["Believe Me: The Abduction of Lisa McVey", "https://www.tiktok.com/@randommm.clipss/video/7299101557050690858"],
  ["Frequency", "https://www.tiktok.com/@mvdoanl/video/7594524142473415967"],
  ["Rambo: First Blood Part II", "https://www.tiktok.com/@movieclips/video/7665950674969988366"],
  ["The Shallows", "https://www.tiktok.com/@movieclips/video/7390528030755540266"],
  ["Blades of Glory", "https://www.tiktok.com/@oippr4me/video/7595150640184036622"],
  ["Past Lives", "https://www.tiktok.com/@moovie_cl1ps/video/7238357806506577194"],
  ["The Fast and the Furious", "https://www.tiktok.com/@movieclips/video/7650168133856070925"],
  ["47 Ronin", "https://www.tiktok.com/@movieclips/video/7652062923220651277"],
  ["Elysium", "https://www.tiktok.com/@movieclips/video/7672503214318652685"],
  ["Sully", "https://www.tiktok.com/@volpeclips_/video/7311529919635410206"],
  ["Spider-Man 2", "https://www.tiktok.com/@movieclips/video/7408314502216830250"],
  ["Venom", "https://www.tiktok.com/@movieclips/video/7429059680917474606"],
  ["Escape Room: Tournament of Champions", "https://www.tiktok.com/@__moviesclips/video/7274688674460388654"],
  ["Facing the Giants", "https://www.tiktok.com/@random.movie.clipz/video/7271688260731063598"],
  ["Bruce Almighty", "https://www.tiktok.com/@movieclips/video/7453925307268058410"],
  ["Straight Outta Compton", "https://www.tiktok.com/@classicmovieclips/video/7306120073008205087"],
  ["Cars", "https://www.tiktok.com/@random.movie.clipz/video/7271099010977385770"],
  ["Taken", "https://www.tiktok.com/@tubi/video/7368517860580330798"],
  ["Monsters vs. Aliens", "https://www.tiktok.com/@movieclips/video/7433910047551343915"],
  ["The Hurt Locker", "https://www.tiktok.com/@movieclips/video/7616025049971100942"],
  ["Puss in Boots: The Last Wish", "https://www.tiktok.com/@movieclips/video/7468400580055158058"],
  ["Skin", "https://www.tiktok.com/@movieclipzz000/video/7414119018275163434"],
  ["Barefoot", "https://www.tiktok.com/@randommm.clipss/video/7275128092937473323"],
  ["Vivarium", "https://www.tiktok.com/@ski.movie.clips/video/7256630185468890411"],
  ["Gifted", "https://www.tiktok.com/@movieshows_123/video/7259148624876031275"],
  ["21 Jump Street", "https://www.tiktok.com/@movieclips/video/7592310714895813902"],
  ["Tag", "https://www.tiktok.com/@moviewoscw8/video/7209531635170053422"],
  ["Avengers: Endgame", "https://www.tiktok.com/@filmfanatic4l/video/7673270619533856014"],
  ["It Could Happen to You", "https://www.tiktok.com/@film_clips2026/video/7599821862218091798"],
  ["Pitch Perfect", "https://www.tiktok.com/@movieclips/video/7438745802106834218"],
] as const;

const results: Array<Record<string, unknown>> = [];
const requestedIndexes = new Set(
  process.argv.slice(2).map(Number).filter((value) => Number.isInteger(value) && value > 0),
);
const selectedCorpus = corpus
  .map((entry, index) => ({ entry, index }))
  .filter(({ index }) => requestedIndexes.size === 0 || requestedIndexes.has(index + 1));
for (const { entry: [expectedTitle, url], index } of selectedCorpus) {
  const startedAt = performance.now();
  try {
    const page = await fetchText(url);
    const transcriptURL = tiktokTranscriptURL(page);
    const durationSeconds = tiktokDurationSeconds(page);
    if (!transcriptURL || !durationSeconds) {
      results.push({ index: index + 1, expectedTitle, passed: false, reason: "missing_timed_captions" });
      console.log(JSON.stringify(results.at(-1)));
      continue;
    }
    const cues = parseWebVTT(await fetchText(transcriptURL));
    // The TikTok caption supplies a candidate label, exactly as production
    // metadata does. The pass still requires the independent subtitle indexes
    // to return that same title and either two consistent timeline anchors or
    // one exceptionally close match near enough to the clip end that only a
    // short, bounded extrapolation is required.
    const resolution = await resolveSceneTimeline({ cues, durationSeconds, expectedTitle });
    const independentlyVerified = Boolean(
      resolution && (
        resolution.anchorCount >= 2 ||
        (
          resolution.anchorCount === 1 &&
          resolution.averageAnchorSimilarity >= 0.9 &&
          resolution.endExtrapolationSeconds <= 8
        )
      )
    );
    const passed = Boolean(
      resolution &&
      titlesMatch(resolution.canonicalTitle, expectedTitle) &&
      independentlyVerified &&
      resolution.maximumAnchorDeviationSeconds <= 4,
    );
    results.push({
      index: index + 1,
      expectedTitle,
      detectedTitle: resolution?.canonicalTitle ?? null,
      startSeconds: round(resolution?.startSeconds),
      endSeconds: round(resolution?.endSeconds),
      anchors: resolution?.anchorCount ?? 0,
      averageAnchorSimilarity: round(resolution?.averageAnchorSimilarity),
      endExtrapolationSeconds: round(resolution?.endExtrapolationSeconds),
      maximumDeviationSeconds: round(resolution?.maximumAnchorDeviationSeconds),
      passed,
      reason: resolution ? (passed ? "verified" : "title_or_alignment_mismatch") : "no_timeline_match",
      elapsedSeconds: round((performance.now() - startedAt) / 1_000),
    });
  } catch (error) {
    results.push({
      index: index + 1,
      expectedTitle,
      passed: false,
      reason: error instanceof Error ? error.message : "unknown_error",
      elapsedSeconds: round((performance.now() - startedAt) / 1_000),
    });
  }
  console.log(JSON.stringify(results.at(-1)));
}

const passed = results.filter((result) => result.passed).length;
const latencies = results.map((result) => Number(result.elapsedSeconds ?? 0)).sort((a, b) => a - b);
const summary = {
  clips: results.length,
  passed,
  successRate: round(passed / results.length),
  medianSeconds: percentile(latencies, 0.5),
  p95Seconds: percentile(latencies, 0.95),
};
console.log(JSON.stringify({ summary }));
if (summary.successRate < 0.8) process.exitCode = 1;

async function fetchText(url: string): Promise<string> {
  const response = await fetch(url, {
    headers: { "user-agent": "Mozilla/5.0 (iPhone; SceneFind regression)" },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`HTTP_${response.status}`);
  return response.text();
}

function round(value?: number | null): number | null {
  return value === undefined || value === null ? null : Math.round(value * 100) / 100;
}

function percentile(sorted: number[], fraction: number): number | null {
  if (sorted.length === 0) return null;
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}
