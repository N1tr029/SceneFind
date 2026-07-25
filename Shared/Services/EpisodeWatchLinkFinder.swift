import Foundation

/// Finds the real "open in <service>" link for an episode or film, the same way
/// a search engine does.
///
/// Content ids like Apple TV's `umc.cmc.3151jcjocan3bys22epi0qeg6` or Peacock's
/// per-episode UUID cannot be derived from a title — but they are sitting in
/// public search results, because every provider publishes crawlable episode
/// pages. So SceneFind searches for the episode, pulls out any provider URLs,
/// and then **verifies each one by fetching it** and checking the page's own
/// `og:title` names the same show and season/episode. Verified live on
/// 2026-07-24 for *The Middle* S5E8, which returned a working Apple TV,
/// Peacock, and HBO Max episode URL.
///
/// The verification step is the point. It means a link is only ever offered when
/// the provider's own page confirms it, so a wrong or stale id is dropped rather
/// than handed to the viewer as a dead button.
struct EpisodeWatchLinkFinder {
    private let session: URLSession
    private let searchProvider: WebSearchProvider

    init(session: URLSession = .shared, searchProvider: WebSearchProvider? = nil) {
        self.session = session
        self.searchProvider = searchProvider ?? CompositeWebSearchProvider(session: session)
    }

    struct Found: Equatable {
        let url: URL
        let service: StreamingProviderKind
        let serviceName: String
    }

    /// Returns provider links whose own pages confirm they are this exact title.
    func verifiedLinks(for candidate: SceneCandidate, limit: Int = 3) async -> [Found] {
        let results = await searchProvider.search(query: Self.query(for: candidate))
        guard !results.isEmpty else { return [] }

        var checked: [Found] = []
        var seenServices = Set<StreamingProviderKind>()
        for url in Self.rankedProviderURLs(in: results) {
            if checked.count >= limit { break }
            let kind = StreamingProviderKind(name: "", host: url.host)
            guard kind != .other, !seenServices.contains(kind) else { continue }
            guard await pageConfirms(url, candidate: candidate, kind: kind) else { continue }
            seenServices.insert(kind)
            checked.append(Found(
                url: WatchDestinationPolicy.normalized(url),
                service: kind,
                serviceName: OfficialWatchLinkService.displayName(for: kind)
            ))
        }
        return checked
    }

    /// Phrased the way a person would search for the episode, because that is
    /// what the provider pages are titled and indexed as.
    static func query(for candidate: SceneCandidate) -> String {
        var parts = [candidate.mediaTitle]
        if candidate.mediaType == .television,
           let season = candidate.seasonNumber, let episode = candidate.episodeNumber {
            parts.append("season \(season) episode \(episode)")
            if let episodeTitle = candidate.episodeTitle, !episodeTitle.isEmpty {
                parts.append(episodeTitle)
            }
        } else if candidate.mediaType == .movie {
            parts.append(String(candidate.releaseYear))
        }
        parts.append("watch")
        return parts.joined(separator: " ")
    }

    /// Prefers URLs that look episode-specific over a service's front page.
    static func rankedProviderURLs(in results: [URL]) -> [URL] {
        let markers = ["/episode", "/watch", "/video", "/movie", "/play", "/detail"]
        return results
            .filter { $0.scheme?.lowercased() == "https" }
            .sorted { lhs, rhs in
                let l = markers.contains { lhs.path.lowercased().contains($0) }
                let r = markers.contains { rhs.path.lowercased().contains($0) }
                if l != r { return l }
                return lhs.path.count > rhs.path.count
            }
    }

    private func pageConfirms(
        _ url: URL,
        candidate: SceneCandidate,
        kind: StreamingProviderKind
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(OEmbedSocialClipMetadataService.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { return false }
        return StreamingPageParser.verification(
            in: data,
            candidate: candidate,
            kind: kind,
            url: response.url ?? url
        ) == .verified
    }
}

// MARK: - Search

protocol WebSearchProvider {
    /// Result URLs for a query, best first. Empty when the search is unavailable.
    func search(query: String) async -> [URL]
}

/// Uses a configured search API when there is one, and otherwise makes a
/// best-effort keyless attempt.
///
/// The keyless path is genuinely unreliable: measured on 2026-07-24, DuckDuckGo's
/// HTML endpoint answered the first request with `200` and the next two with
/// `202` — its bot challenge. That is fine as an opportunistic bonus but it is
/// why a search API key is the supported configuration; see
/// `WebSearchConfiguration`.
struct CompositeWebSearchProvider: WebSearchProvider {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func search(query: String) async -> [URL] {
        if let key = WebSearchConfiguration.apiKey, !key.isEmpty,
           let results = await braveSearch(query: query, apiKey: key), !results.isEmpty {
            return results
        }
        return await duckDuckGoSearch(query: query) ?? []
    }

    /// Brave's Search API is documented, keyed, and permits this use. It returns
    /// the same provider pages a browser search does.
    private func braveSearch(query: String, apiKey: String) async -> [URL]? {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "20")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let payload = try? JSONDecoder().decode(BraveResponse.self, from: data) else { return nil }
        return payload.web?.results.compactMap { URL(string: $0.url) } ?? []
    }

    private func duckDuckGoSearch(query: String) async -> [URL]? {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(OEmbedSocialClipMetadataService.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return Self.absoluteURLs(in: html)
    }

    /// Pulls candidate result URLs out of a results page, unwrapping the
    /// redirector DuckDuckGo puts around outbound links.
    static func absoluteURLs(in html: String) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        func append(_ text: String) {
            let cleaned = text
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>) "))
            guard let url = URL(string: cleaned), url.host != nil, seen.insert(cleaned).inserted else { return }
            found.append(url)
        }
        if let regex = try? NSRegularExpression(pattern: "uddg=([^&\"']+)") {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                append(String(html[range]).removingPercentEncoding ?? String(html[range]))
            }
        }
        if let regex = try? NSRegularExpression(pattern: "https?://[^\"'<> )\\\\]+") {
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range, in: html) else { continue }
                append(String(html[range]))
            }
        }
        return found
    }

    private struct BraveResponse: Decodable {
        struct Web: Decodable {
            struct Result: Decodable { let url: String }
            let results: [Result]
        }
        let web: Web?
    }
}
