export interface WebSearchResult {
  url: string;
  title: string;
  snippet: string;
}

/** Shared keyed web search for both transcript evidence and watch links. */
export async function searchWeb(options: {
  apiKey?: string;
  query: string;
  region?: string;
  fetcher?: typeof fetch;
}): Promise<WebSearchResult[]> {
  const key = options.apiKey?.trim();
  if (!key) return [];
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
    const response = await fetcher(url, { headers: { accept: "application/json" } });
    if (!response.ok) return [];
    const body = await response.json() as {
      organic_results?: Array<{ link?: string; title?: string; snippet?: string }>;
      inline_videos?: Array<{ link?: string; title?: string; snippet?: string }>;
    };
    return [...(body.organic_results ?? []), ...(body.inline_videos ?? [])]
      .flatMap((result) => typeof result.link === "string"
        ? [{ url: normalizedResultURL(result.link), title: result.title ?? "", snippet: result.snippet ?? "" }]
        : []);
  }
  if (key.startsWith("BSA")) {
    const url = new URL("https://api.search.brave.com/res/v1/web/search");
    url.searchParams.set("q", options.query);
    url.searchParams.set("count", "20");
    url.searchParams.set("country", region);
    const response = await fetcher(url, {
      headers: { accept: "application/json", "x-subscription-token": key },
    });
    if (!response.ok) return [];
    const body = await response.json() as {
      web?: { results?: Array<{ url?: string; title?: string; description?: string }> };
    };
    return (body.web?.results ?? []).flatMap((result) =>
      typeof result.url === "string"
        ? [{ url: normalizedResultURL(result.url), title: result.title ?? "", snippet: result.description ?? "" }]
        : []);
  }
  return [];
}

/** Some search responses double-escape query delimiters (`\\u003d`,
 * `\\u0026`) inside result URLs. Fetching that literal string drops the
 * transcript page's episode selector and can verify the wrong page. */
function normalizedResultURL(value: string): string {
  return value
    .replace(/\\u([0-9a-f]{4})/gi, (_, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)))
    .replaceAll("&amp;", "&");
}
