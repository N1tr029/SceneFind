import {
  parseTimedCaptions,
  tiktokDurationSeconds,
  tiktokTranscriptURL,
} from "../src/sourceRetrieval.ts";
import { resolveSceneTimeline, searchablePhrases, titlesMatch } from "../src/timestampResolver.ts";
import { fetchEpisodeGuide, resolveEpisodeMetadata } from "../src/episodeCatalog.ts";
import { resolveEpisodeEvidence } from "../src/episodeEvidence.ts";
import type { Env } from "../src/types.ts";
import { searchWeb } from "../src/webSearch.ts";

interface CorpusItem {
  title: string;
  season: number;
  episode: number;
  url: string;
}

const corpus: CorpusItem[] = [
  { title: "The Office", season: 3, episode: 18, url: "https://www.tiktok.com/@theofficefy/video/7418989755909623047" },
  { title: "Friends", season: 5, episode: 16, url: "https://www.tiktok.com/@oscarmayorga_40/video/7598002718396976391" },
  { title: "Friends", season: 2, episode: 5, url: "https://www.tiktok.com/@wwreynoldsfoundation/video/7517327275877059870" },
  { title: "Friends", season: 3, episode: 14, url: "https://www.tiktok.com/@shortclipsguy16/video/7320657625585028382" },
  { title: "The Office", season: 1, episode: 3, url: "https://www.tiktok.com/@ho.film/video/7645277742275104013" },
  { title: "The Office", season: 3, episode: 9, url: "https://www.tiktok.com/@1clip2watch/video/7320335053869944070" },
  { title: "Friends", season: 1, episode: 22, url: "https://www.tiktok.com/@friendss.clipssb/video/7451458348597185797" },
  { title: "Friends", season: 5, episode: 11, url: "https://www.tiktok.com/@friendss.clipssb/video/7442532377282301240" },
  { title: "How I Met Your Mother", season: 4, episode: 2, url: "https://www.tiktok.com/@swarleymemes/video/7277933440396184865" },
  { title: "How I Met Your Mother", season: 4, episode: 19, url: "https://www.tiktok.com/@doubledstatue/video/7383997694261562670" },
  { title: "How I Met Your Mother", season: 4, episode: 20, url: "https://www.tiktok.com/@doubledstatue/video/7384290360987520298" },
  { title: "How I Met Your Mother", season: 1, episode: 1, url: "https://www.tiktok.com/@gege.edits3/video/7650602779299319070" },
  { title: "How I Met Your Mother", season: 8, episode: 20, url: "https://www.tiktok.com/@himymaddict/video/7639994703336721686" },
  { title: "How I Met Your Mother", season: 3, episode: 13, url: "https://www.tiktok.com/@eurencenain/video/7207120987521813786" },
  { title: "How I Met Your Mother", season: 4, episode: 3, url: "https://www.tiktok.com/@doubledstatue/video/7207947480246373674" },
  { title: "How I Met Your Mother", season: 4, episode: 9, url: "https://www.tiktok.com/@doubledstatue/video/7210155439479098670" },
  { title: "How I Met Your Mother", season: 3, episode: 13, url: "https://www.tiktok.com/@doubledstatue/video/7206833271458516270" },
  { title: "How I Met Your Mother", season: 4, episode: 21, url: "https://www.tiktok.com/@doubledstatue/video/7384336334434962734" },
  { title: "How I Met Your Mother", season: 5, episode: 18, url: "https://www.tiktok.com/@doubledstatue/video/7211642379177200942" },
  { title: "How I Met Your Mother", season: 5, episode: 13, url: "https://www.tiktok.com/@doubledstatue/video/7387687104672763179" },
  { title: "How I Met Your Mother", season: 5, episode: 6, url: "https://www.tiktok.com/@doubledstatue/video/7385284532519521582" },
  { title: "How I Met Your Mother", season: 5, episode: 1, url: "https://www.tiktok.com/@doubledstatue/video/7384702296074210606" },
  { title: "How I Met Your Mother", season: 5, episode: 15, url: "https://www.tiktok.com/@doubledstatue/video/7236578003759795498" },
  { title: "How I Met Your Mother", season: 6, episode: 2, url: "https://www.tiktok.com/@swarleymemes/video/7202147026102914309" },
  { title: "Friends", season: 10, episode: 1, url: "https://www.tiktok.com/@shawnston1/video/7645478896741272845" },
  { title: "Friends", season: 6, episode: 22, url: "https://www.tiktok.com/@_.user8675309._/video/7304289395706842398" },
  { title: "The Big Bang Theory", season: 6, episode: 3, url: "https://www.tiktok.com/@harvey.adams68/video/7615684470921841942" },
  { title: "Game of Thrones", season: 1, episode: 7, url: "https://www.tiktok.com/@choomach/video/7631610795696065814" },
  { title: "Game of Thrones", season: 2, episode: 7, url: "https://www.tiktok.com/@viralshotsindia7/video/7617101057876905238" },
  { title: "Game of Thrones", season: 2, episode: 10, url: "https://www.tiktok.com/@hatchinghistory/video/7210768920955915566" },
];

const results: Array<Record<string, unknown>> = [];
const requestedIndexes = new Set(
  process.argv.slice(2).map(Number).filter((value) => Number.isInteger(value) && value > 0),
);

for (const [index, item] of corpus.entries()) {
  if (requestedIndexes.size > 0 && !requestedIndexes.has(index + 1)) continue;
  const startedAt = performance.now();
  try {
    const page = await fetchText(item.url);
    const transcriptURL = tiktokTranscriptURL(page);
    const durationSeconds = tiktokDurationSeconds(page);
    if (!transcriptURL || !durationSeconds) {
      results.push({ index: index + 1, ...item, passed: false, reason: "missing_timed_captions" });
      console.log(JSON.stringify(results.at(-1)));
      continue;
    }
    const rawTranscript = await fetchText(transcriptURL);
    const cues = parseTimedCaptions(rawTranscript);
    if (process.env.SCENEFIND_VERBOSE === "1") {
      const diagnosticPhrases = searchablePhrases(cues).map((phrase) => phrase.text);
      const searches = process.env.SEARCH_API_KEY
        ? await Promise.all(diagnosticPhrases.map(async (phrase) => ({
            phrase,
            results: (await searchWeb({
              apiKey: process.env.SEARCH_API_KEY,
              query: `"${phrase.replaceAll('"', "")}" "${item.title}" episode transcript`,
              region: "US",
            })).slice(0, 5),
          })))
        : [];
      const diagnosticGuide = await fetchEpisodeGuide({ showTitle: item.title });
      const expectedGuideEpisode = diagnosticGuide?.episodes.find((episode) =>
        episode.seasonNumber === item.season && episode.episodeNumber === item.episode
      );
      const candidateTranscriptResults = process.env.SEARCH_API_KEY && expectedGuideEpisode
        ? (await searchWeb({
            apiKey: process.env.SEARCH_API_KEY,
            query: `"${item.title}" "${expectedGuideEpisode.episodeTitle}" transcript`,
            region: "US",
          })).slice(0, 10)
        : [];
      console.log(JSON.stringify({
        diagnostic: {
          index: index + 1,
          caption: tiktokCaption(page),
          rawTranscript: rawTranscript.slice(0, 2_000),
          cues: cues.slice(0, 30),
          phrases: diagnosticPhrases,
          searches,
          candidateTranscriptResults,
        },
      }));
    }
    const evidenceResolution = process.env.SEARCH_API_KEY || process.env.GROQ_API_KEY
      ? await resolveEpisodeEvidence({
          SEARCH_API_KEY: process.env.SEARCH_API_KEY,
          GROQ_API_KEY: process.env.GROQ_API_KEY ?? "",
          GROQ_MODEL: process.env.GROQ_MODEL ?? "openai/gpt-oss-120b",
        } as Env, {
          showTitle: item.title,
          detectedDialogue: cues.map((cue) => cue.text).join(" "),
          transcriptCues: cues,
          visualEvidence: [],
          captionEvidence: tiktokCaption(page),
          candidateSeason: null,
          candidateEpisode: null,
        }, process.env.SCENEFIND_VERBOSE === "1" ? {
          searcher: async (options: Parameters<typeof searchWeb>[0]) => {
            const searchResults = await searchWeb(options);
            console.log(JSON.stringify({ evidenceSearch: {
              query: options.query,
              results: searchResults.slice(0, 12),
            } }));
            return searchResults;
          },
          diagnostic: (snapshot) => console.log(JSON.stringify({ episodeEvidence: snapshot })),
        } : undefined)
      : null;
    const resolution = await resolveSceneTimeline({
      cues,
      durationSeconds,
      expectedTitle: item.title,
    });
    const episode = resolution?.seriesTitle && resolution.episodeTitle
      ? await resolveEpisodeMetadata({
          showTitle: resolution.seriesTitle,
          episodeTitle: resolution.episodeTitle,
        })
      : null;
    const timingVerified = Boolean(
      resolution && (
        (
          resolution.anchorCount >= 2 &&
          resolution.endExtrapolationSeconds <= 20
        ) ||
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
    // A multi-anchor timed subtitle hit is stronger than a single untimed web
    // result, so it wins a disagreement exactly as it does in production.
    const timelineEpisode = resolution && episode && titlesMatch(resolution.canonicalTitle, item.title)
      ? episode
      : null;
    const detectedSeason = timelineEpisode?.seasonNumber ?? evidenceResolution?.seasonNumber ?? null;
    const detectedEpisode = timelineEpisode?.episodeNumber ?? evidenceResolution?.episodeNumber ?? null;
    const passed = detectedSeason === item.season && detectedEpisode === item.episode;
    results.push({
      index: index + 1,
      expectedTitle: item.title,
      expectedSeason: item.season,
      expectedEpisode: item.episode,
      detectedTitle: resolution?.canonicalTitle ?? null,
      detectedEpisodeTitle: resolution?.episodeTitle ?? null,
      detectedSeason,
      detectedEpisode,
      episodeEvidence: timelineEpisode
        ? `Timed multi-anchor dialogue matched ${resolution?.episodeTitle}; canonical guide mapping won.${
            evidenceResolution?.verified && (
              evidenceResolution.seasonNumber !== timelineEpisode.seasonNumber ||
              evidenceResolution.episodeNumber !== timelineEpisode.episodeNumber
            ) ? ` Rejected conflicting untimed web candidate S${evidenceResolution.seasonNumber}E${evidenceResolution.episodeNumber}.` : ""
          }`
        : evidenceResolution?.evidence ?? null,
      startSeconds: round(resolution?.startSeconds),
      endSeconds: round(resolution?.endSeconds),
      anchors: resolution?.anchorCount ?? 0,
      maximumDeviationSeconds: round(resolution?.maximumAnchorDeviationSeconds),
      endExtrapolationSeconds: round(resolution?.endExtrapolationSeconds),
      endAnchorDeviationSeconds: round(resolution?.endAnchorDeviationSeconds),
      heldOutEndAnchorErrorSeconds: round(resolution?.heldOutEndAnchorErrorSeconds),
      timingVerified,
      passed,
      reason: passed ? "episode_verified" : "episode_not_verified",
      elapsedSeconds: round((performance.now() - startedAt) / 1_000),
    });
  } catch (error) {
    results.push({
      index: index + 1,
      expectedTitle: item.title,
      expectedSeason: item.season,
      expectedEpisode: item.episode,
      passed: false,
      reason: error instanceof Error ? error.message : "unknown_error",
      elapsedSeconds: round((performance.now() - startedAt) / 1_000),
    });
  }
  console.log(JSON.stringify(results.at(-1)));
}

const passed = results.filter((result) => result.passed).length;
const latencies = results.map((result) => Number(result.elapsedSeconds ?? 0)).sort((a, b) => a - b);
const heldOutEndpointErrors = results.flatMap((result) =>
  typeof result.heldOutEndAnchorErrorSeconds === "number"
    ? [result.heldOutEndAnchorErrorSeconds]
    : []
).sort((left, right) => left - right);
const summary = {
  clips: results.length,
  passed,
  successRate: round(passed / results.length),
  medianSeconds: percentile(latencies, 0.5),
  p95Seconds: percentile(latencies, 0.95),
  heldOutEndpointClips: heldOutEndpointErrors.length,
  heldOutEndpointWithinTwoSeconds: heldOutEndpointErrors.filter((error) => error <= 2).length,
  heldOutEndpointWithinFourSeconds: heldOutEndpointErrors.filter((error) => error <= 4).length,
  heldOutEndpointMedianErrorSeconds: percentile(heldOutEndpointErrors, 0.5),
  heldOutEndpointP95ErrorSeconds: percentile(heldOutEndpointErrors, 0.95),
};
console.log(JSON.stringify({ summary }));
if (summary.successRate < 0.9) process.exitCode = 1;

async function fetchText(url: string): Promise<string> {
  const response = await fetch(url, {
    headers: { "user-agent": "Mozilla/5.0 (iPhone; SceneFind regression)" },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`HTTP_${response.status}`);
  return response.text();
}

function tiktokCaption(page: string): string {
  const match = page.match(/"desc":"((?:\\.|[^"\\])*)"/);
  if (!match) return "";
  try {
    return JSON.parse(`"${match[1]}"`) as string;
  } catch {
    return match[1];
  }
}

function round(value?: number | null): number | null {
  return value === undefined || value === null ? null : Math.round(value * 100) / 100;
}

function percentile(sorted: number[], fraction: number): number | null {
  if (sorted.length === 0) return null;
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}
