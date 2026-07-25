import Foundation

/// What SceneFind knows about opening a title on each streaming service.
///
/// Everything here was checked against the live services on 2026-07-24 rather
/// than taken from the model's memory or from documentation, because the two
/// most consequential facts are both things the docs still get wrong.
enum WatchDestinationPolicy {

    // MARK: - Dead services

    /// No service is fully retired — but Hulu needs the right host.
    ///
    /// `www.hulu.com` is being folded into Disney+ and answers `302` to
    /// `https://www.disneyplus.com/` with the path discarded, so a www watch URL
    /// loses the episode. `dl.hulu.com` is a different story: it still publishes
    /// an apple-app-site-association listing `/watch/*` for the Hulu iOS app
    /// (`com.hulu.plus`), and iOS matches a Universal Link against that file
    /// *before* any web request happens. So `dl.hulu.com/watch/<id>` still opens
    /// the installed app at the episode — it is only the browser fallback that
    /// ends up on Disney+.
    static func isRetiredService(_ url: URL) -> Bool { false }

    /// Moves a Hulu watch URL onto the host that can still open the app.
    static func huluDeepLink(episodeID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dl.hulu.com"
        components.path = "/watch/\(episodeID)"
        components.queryItems = [
            URLQueryItem(name: "source", value: "web_universal_deep_linking"),
            URLQueryItem(name: "play", value: "true")
        ]
        return components.url
    }

    // MARK: - Host normalisation

    /// Rewrites hosts that moved or that resolve but refuse to open the app.
    ///
    /// - `max.com` answers `301` to `www.hbomax.com`.
    /// - `play.hbomax.com` serves a catch-all AASA and opens the app;
    ///   `www.hbomax.com` returns `404` for its AASA and will only ever open
    ///   Safari, so watch links are moved onto the `play.` host.
    static func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return url }

        if host == "max.com" || host.hasSuffix(".max.com") {
            components.host = "play.hbomax.com"
            return components.url ?? url
        }
        if host == "hbomax.com" || host == "www.hbomax.com",
           components.path.lowercased().contains("/video/watch/") {
            components.host = "play.hbomax.com"
            return components.url ?? url
        }
        return components.url ?? url
    }

    // MARK: - Timestamps

    /// Services that genuinely honour a start time in the URL.
    ///
    /// Only two do. YouTube documents `t`/`start` in its player parameters, and
    /// Netflix's own "Moments" share links carry `?t=<seconds>` on a `/watch/`
    /// URL. Disney+ strips an added `t` during canonicalisation, and Apple's
    /// `resumeTime` is a contract Apple imposes on its own channel partners,
    /// not something `tv.apple.com` accepts. For every other service SceneFind
    /// shows the time as text instead of pretending the link will seek.
    static func timestampedURL(_ url: URL, startSeconds: Double) -> URL? {
        guard startSeconds >= 1 else { return nil }
        let seconds = Int(startSeconds.rounded())
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }

        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
            var items = components.queryItems?.filter { $0.name != "t" } ?? []
            items.append(URLQueryItem(name: "t", value: "\(seconds)s"))
            components.queryItems = items
            return components.url
        }

        if host == "netflix.com" || host.hasSuffix(".netflix.com") {
            guard components.path.lowercased().hasPrefix("/watch/") else { return nil }
            // Netflix's own share links carry `t` as the only parameter.
            components.queryItems = [URLQueryItem(name: "t", value: String(seconds))]
            return components.url
        }

        return nil
    }

    static func supportsTimestamp(_ url: URL) -> Bool {
        timestampedURL(url, startSeconds: 60) != nil
    }

    // MARK: - Honest fallbacks

    /// An official search page on the service itself.
    ///
    /// This is what SceneFind shows instead of a fabricated content ID. It is
    /// not as good as landing on the episode, but it always resolves, and it is
    /// honest about what the app actually knows.
    static func searchURL(service: StreamingProviderKind, title: String) -> URL? {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        switch service {
        case .netflix:
            return components("https://www.netflix.com/search", [URLQueryItem(name: "q", value: query)])
        case .youtube:
            return components("https://www.youtube.com/results", [URLQueryItem(name: "search_query", value: query)])
        case .disneyPlus:
            return components("https://www.disneyplus.com/search", [URLQueryItem(name: "q", value: query)])
        case .primeVideo:
            return components("https://www.primevideo.com/search", [URLQueryItem(name: "phrase", value: query)])
        case .appleTV:
            return components("https://tv.apple.com/search", [URLQueryItem(name: "term", value: query)])
        case .max:
            return components("https://play.hbomax.com/search", [URLQueryItem(name: "q", value: query)])
        case .peacock:
            return components("https://www.peacocktv.com/search", [URLQueryItem(name: "q", value: query)])
        case .paramountPlus:
            return components("https://www.paramountplus.com/search", [URLQueryItem(name: "q", value: query)])
        case .hulu:
            return components("https://www.hulu.com/search", [URLQueryItem(name: "q", value: query)])
        case .other:
            return nil
        }
    }

    /// Deliberately absent: there is no third-party "where to watch" fallback.
    ///
    /// Every destination SceneFind offers points at the streaming service that
    /// actually carries the title. When a service cannot be linked, its row is
    /// dropped rather than redirected to an aggregator or any other outside
    /// site, so a "Watch" button always lands on the real provider.
    static func whereToWatchURL(title: String) -> URL? { nil }

    private static func components(_ base: String, _ items: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = items
        return components?.url
    }
}
