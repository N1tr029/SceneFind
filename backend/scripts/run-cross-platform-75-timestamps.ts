import {
  parseWebVTT,
  tiktokDurationSeconds,
  tiktokTranscriptURL,
} from "../src/sourceRetrieval.ts";
import { resolveEpisodeMetadata } from "../src/episodeCatalog.ts";
import { resolveSceneTimeline, titlesMatch } from "../src/timestampResolver.ts";

interface CorpusItem {
  corpusIndex: number;
  category: "movie" | "show";
  title: string;
  url: string;
  season?: number;
  episode?: number;
}

// TikTok members of the signed-in 75-clip corpus. Instagram does not publish
// timed dialogue to SceneFind's unsigned client, so its moment result is
// intentionally reported by the Swift retrieval audit rather than fabricated.
const corpus: CorpusItem[] = [
  { corpusIndex: 1, category: "movie", title: "I Am Sam", url: "https://www.tiktok.com/@salvadorlerma/video/7609423841747684622" },
  { corpusIndex: 2, category: "movie", title: "Believe Me: The Abduction of Lisa McVey", url: "https://www.tiktok.com/@randommm.clipss/video/7291167856643935534" },
  { corpusIndex: 3, category: "movie", title: "Spider-Man: No Way Home", url: "https://www.tiktok.com/@movieclips/video/7668009517312986382" },
  { corpusIndex: 4, category: "movie", title: "Serendipity", url: "https://www.tiktok.com/@deenk54/video/7301881307280280875" },
  { corpusIndex: 5, category: "movie", title: "Spider-Man: No Way Home", url: "https://www.tiktok.com/@movieclips/video/7668011828550667533" },
  { corpusIndex: 6, category: "movie", title: "The Clique", url: "https://www.tiktok.com/@hxm54/video/7256891577187126574" },
  { corpusIndex: 7, category: "movie", title: "Rambo: First Blood Part II", url: "https://www.tiktok.com/@movieclips/video/7665950674969988366" },
  { corpusIndex: 8, category: "movie", title: "Desert Flower", url: "https://www.tiktok.com/@carparkmovies/video/7567803945897364758" },
  { corpusIndex: 9, category: "movie", title: "Frequency", url: "https://www.tiktok.com/@mvdoanl/video/7594524142473415967" },
  { corpusIndex: 10, category: "movie", title: "Pirates of the Caribbean", url: "https://www.tiktok.com/@__moviesclips/video/7337032123280313642" },
  { corpusIndex: 11, category: "movie", title: "Blades of Glory", url: "https://www.tiktok.com/@oippr4me/video/7595150640184036622" },
  { corpusIndex: 12, category: "movie", title: "The Blind Side", url: "https://www.tiktok.com/@johhny.movies/video/7256891639271050539" },
  { corpusIndex: 13, category: "movie", title: "The Fast and the Furious", url: "https://www.tiktok.com/@movieclips/video/7650168133856070925" },
  { corpusIndex: 26, category: "show", title: "Jessie", season: 1, episode: 5, url: "https://www.tiktok.com/@primetelevision888/video/7660500502450294030" },
  { corpusIndex: 27, category: "show", title: "Hangin' with Mr. Cooper", season: 1, episode: 2, url: "https://www.tiktok.com/@tv.shows.movie.clip/video/7672927452393524493" },
  { corpusIndex: 28, category: "show", title: "Dance Moms", url: "https://www.tiktok.com/@liz_secret67/video/7671732028768881940" },
  { corpusIndex: 29, category: "show", title: "Jessie", season: 4, episode: 1, url: "https://www.tiktok.com/@primetelevision888/video/7665587050594323725" },
  { corpusIndex: 30, category: "show", title: "Jessie", season: 3, episode: 2, url: "https://www.tiktok.com/@primetelevision888/video/7670303506355555598" },
  { corpusIndex: 31, category: "show", title: "The Simpsons", url: "https://www.tiktok.com/@gog66ni/video/7672329840732785934" },
  { corpusIndex: 32, category: "show", title: "From", url: "https://www.tiktok.com/@susana12g/video/7653707880159366413" },
  { corpusIndex: 33, category: "show", title: "Good Luck Charlie", season: 2, episode: 15, url: "https://www.tiktok.com/@primetelevision888/video/7667058232807968014" },
  { corpusIndex: 34, category: "show", title: "9-1-1", url: "https://www.tiktok.com/@lee.i.thao/video/7669015789143362829" },
  { corpusIndex: 35, category: "show", title: "Desperate Housewives", url: "https://www.tiktok.com/@voivi35/video/7644333858338475278" },
  { corpusIndex: 36, category: "show", title: "Modern Family", url: "https://www.tiktok.com/@funniest_sitcoms/video/7664216630465006870" },
  { corpusIndex: 37, category: "show", title: "Wizards of Waverly Place", season: 4, episode: 16, url: "https://www.tiktok.com/@primetelevision888/video/7670599842082606349" },
  { corpusIndex: 38, category: "show", title: "9-1-1: Lone Star", url: "https://www.tiktok.com/@dramaclubfox/video/7322948494770130219" },
];

const results: Array<Record<string, unknown>> = [];
for (const item of corpus) {
  const startedAt = performance.now();
  try {
    const page = await fetchText(item.url);
    const transcriptURL = tiktokTranscriptURL(page);
    const durationSeconds = tiktokDurationSeconds(page);
    if (!transcriptURL || !durationSeconds) {
      emit({ ...item, passed: false, reason: "missing_timed_captions" });
      continue;
    }

    const cues = parseWebVTT(await fetchText(transcriptURL));
    const resolution = await resolveSceneTimeline({
      cues,
      durationSeconds,
      expectedTitle: item.title,
    });
    const episode = item.category === "show" && resolution?.seriesTitle && resolution.episodeTitle
      ? await resolveEpisodeMetadata({
          showTitle: resolution.seriesTitle,
          episodeTitle: resolution.episodeTitle,
        })
      : null;
    const timingVerified = Boolean(
      resolution &&
      (
        (resolution.anchorCount >= 2 && resolution.endExtrapolationSeconds <= 20) ||
        (
          resolution.anchorCount === 1 &&
          resolution.averageAnchorSimilarity >= 0.9 &&
          resolution.endExtrapolationSeconds <= 8
        )
      ) &&
      resolution.maximumAnchorDeviationSeconds <= 4 &&
      (
        resolution.heldOutEndAnchorErrorSeconds === null ||
        resolution.heldOutEndAnchorErrorSeconds <= 4
      ),
    );
    const titleMatch = Boolean(
      resolution && titlesMatch(resolution.canonicalTitle, item.title),
    );
    const hasEpisodeGroundTruth = item.season !== undefined && item.episode !== undefined;
    const episodeMatch = hasEpisodeGroundTruth
      ? episode?.seasonNumber === item.season && episode?.episodeNumber === item.episode
      : null;
    const passed = titleMatch && timingVerified && (episodeMatch ?? true);

    emit({
      ...item,
      detectedTitle: resolution?.canonicalTitle ?? null,
      detectedEpisodeTitle: resolution?.episodeTitle ?? null,
      detectedSeason: episode?.seasonNumber ?? null,
      detectedEpisode: episode?.episodeNumber ?? null,
      startSeconds: round(resolution?.startSeconds),
      endSeconds: round(resolution?.endSeconds),
      anchors: resolution?.anchorCount ?? 0,
      maximumDeviationSeconds: round(resolution?.maximumAnchorDeviationSeconds),
      endExtrapolationSeconds: round(resolution?.endExtrapolationSeconds),
      heldOutEndAnchorErrorSeconds: round(resolution?.heldOutEndAnchorErrorSeconds),
      titleMatch,
      timingVerified,
      episodeGroundTruth: hasEpisodeGroundTruth,
      episodeMatch,
      passed,
      reason: resolution ? (passed ? "verified" : "title_episode_or_alignment_mismatch") : "no_timeline_match",
      elapsedSeconds: round((performance.now() - startedAt) / 1_000),
    });
  } catch (error) {
    emit({
      ...item,
      passed: false,
      reason: error instanceof Error ? error.message : "unknown_error",
      elapsedSeconds: round((performance.now() - startedAt) / 1_000),
    });
  }
}

const byCategory = Object.fromEntries(["movie", "show"].map((category) => {
  const categoryResults = results.filter((result) => result.category === category);
  const episodeChecks = categoryResults.filter((result) => result.episodeGroundTruth === true);
  return [category, {
    clips: categoryResults.length,
    timed: categoryResults.filter((result) => result.timingVerified === true).length,
    passed: categoryResults.filter((result) => result.passed === true).length,
    episodeChecks: episodeChecks.length,
    episodeMatches: episodeChecks.filter((result) => result.episodeMatch === true).length,
  }];
}));
console.log(JSON.stringify({ summary: { clips: results.length, byCategory } }));

function emit(result: Record<string, unknown>): void {
  results.push(result);
  console.log(JSON.stringify(result));
}

async function fetchText(url: string): Promise<string> {
  const response = await fetch(url, {
    headers: { "user-agent": "Mozilla/5.0 (iPhone; SceneFind cross-platform regression)" },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`HTTP_${response.status}`);
  return response.text();
}

function round(value?: number | null): number | null {
  return value === undefined || value === null ? null : Math.round(value * 100) / 100;
}
