import Foundation

/// Finds a real, publisher-declared streaming URL for a title.
///
/// This exists because the model cannot be trusted with content identifiers and
/// SceneFind will not ship a guessed one. TVmaze records each show's
/// `officialSite`, which for streaming-original series is the actual provider
/// page — verified live on 2026-07-24:
///
///     Stranger Things → https://www.netflix.com/title/80057281
///     Severance       → https://tv.apple.com/show/severance/umc.cmc.1srk2go…
///     The Mandalorian → https://www.disneyplus.com/series/the-mandalorian/…
///
/// Those are genuine ids on hosts whose apple-app-site-association covers the
/// path, so they open the app. Two honest limits: it is show-level, not
/// episode-level, and for network shows the field points at the broadcaster
/// (abc.com, nbc.com) rather than a streaming service — those are filtered out
/// here, since a network marketing page is not somewhere you can watch.
struct OfficialWatchLinkService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct Link: Equatable {
        let url: URL
        let service: StreamingProviderKind
        let serviceName: String
    }

    func officialLink(forShow title: String) async -> Link? {
        var components = URLComponents(string: "https://api.tvmaze.com/singlesearch/shows")
        components?.queryItems = [URLQueryItem(name: "q", value: title)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("SceneFind/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let show = try? JSONDecoder().decode(TVMazeShow.self, from: data),
              let siteText = show.officialSite,
              let site = URL(string: siteText) else { return nil }

        // Only accept it when the host is a streaming service we can name; a
        // broadcaster's site is not a watch destination.
        let kind = StreamingProviderKind(name: "", host: site.host)
        guard kind != .other else { return nil }
        return Link(
            url: WatchDestinationPolicy.normalized(site),
            service: kind,
            serviceName: Self.displayName(for: kind)
        )
    }

    static func displayName(for kind: StreamingProviderKind) -> String {
        switch kind {
        case .netflix: "Netflix"
        case .appleTV: "Apple TV"
        case .disneyPlus: "Disney+"
        case .primeVideo: "Prime Video"
        case .max: "Max"
        case .peacock: "Peacock"
        case .paramountPlus: "Paramount+"
        case .hulu: "Hulu"
        case .youtube: "YouTube"
        case .other: "Streaming"
        }
    }

    private struct TVMazeShow: Decodable {
        let officialSite: String?
    }
}
