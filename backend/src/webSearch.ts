export interface WebSearchResult {
  url: string;
  title: string;
  snippet: string;
}

/** A provider link Google itself published in its "Watch episode" panel. */
export interface KnowledgeWatchLink {
  url: string;
  /** Provider name as Google labelled it, when it gave one. */
  label: string;
}

export interface WebSearchOutcome {
  results: WebSearchResult[];
  /** False when the provider was unreachable, errored, or is unconfigured.
   *  An empty `results` with `ok: true` genuinely means "nothing found". */
  ok: boolean;
  /** Links lifted from Google's knowledge panel rather than organic results. */
  knowledge: KnowledgeWatchLink[];
}

/** Shared keyed web search for both transcript evidence and watch links. */
export async function searchWeb(options: {
  apiKey?: string;
  query: string;
  region?: string;
  fetcher?: typeof fetch;
}): Promise<WebSearchResult[]> {
  return (await searchWebDetailed(options)).results;
}

/** As `searchWeb`, but distinguishes "found nothing" from "could not ask", and
 *  surfaces the provider links Google publishes in its knowledge panel.
 *
 *  The panel matters because a provider page cannot always be verified by
 *  fetching it. Netflix serves `<title>Netflix</title>` and nothing else to an
 *  unauthenticated request, so a `/watch/<id>` URL can never be confirmed from
 *  its own page — but Google already resolved that exact id for the episode. */
export async function searchWebDetailed(options: {
  apiKey?: string;
  query: string;
  region?: string;
  fetcher?: typeof fetch;
}): Promise<WebSearchOutcome> {
  const key = options.apiKey?.trim();
  if (!key) return { results: [], ok: false, knowledge: [] };
  const fetcher = options.fetcher ?? fetch;
  const region = (options.region ?? "US").toLowerCase();
  if (/^[0-9a-f]{64}$/i.test(key)) {
    const url = new URL("https://serpapi.com/search.json");
    url.searchParams.set("engine", "google");
    url.searchParams.set("q", options.query);
    url.searchParams.set("num", "20");
    url.searchParams.set("gl", region);
    url.searchParams.set("hl", "en");
    url.searchParams.set("api_key", key);
    let body: {
      organic_results?: Array<{ link?: string; title?: string; snippet?: string }>;
      inline_videos?: Array<{ link?: string; title?: string; snippet?: string }>;
      knowledge_graph?: unknown;
      available_on?: unknown;
    };
    try {
      const response = await fetcher(url, { headers: { accept: "application/json" } });
      if (!response.ok) return { results: [], ok: false, knowledge: [] };
      body = await response.json() as typeof body;
    } catch {
      return { results: [], ok: false, knowledge: [] };
    }
    const results = [...(body.organic_results ?? []), ...(body.inline_videos ?? [])]
      .flatMap((result) => typeof result.link === "string"
        ? [{ url: normalizedResultURL(result.link), title: result.title ?? "", snippet: result.snippet ?? "" }]
        : []);
    // Only the knowledge panel is trusted here; organic results are guesses.
    const knowledge = [
      ...collectKnowledgeLinks(body.knowledge_graph),
      ...collectKnowledgeLinks(body.available_on),
    ];
    return { results, ok: true, knowledge };
  }
  if (key.startsWith("BSA")) {
    const url = new URL("https://api.search.brave.com/res/v1/web/search");
    url.searchParams.set("q", options.query);
    url.searchParams.set("count", "20");
    url.searchParams.set("country", region);
    let body: { web?: { results?: Array<{ url?: string; title?: string; description?: string }> } };
    try {
      const response = await fetcher(url, {
        headers: { accept: "application/json", "x-subscription-token": key },
      });
      if (!response.ok) return { results: [], ok: false, knowledge: [] };
      body = await response.json() as typeof body;
    } catch {
      return { results: [], ok: false, knowledge: [] };
    }
    const results = (body.web?.results ?? []).flatMap((result) =>
      typeof result.url === "string"
        ? [{ url: normalizedResultURL(result.url), title: result.title ?? "", snippet: result.description ?? "" }]
        : []);
    return { results, ok: true, knowledge: [] };
  }
  return { results: [], ok: false, knowledge: [] };
}

/** Walk a knowledge-panel subtree and collect every link it carries.
 *
 *  Deliberately shape-agnostic: Google labels this section differently for
 *  films, shows and single episodes, and SerpApi passes those variations
 *  through. Anything with a URL inside the panel is a candidate; the caller
 *  decides which hosts it is willing to hand a viewer. */
export function collectKnowledgeLinks(node: unknown, depth = 0): KnowledgeWatchLink[] {
  if (depth > 6 || node === null || typeof node !== "object") return [];
  if (Array.isArray(node)) return node.flatMap((item) => collectKnowledgeLinks(item, depth + 1));

  const record = node as Record<string, unknown>;
  const out: KnowledgeWatchLink[] = [];
  const rawLink = ["link", "url", "watch_link"]
    .map((field) => record[field])
    .find((value): value is string => typeof value === "string" && /^https?:\/\//i.test(value));
  if (rawLink) {
    const label = ["name", "title", "provider", "service"]
      .map((field) => record[field])
      .find((value): value is string => typeof value === "string") ?? "";
    out.push({ url: normalizedResultURL(rawLink), label });
  }
  for (const value of Object.values(record)) out.push(...collectKnowledgeLinks(value, depth + 1));
  return out;
}

/** Some search responses double-escape query delimiters (`\\u003d`,
 * `\\u0026`) inside result URLs. Fetching that literal string drops the
 * transcript page's episode selector and can verify the wrong page. */
function normalizedResultURL(value: string): string {
  return value
    .replace(/\\u([0-9a-f]{4})/gi, (_, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)))
    .replaceAll("&amp;", "&");
}
