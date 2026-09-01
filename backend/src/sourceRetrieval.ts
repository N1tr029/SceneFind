import { Buffer } from "node:buffer";
import type { AnalysisRequest } from "./types";

const USER_AGENT =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " +
  "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const MAX_PAGE_BYTES = 2_000_000;
const MAX_MEDIA_BYTES = 8_000_000;
const MAX_IMAGE_BYTES = 2_000_000;

export interface RetrievedEvidence {
  finalURL?: string;
  title?: string;
  description?: string;
  author?: string;
  dialogue?: string;
  transcriptCues?: TranscriptCue[];
  durationSeconds?: number;
  thumbnailURL?: string;
  thumbnailDataBase64?: string;
  thumbnailMimeType?: string;
  mediaURL?: string;
  mediaDataBase64?: string;
  mediaMimeType?: string;
}

export interface TranscriptCue {
  startSeconds: number;
  endSeconds: number;
  text: string;
}

interface TranscriptEvidence {
  text: string;
  cues: TranscriptCue[];
}

export async function retrieveEvidence(request: AnalysisRequest): Promise<RetrievedEvidence> {
  if (request.sourceDataBase64) {
    return {
      mediaDataBase64: request.sourceDataBase64,
      mediaMimeType: safeMimeType(request.sourceMimeType),
      description: request.sourceText,
    };
  }
  if (request.sourceText) return { description: request.sourceText.slice(0, 8_000) };
  if (!request.sourceURL) return {};

  const sourceURL = safePublicURL(request.sourceURL);
  // TikTok and YouTube sometimes deny the page request to cloud IP ranges even
  // while their public oEmbed endpoint remains available. Start that request
  // first so a blocked page can still yield a real title and preview image.
  const oEmbedTask = fetchOEmbed(sourceURL).catch(() => null);
  let pageResponse: Response;
  try {
    pageResponse = await fetchWithRetry(sourceURL, {
      headers: { "user-agent": USER_AGENT, "accept-language": "en-US,en;q=0.9" },
      redirect: "follow",
    }, 8_000);
  } catch (error) {
    const fallback = await oEmbedEvidence(sourceURL, await oEmbedTask);
    if (fallback) return fallback;
    throw error;
  }
  if (!pageResponse.ok) {
    const fallback = await oEmbedEvidence(sourceURL, await oEmbedTask);
    if (fallback) return fallback;
    throw new RetrievalError(`Source returned HTTP ${pageResponse.status}.`);
  }
  const finalURL = safePublicURL(pageResponse.url || sourceURL.toString());
  const directMimeType = (pageResponse.headers.get("content-type") ?? "")
    .split(";")[0]
    .toLowerCase();
  if (/^(video|audio)\//.test(directMimeType)) {
    const media = await binaryResponse(pageResponse, MAX_MEDIA_BYTES, ["video/", "audio/"]);
    return {
      finalURL: finalURL.toString(),
      mediaDataBase64: media.base64,
      mediaMimeType: media.mimeType,
    };
  }
  if (directMimeType.startsWith("image/")) {
    const media = await binaryResponse(pageResponse, MAX_IMAGE_BYTES, ["image/"]);
    return {
      finalURL: finalURL.toString(),
      mediaDataBase64: media.base64,
      mediaMimeType: media.mimeType,
    };
  }
  const page = await limitedText(pageResponse, MAX_PAGE_BYTES);
  const player = youtubePlayerResponse(page);
  const metadata = pageMetadata(page);

  const youtubeTranscriptTask = fetchYouTubeTranscript(player).catch(() => null);
  const tiktokTranscriptTask = fetchTikTokTranscript(page).catch(() => null);
  const oEmbed = await oEmbedTask;
  const [youtubeTranscript, tiktokTranscript] = await Promise.all([
    youtubeTranscriptTask,
    tiktokTranscriptTask,
  ]);
  const transcript = youtubeTranscript ?? tiktokTranscript;

  const mediaURL = firstPublicURL([
    metadata.videoURL,
    directMediaURL(player),
    tiktokMediaURL(page),
  ]);
  const thumbnailURL = firstPublicURL([
    metadata.thumbnailURL,
    oEmbed?.thumbnail_url,
    youtubeThumbnail(player),
  ]);
  const [media, thumbnail] = await Promise.all([
    mediaURL ? fetchBinary(mediaURL, MAX_MEDIA_BYTES, ["video/", "audio/"]).catch(() => null) : null,
    thumbnailURL ? fetchBinary(thumbnailURL, MAX_IMAGE_BYTES, ["image/"]).catch(() => null) : null,
  ]);

  return {
    finalURL: finalURL.toString(),
    title: oEmbed?.title ?? metadata.title,
    description: metadata.description,
    author: oEmbed?.author_name ?? metadata.author,
    dialogue: transcript?.text,
    transcriptCues: transcript?.cues,
    durationSeconds: sourceDurationSeconds(player, page),
    thumbnailURL: thumbnailURL?.toString(),
    thumbnailDataBase64: thumbnail?.base64,
    thumbnailMimeType: thumbnail?.mimeType,
    mediaURL: mediaURL?.toString(),
    mediaDataBase64: media?.base64,
    mediaMimeType: media?.mimeType,
  };
}

export function evidenceParts(request: AnalysisRequest, evidence: RetrievedEvidence): unknown[] {
  const text = [
    "Identify this movie or television clip using only the supplied evidence.",
    evidence.finalURL ? `Resolved source: ${evidence.finalURL}` : null,
    evidence.title ? `Public title: ${evidence.title}` : null,
    evidence.author ? `Public author: ${evidence.author}` : null,
    evidence.description ? `Public caption/description: ${evidence.description.slice(0, 6_000)}` : null,
    evidence.dialogue ? `Platform dialogue track: ${evidence.dialogue.slice(0, 8_000)}` : null,
    request.region ? `Viewer region: ${request.region}` : null,
  ].filter((value): value is string => Boolean(value)).join("\n");
  const parts: unknown[] = [{ text }];
  if (evidence.thumbnailDataBase64 && evidence.thumbnailMimeType) {
    parts.push({ inlineData: { data: evidence.thumbnailDataBase64, mimeType: evidence.thumbnailMimeType } });
  }
  if (evidence.mediaDataBase64 && evidence.mediaMimeType) {
    parts.push({ inlineData: { data: evidence.mediaDataBase64, mimeType: evidence.mediaMimeType } });
  } else if (hasRemoteYouTubeVideo(evidence)) {
    // Gemini's generateContent API accepts a public YouTube URL as fileData.
    // This preserves visual/audio analysis when YouTube exposes only a
    // signatureCipher instead of a directly downloadable media URL.
    parts.push({ fileData: { fileUri: evidence.finalURL } });
  }
  return parts;
}

export function hasRemoteYouTubeVideo(evidence: RetrievedEvidence): boolean {
  if (!evidence.finalURL || evidence.mediaDataBase64) return false;
  try {
    const host = new URL(evidence.finalURL).hostname.toLowerCase();
    return host === "youtu.be" || host === "youtube.com" || host.endsWith(".youtube.com");
  } catch {
    return false;
  }
}

export class RetrievalError extends Error {}

interface PageMetadata {
  title?: string;
  description?: string;
  author?: string;
  thumbnailURL?: string;
  videoURL?: string;
}

function pageMetadata(html: string): PageMetadata {
  return {
    title: metaContent(html, "og:title") ?? pageTitle(html) ?? undefined,
    description:
      metaContent(html, "og:description") ??
      metaContent(html, "description") ??
      undefined,
    author: metaContent(html, "author") ?? undefined,
    thumbnailURL:
      metaContent(html, "og:image") ??
      metaContent(html, "twitter:image") ??
      undefined,
    videoURL:
      metaContent(html, "og:video:secure_url") ??
      metaContent(html, "og:video") ??
      undefined,
  };
}

function metaContent(html: string, property: string): string | null {
  const escaped = property.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  for (const pattern of [
    new RegExp(`<meta[^>]*(?:property|name)=["']${escaped}["'][^>]*content=["']([^"']*)["']`, "i"),
    new RegExp(`<meta[^>]*content=["']([^"']*)["'][^>]*(?:property|name)=["']${escaped}["']`, "i"),
  ]) {
    const value = html.match(pattern)?.[1];
    if (value) return decodeHTML(value);
  }
  return null;
}

function pageTitle(html: string): string | null {
  const value = html.match(/<title[^>]*>([^<]+)<\/title>/i)?.[1];
  return value ? decodeHTML(value) : null;
}

function youtubePlayerResponse(html: string): Record<string, unknown> | null {
  for (const marker of ["ytInitialPlayerResponse =", "ytInitialPlayerResponse="]) {
    const start = html.indexOf(marker);
    if (start < 0) continue;
    const jsonStart = html.indexOf("{", start + marker.length);
    const json = balancedJSON(html, jsonStart);
    if (!json) continue;
    try {
      return JSON.parse(json) as Record<string, unknown>;
    } catch {
      continue;
    }
  }
  return null;
}

function balancedJSON(value: string, start: number): string | null {
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < value.length; index += 1) {
    const character = value[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') inString = false;
      continue;
    }
    if (character === '"') inString = true;
    else if (character === "{") depth += 1;
    else if (character === "}" && --depth === 0) return value.slice(start, index + 1);
  }
  return null;
}

function balancedJSONArray(value: string, start: number): string | null {
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < value.length; index += 1) {
    const character = value[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') inString = false;
      continue;
    }
    if (character === '"') inString = true;
    else if (character === "[") depth += 1;
    else if (character === "]" && --depth === 0) return value.slice(start, index + 1);
  }
  return null;
}

function directMediaURL(player: Record<string, unknown> | null): string | undefined {
  const streaming = object(player?.streamingData);
  const formats = [
    ...array(streaming?.formats),
    ...array(streaming?.adaptiveFormats),
  ];
  return formats
    .map(object)
    .find((format) => typeof format?.url === "string" && String(format.mimeType).startsWith("video/"))
    ?.url as string | undefined;
}

function youtubeThumbnail(player: Record<string, unknown> | null): string | undefined {
  const details = object(player?.videoDetails);
  const thumbnail = object(details?.thumbnail);
  return array(thumbnail?.thumbnails).map(object).at(-1)?.url as string | undefined;
}

async function fetchYouTubeTranscript(
  player: Record<string, unknown> | null,
): Promise<TranscriptEvidence | null> {
  const captions = object(player?.captions);
  const renderer = object(captions?.playerCaptionsTracklistRenderer);
  const track = array(renderer?.captionTracks).map(object).find(
    (candidate) => typeof candidate?.baseUrl === "string",
  );
  if (!track?.baseUrl) return null;
  const url = safePublicURL(String(track.baseUrl));
  url.searchParams.set("fmt", "json3");
  const response = await fetchWithRetry(url, { headers: { "user-agent": USER_AGENT } }, 5_000);
  if (!response.ok) return null;
  const body = await response.json() as {
    events?: Array<{
      tStartMs?: number;
      dDurationMs?: number;
      segs?: Array<{ utf8?: string }>;
    }>;
  };
  const cues = (body.events ?? []).flatMap((event): TranscriptCue[] => {
    const text = (event.segs ?? []).map((segment) => segment.utf8 ?? "")
      .join("")
      .replace(/\s+/g, " ")
      .trim();
    if (text.length < 2 || !Number.isFinite(event.tStartMs)) return [];
    const startSeconds = Number(event.tStartMs) / 1_000;
    return [{
      startSeconds,
      endSeconds: startSeconds + Math.max(0, Number(event.dDurationMs ?? 0) / 1_000),
      text,
    }];
  });
  return transcriptEvidence(cues);
}

async function fetchTikTokTranscript(html: string): Promise<TranscriptEvidence | null> {
  const transcriptURL = tiktokTranscriptURL(html);
  if (!transcriptURL) return null;
  const url = safePublicURL(transcriptURL);
  const response = await fetchWithRetry(url, { headers: { "user-agent": USER_AGENT } }, 5_000);
  if (!response.ok) return null;
  return transcriptEvidence(parseTimedCaptions(await limitedText(response, 1_000_000)));
}

export function tiktokTranscriptURL(html: string): string | null {
  const subtitleInfos = tiktokSubtitleInfos(html);
  const info = subtitleInfos.find((item) =>
    typeof item.Url === "string" &&
    (String(item.LanguageCodeName ?? "").toLowerCase().startsWith("en") ||
      String(item.LanguageID ?? "") === "2")
  ) ?? subtitleInfos.find((item) => typeof item.Url === "string");
  return info?.Url ?? null;
}

export function tiktokDurationSeconds(html: string): number | null {
  const raw = html.match(/"duration":(\d+(?:\.\d+)?)/)?.[1];
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) return null;
  // TikTok's public JSON normally truncates player duration to an integer.
  // The midpoint removes the systematic early bias while preserving a real
  // fractional value if the platform starts publishing one.
  return raw?.includes(".") ? value : value + 0.5;
}

function tiktokSubtitleInfos(html: string): Array<{
  Url?: string;
  LanguageCodeName?: string;
  LanguageID?: string;
}> {
  const marker = '"subtitleInfos":';
  const start = html.indexOf(marker);
  if (start < 0) return [];
  const arrayStart = html.indexOf("[", start + marker.length);
  const json = balancedJSONArray(html, arrayStart);
  if (!json) return [];
  try {
    return JSON.parse(json) as Array<{
      Url?: string;
      LanguageCodeName?: string;
      LanguageID?: string;
    }>;
  } catch {
    return [];
  }
}

export function parseWebVTT(value: string): TranscriptCue[] {
  const cues: TranscriptCue[] = [];
  const pattern = /(?:^|\n)(\d{2}:\d{2}:\d{2}[.,]\d{3})\s+-->\s+(\d{2}:\d{2}:\d{2}[.,]\d{3})[^\n]*\n([\s\S]*?)(?=\n\s*\n|$)/g;
  for (const match of value.replace(/\r/g, "").matchAll(pattern)) {
    const text = match[3]
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim();
    const startSeconds = vttSeconds(match[1]);
    const endSeconds = vttSeconds(match[2]);
    if (text.length >= 2 && startSeconds !== null && endSeconds !== null && endSeconds >= startSeconds) {
      cues.push({ startSeconds, endSeconds, text });
    }
  }
  return cues;
}

/** TikTok currently serves both WebVTT and a JSON `utterances` shape from the
 * same subtitle metadata field. Treat them as one timed-caption contract. */
export function parseTimedCaptions(value: string): TranscriptCue[] {
  try {
    const payload = JSON.parse(value) as {
      utterances?: Array<{ text?: unknown; start_time?: unknown; end_time?: unknown }>;
    };
    if (Array.isArray(payload.utterances)) {
      const cues = payload.utterances.flatMap((utterance): TranscriptCue[] => {
        const text = typeof utterance.text === "string"
          ? utterance.text.replace(/\s+/g, " ").trim()
          : "";
        const startMs = Number(utterance.start_time);
        const endMs = Number(utterance.end_time);
        if (!text || !Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs < startMs) {
          return [];
        }
        return [{ startSeconds: startMs / 1_000, endSeconds: endMs / 1_000, text }];
      });
      if (cues.length > 0) return cues;
    }
  } catch {
    // WebVTT is not JSON; parse it below.
  }
  return parseWebVTT(value);
}

function transcriptEvidence(cues: TranscriptCue[]): TranscriptEvidence | null {
  const text = cues.map((cue) => cue.text).join(" ").replace(/\s+/g, " ").trim();
  return text.length >= 8 ? { text, cues } : null;
}

function vttSeconds(value: string): number | null {
  const parts = value.replace(",", ".").split(":").map(Number);
  if (parts.length !== 3 || parts.some((part) => !Number.isFinite(part))) return null;
  return parts[0] * 3_600 + parts[1] * 60 + parts[2];
}

function sourceDurationSeconds(
  player: Record<string, unknown> | null,
  html: string,
): number | undefined {
  const details = object(player?.videoDetails);
  const youtubeSeconds = Number(details?.lengthSeconds);
  if (Number.isFinite(youtubeSeconds) && youtubeSeconds > 0) return youtubeSeconds;
  return tiktokDurationSeconds(html) ?? undefined;
}

function tiktokMediaURL(html: string): string | undefined {
  for (const name of ["playAddr", "downloadAddr"]) {
    const escaped = html.match(new RegExp(`"${name}":"(https:[^"]+)"`))?.[1];
    if (escaped) return escaped.replace(/\\u002F/g, "/").replace(/\\\//g, "/");
  }
  return undefined;
}

async function fetchOEmbed(url: URL): Promise<{
  title?: string;
  author_name?: string;
  thumbnail_url?: string;
} | null> {
  const host = url.hostname.toLowerCase();
  let endpoint: URL | null = null;
  if (host.includes("youtube.com") || host === "youtu.be") {
    endpoint = new URL("https://www.youtube.com/oembed");
  } else if (host.includes("tiktok.com")) {
    endpoint = new URL("https://www.tiktok.com/oembed");
  }
  if (!endpoint) return null;
  endpoint.searchParams.set("url", url.toString());
  endpoint.searchParams.set("format", "json");
  const response = await fetchWithRetry(endpoint, { headers: { "user-agent": USER_AGENT } }, 5_000);
  return response.ok ? response.json() : null;
}

async function oEmbedEvidence(
  sourceURL: URL,
  oEmbed: Awaited<ReturnType<typeof fetchOEmbed>>,
): Promise<RetrievedEvidence | null> {
  if (!oEmbed) return null;
  const thumbnailURL = firstPublicURL([oEmbed.thumbnail_url]);
  const thumbnail = thumbnailURL
    ? await fetchBinary(thumbnailURL, MAX_IMAGE_BYTES, ["image/"]).catch(() => null)
    : null;
  return {
    finalURL: sourceURL.toString(),
    title: oEmbed.title,
    author: oEmbed.author_name,
    thumbnailURL: thumbnailURL?.toString(),
    thumbnailDataBase64: thumbnail?.base64,
    thumbnailMimeType: thumbnail?.mimeType,
  };
}

async function fetchBinary(
  url: URL,
  maximumBytes: number,
  allowedPrefixes: string[],
): Promise<{ base64: string; mimeType: string }> {
  const response = await fetchWithRetry(url, { headers: { "user-agent": USER_AGENT } }, 8_000);
  if (!response.ok) throw new RetrievalError(`Media returned HTTP ${response.status}.`);
  return binaryResponse(response, maximumBytes, allowedPrefixes);
}

async function binaryResponse(
  response: Response,
  maximumBytes: number,
  allowedPrefixes: string[],
): Promise<{ base64: string; mimeType: string }> {
  const mimeType = (response.headers.get("content-type") ?? "").split(";")[0].toLowerCase();
  if (!allowedPrefixes.some((prefix) => mimeType.startsWith(prefix))) {
    throw new RetrievalError("Source returned an unsupported media type.");
  }
  const length = Number(response.headers.get("content-length"));
  if (Number.isFinite(length) && length > maximumBytes) throw new RetrievalError("Media is too large.");
  const data = await response.arrayBuffer();
  if (data.byteLength > maximumBytes) throw new RetrievalError("Media is too large.");
  return { base64: Buffer.from(data).toString("base64"), mimeType };
}

async function limitedText(response: Response, maximumBytes: number): Promise<string> {
  const data = await response.arrayBuffer();
  if (data.byteLength > maximumBytes) throw new RetrievalError("Source page is too large.");
  return new TextDecoder().decode(data);
}

async function fetchWithRetry(
  url: URL,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      let currentURL = url;
      for (let redirects = 0; redirects <= 3; redirects += 1) {
        const response = await fetch(currentURL, {
          ...init,
          redirect: "manual",
          signal: AbortSignal.timeout(timeoutMs),
        });
        if (response.status >= 300 && response.status < 400) {
          const location = response.headers.get("location");
          if (!location || redirects === 3) throw new RetrievalError("Too many source redirects.");
          currentURL = safePublicURL(new URL(location, currentURL).toString());
          continue;
        }
        if (response.status !== 429 && response.status < 500) return response;
        lastError = new RetrievalError(`Temporary source error ${response.status}.`);
        break;
      }
    } catch (error) {
      lastError = error;
    }
    if (attempt === 0) await new Promise((resolve) => setTimeout(resolve, 350));
  }
  throw lastError instanceof Error ? lastError : new RetrievalError("Source unavailable.");
}

function safePublicURL(raw: string): URL {
  const url = new URL(raw);
  if (url.protocol !== "https:" || isPrivateHost(url.hostname)) {
    throw new RetrievalError("Private or non-HTTPS sources are not allowed.");
  }
  return url;
}

function firstPublicURL(values: Array<string | undefined>): URL | undefined {
  for (const value of values) {
    if (!value) continue;
    try {
      return safePublicURL(value);
    } catch {
      continue;
    }
  }
  return undefined;
}

function isPrivateHost(hostname: string): boolean {
  const host = hostname.toLowerCase();
  if (host === "localhost" || host.endsWith(".local") || host.endsWith(".internal")) return true;
  if (/^(127|10|0)\./.test(host) || /^169\.254\./.test(host) || /^192\.168\./.test(host)) return true;
  const match = host.match(/^172\.(\d+)\./);
  if (match && Number(match[1]) >= 16 && Number(match[1]) <= 31) return true;
  return host === "::1" || host.startsWith("fc") || host.startsWith("fd") || host.startsWith("fe80:");
}

function safeMimeType(value?: string): string {
  const mime = (value ?? "application/octet-stream").split(";")[0].toLowerCase();
  return /^(video|audio|image)\/[a-z0-9.+-]+$/.test(mime) ? mime : "application/octet-stream";
}

function object(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function decodeHTML(value: string): string {
  return value
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;/g, "'")
    .replace(/&nbsp;/g, " ");
}
