import Foundation

/// Everything SceneFind can learn about a shared clip *before* spending money on
/// a model call.
///
/// The three fields that matter most are `caption`, `transcript`, and `title`:
/// between them they answer most clips outright. A poster who captions "Ant-Man
/// (2015)" has already told us the answer, and TikTok's free ASR track hands us
/// verbatim dialogue. Fetching those costs one small HTTP request per clip and
/// removes the need to download the video at all in the common case.
struct SocialClipMetadata: Hashable {
    let title: String?
    let authorName: String?
    let thumbnailURL: URL?
    let videoURL: URL?
    let searchHints: [String]
    let canonicalURL: URL?
    /// The poster's own caption / description text.
    let caption: String?
    /// Timed dialogue from the platform's caption track, when it publishes one.
    let transcript: ClipTranscript?
    let clipDurationSeconds: Double?
    /// Platform-assigned topic labels (TikTok's `diversificationLabels`).
    let contentLabels: [String]

    init(
        title: String?,
        authorName: String?,
        thumbnailURL: URL?,
        videoURL: URL? = nil,
        searchHints: [String] = [],
        canonicalURL: URL? = nil,
        caption: String? = nil,
        transcript: ClipTranscript? = nil,
        clipDurationSeconds: Double? = nil,
        contentLabels: [String] = []
    ) {
        self.title = title
        self.authorName = authorName
        self.thumbnailURL = thumbnailURL
        self.videoURL = videoURL
        self.searchHints = searchHints
        self.canonicalURL = canonicalURL
        self.caption = caption
        self.transcript = transcript
        self.clipDurationSeconds = clipDurationSeconds
        self.contentLabels = contentLabels
    }

    /// Whether text evidence alone is worth an identification attempt.
    ///
    /// Deliberately generous: the text attempt is cheap and fast, and it reports
    /// its own `needs_video` when the evidence turns out to be too thin. Being
    /// strict here just forces slow video analysis onto clips that did not need it.
    var supportsTextIdentification: Bool {
        if let transcript, transcript.wordCount >= 12 { return true }
        return Self.meaningfulWordCount(in: caption) >= 4
            || Self.meaningfulWordCount(in: title) >= 4
    }

    /// Words left after stripping hashtags, @handles, and URLs. "#fyp #viral" is
    /// not evidence, and treating it as evidence is how the old pipeline talked
    /// itself into confident wrong answers.
    private static func meaningfulWordCount(in text: String?) -> Int {
        guard let text else { return 0 }
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { word in
                guard !word.isEmpty else { return false }
                guard !word.hasPrefix("#"), !word.hasPrefix("@") else { return false }
                guard !word.lowercased().hasPrefix("http") else { return false }
                return word.contains { $0.isLetter || $0.isNumber }
            }
            .count
    }
}

protocol SocialClipMetadataService {
    func metadata(for url: URL) async throws -> SocialClipMetadata
}

final class OEmbedSocialClipMetadataService: SocialClipMetadataService {
    private struct Response: Decodable {
        let title: String?
        let authorName: String?
        let thumbnailURL: URL?
        let html: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
            case html
        }
    }

    private let session: URLSession

    static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func metadata(for url: URL) async throws -> SocialClipMetadata {
        switch SharedPlatform.detect(url: url) {
        case .tiktok: return try await tikTokMetadata(for: url)
        case .youtube: return try await youTubeMetadata(for: url)
        case .instagram: return try await instagramMetadata(for: url)
        default: return try await openGraphMetadata(for: url)
        }
    }

    // MARK: - YouTube

    /// oEmbed is not enough on its own: it returns 401 for any video whose owner
    /// disabled embedding, which is common for the TV/film clip channels this app
    /// exists to identify. The watch page still serves the title and the full
    /// description to a normal browser user-agent, and clip channels routinely
    /// name the show and episode there.
    private func youTubeMetadata(for url: URL) async throws -> SocialClipMetadata {
        let canonical = Self.canonicalYouTubeURL(url)
        guard let html = try? await htmlText(for: canonical, userAgent: Self.desktopUserAgent) else {
            throw SceneFindError.invalidURL
        }
        let description = Self.youTubeShortDescription(in: html)
            ?? Self.metaContent(property: "og:description", in: html)
        return SocialClipMetadata(
            title: Self.metaContent(property: "og:title", in: html),
            authorName: Self.jsonStringValue(key: "ownerChannelName", in: html),
            thumbnailURL: Self.metaContent(property: "og:image", in: html).flatMap(URL.init(string:)),
            videoURL: nil,
            searchHints: Self.metaContents(property: "og:video:tag", in: html),
            canonicalURL: canonical,
            caption: description,
            transcript: nil,
            clipDurationSeconds: Self.jsonStringValue(key: "lengthSeconds", in: html).flatMap(Double.init),
            contentLabels: []
        )
    }

    static func canonicalYouTubeURL(_ url: URL) -> URL {
        guard let host = url.host()?.lowercased() else { return url }
        let components = url.pathComponents
        if host.contains("youtu.be"), let id = components.dropFirst().first {
            return URL(string: "https://www.youtube.com/watch?v=\(id)") ?? url
        }
        for marker in ["shorts", "embed", "live"] {
            guard let index = components.firstIndex(of: marker),
                  components.indices.contains(index + 1) else { continue }
            return URL(string: "https://www.youtube.com/watch?v=\(components[index + 1])") ?? url
        }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            return URL(string: "https://www.youtube.com/watch?v=\(id)") ?? url
        }
        return url
    }

    /// `shortDescription` carries the untruncated description; og:description is
    /// clipped to roughly 160 characters, which often cuts the episode number off.
    private static func youTubeShortDescription(in html: String) -> String? {
        jsonStringValue(key: "shortDescription", in: html)
    }

    // MARK: - TikTok

    private func tikTokMetadata(for url: URL) async throws -> SocialClipMetadata {
        let page = await resolvedTikTokPage(for: url)
        let canonicalURL = page?.url ?? url
        let oEmbed = await tikTokOEmbed(for: canonicalURL)

        var pageMetadata = page?.metadata
        if pageMetadata == nil {
            pageMetadata = await tiktokPageMetadata(for: canonicalURL, oEmbedHTML: oEmbed?.html)
        }
        guard oEmbed != nil || pageMetadata != nil else { throw SceneFindError.invalidURL }

        let transcript = await tikTokTranscript(from: pageMetadata)
        return SocialClipMetadata(
            title: oEmbed?.title,
            authorName: oEmbed?.authorName,
            thumbnailURL: oEmbed?.thumbnailURL ?? pageMetadata?.thumbnailURL,
            videoURL: pageMetadata?.videoURL,
            searchHints: pageMetadata?.searchHints ?? [],
            canonicalURL: canonicalURL,
            caption: pageMetadata?.caption ?? oEmbed?.title,
            transcript: transcript,
            clipDurationSeconds: pageMetadata?.durationSeconds,
            contentLabels: pageMetadata?.contentLabels ?? []
        )
    }

    private func tikTokOEmbed(for url: URL) async -> Response? {
        guard var components = URLComponents(string: "https://www.tiktok.com/oembed") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let endpoint = components.url else { return nil }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        request.setValue("SceneFind/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }

    /// TikTok signs its subtitle URLs and rejects requests without a tiktok.com
    /// referer, so this has to be fetched the same way the web player does.
    private func tikTokTranscript(from metadata: TikTokPageMetadata?) async -> ClipTranscript? {
        guard let subtitleURL = metadata?.subtitleURL else { return nil }
        var request = URLRequest(url: subtitleURL)
        request.timeoutInterval = 10
        request.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let cues = WebVTTParser.cues(from: text)
        guard !cues.isEmpty else { return nil }
        return ClipTranscript(cues: cues, source: .tikTokASR)
    }

    private func resolvedTikTokPage(for url: URL) async -> (url: URL, metadata: TikTokPageMetadata?)? {
        guard let (data, response) = try? await rawData(for: url, userAgent: Self.mobileUserAgent, timeout: 12),
              let http = response as? HTTPURLResponse,
              200..<400 ~= http.statusCode else { return nil }
        return (response.url ?? url, TikTokPageParser.metadata(from: data))
    }

    private func tiktokPageMetadata(for url: URL, oEmbedHTML: String?) async -> TikTokPageMetadata? {
        if let videoID = oEmbedHTML.flatMap({ Self.tiktokVideoID(in: $0) })
            ?? Self.tiktokVideoID(in: url.absoluteString),
           let embedURL = URL(string: "https://www.tiktok.com/embed/v2/\(videoID)"),
           let metadata = await tiktokPageMetadata(at: embedURL) {
            return metadata
        }
        return await tiktokPageMetadata(at: url)
    }

    private func tiktokPageMetadata(at url: URL) async -> TikTokPageMetadata? {
        guard let (data, response) = try? await rawData(for: url, userAgent: Self.mobileUserAgent, timeout: 12),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { return nil }
        return TikTokPageParser.metadata(from: data)
    }

    private static func tiktokVideoID(in value: String) -> String? {
        let patterns = [#"data-video-id=[\"'](\d+)[\"']"#, #"/video/(\d+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { continue }
            return String(value[range])
        }
        return nil
    }

    // MARK: - Instagram

    /// Instagram blocks its private APIs but still renders Open Graph tags for
    /// link previews, and `og:description` contains the poster's entire caption.
    /// Film and TV clip accounts routinely name the title there.
    private func instagramMetadata(for url: URL) async throws -> SocialClipMetadata {
        let canonical = Self.canonicalInstagramURL(url) ?? url
        var caption: String?
        var title: String?
        var thumbnailURL: URL?

        if let html = try? await htmlText(for: canonical, userAgent: Self.mobileUserAgent) {
            title = Self.metaContent(property: "twitter:title", in: html)
                ?? Self.metaContent(property: "og:title", in: html)
            caption = Self.metaContent(property: "og:description", in: html)
                ?? Self.metaContent(property: "description", in: html)
            thumbnailURL = Self.metaContent(property: "og:image", in: html).flatMap(URL.init(string:))
        }

        if caption == nil, let embedCaption = await instagramEmbedCaption(for: canonical) {
            caption = embedCaption
        }
        guard caption != nil || thumbnailURL != nil else { throw SceneFindError.invalidURL }
        return SocialClipMetadata(
            title: title,
            authorName: Self.instagramAuthor(in: title),
            thumbnailURL: thumbnailURL,
            videoURL: nil,
            searchHints: [],
            canonicalURL: canonical,
            caption: caption.map(Self.strippingInstagramEngagementPrefix)
        )
    }

    private func instagramEmbedCaption(for url: URL) async -> String? {
        guard let embedURL = URL(string: url.absoluteString.hasSuffix("/")
                                 ? url.absoluteString + "embed/captioned/"
                                 : url.absoluteString + "/embed/captioned/"),
              let html = try? await htmlText(for: embedURL, userAgent: Self.mobileUserAgent),
              let range = html.range(of: "class=\"Caption\""),
              let end = html.range(of: "</div>", range: range.upperBound..<html.endIndex) else { return nil }
        let text = String(html[range.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Self.decodingHTMLEntities(text)
    }

    /// Instagram prefixes the caption with engagement counts, e.g.
    /// `4M likes, 5,518 comments - telewatch.tv on February 10, 2026: "…"`.
    /// The counts are noise; the quoted caption is the evidence.
    static func strippingInstagramEngagementPrefix(_ caption: String) -> String {
        guard let quoteStart = caption.firstIndex(of: "\""),
              caption[caption.startIndex..<quoteStart].contains(" - ") else { return caption }
        var body = String(caption[caption.index(after: quoteStart)...])
        if body.hasSuffix("\"") { body.removeLast() }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func instagramAuthor(in title: String?) -> String? {
        guard let title, let range = title.range(of: #"\(@[^)]+\)"#, options: .regularExpression) else {
            return nil
        }
        return String(title[range]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    }

    private static func canonicalInstagramURL(_ url: URL) -> URL? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let index = components.firstIndex(where: { ["reel", "reels", "p", "tv"].contains($0) }),
              components.indices.contains(index + 1) else { return nil }
        let kind = components[index] == "reels" ? "reel" : components[index]
        return URL(string: "https://www.instagram.com/\(kind)/\(components[index + 1])/")
    }

    // MARK: - Generic web

    private func openGraphMetadata(for url: URL) async throws -> SocialClipMetadata {
        guard let html = try? await htmlText(for: url, userAgent: Self.mobileUserAgent) else {
            throw SceneFindError.invalidURL
        }
        let title = Self.metaContent(property: "og:title", in: html)
        let caption = Self.metaContent(property: "og:description", in: html)
        guard title != nil || caption != nil else { throw SceneFindError.invalidURL }
        return SocialClipMetadata(
            title: title,
            authorName: Self.metaContent(property: "og:site_name", in: html),
            thumbnailURL: Self.metaContent(property: "og:image", in: html).flatMap(URL.init(string:)),
            videoURL: Self.metaContent(property: "og:video", in: html).flatMap(URL.init(string:)),
            canonicalURL: url,
            caption: caption
        )
    }

    // MARK: - HTTP + HTML helpers

    private func rawData(
        for url: URL,
        userAgent: String,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return try await session.data(for: request)
    }

    private func htmlText(for url: URL, userAgent: String, timeout: TimeInterval = 12) async throws -> String {
        let (data, response) = try await rawData(for: url, userAgent: userAgent, timeout: timeout)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw SceneFindError.invalidURL
        }
        guard let text = String(data: data, encoding: .utf8) else { throw SceneFindError.invalidURL }
        return text
    }

    static func metaContent(property: String, in html: String) -> String? {
        metaContents(property: property, in: html).first
    }

    static func metaContents(property: String, in html: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta[^>]*?(?:property|name)\\s*=\\s*[\"']\(escaped)[\"'][^>]*?content\\s*=\\s*[\"']([^\"']*)[\"']",
            "<meta[^>]*?content\\s*=\\s*[\"']([^\"']*)[\"'][^>]*?(?:property|name)\\s*=\\s*[\"']\(escaped)[\"']"
        ]
        var values: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                let value = decodingHTMLEntities(String(html[range]))
                if !value.isEmpty, !values.contains(value) { values.append(value) }
            }
            if !values.isEmpty { break }
        }
        return values
    }

    /// Pulls a JSON string out of an inline script payload, honouring the `\uXXXX`
    /// and `\n` escapes those payloads use. Without the unescaping step a
    /// description comes back full of literal `\n` and mangled emoji.
    static func jsonStringValue(key: String, in html: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(pattern: "\"\(escapedKey)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let raw = String(html[range])
        guard let data = "\"\(raw)\"".data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else { return raw }
        return decoded
    }

    static func decodingHTMLEntities(_ value: String) -> String {
        var result = value
        for (entity, replacement) in [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"),
            ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities: Instagram escapes non-ASCII caption characters this way.
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let full = Range(match.range, in: result),
                  let flagRange = Range(match.range(at: 1), in: result),
                  let digitsRange = Range(match.range(at: 2), in: result) else { continue }
            let radix = result[flagRange].isEmpty ? 10 : 16
            guard let code = UInt32(result[digitsRange], radix: radix),
                  let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(full, with: String(Character(scalar)))
        }
        return result
    }
}

struct TikTokPageMetadata: Equatable {
    let videoURL: URL?
    let thumbnailURL: URL?
    let searchHints: [String]
    let caption: String?
    let subtitleURL: URL?
    let durationSeconds: Double?
    let contentLabels: [String]

    init(
        videoURL: URL?,
        thumbnailURL: URL?,
        searchHints: [String],
        caption: String? = nil,
        subtitleURL: URL? = nil,
        durationSeconds: Double? = nil,
        contentLabels: [String] = []
    ) {
        self.videoURL = videoURL
        self.thumbnailURL = thumbnailURL
        self.searchHints = searchHints
        self.caption = caption
        self.subtitleURL = subtitleURL
        self.durationSeconds = durationSeconds
        self.contentLabels = contentLabels
    }
}

enum TikTokPageParser {
    static func metadata(from data: Data) -> TikTokPageMetadata? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        if let item = universalItem(in: html) {
            return metadata(from: item)
        }
        if let item = embedItem(in: html) {
            return metadata(from: item)
        }
        return openGraphMetadata(in: html)
    }

    private static func openGraphMetadata(in html: String) -> TikTokPageMetadata? {
        let videoURL = (OEmbedSocialClipMetadataService.metaContent(property: "og:video", in: html)
            ?? OEmbedSocialClipMetadataService.metaContent(property: "og:video:url", in: html))
            .flatMap(URL.init(string:))
        let thumbnailURL = (OEmbedSocialClipMetadataService.metaContent(property: "og:image", in: html)
            ?? OEmbedSocialClipMetadataService.metaContent(property: "twitter:image", in: html))
            .flatMap(URL.init(string:))
        let caption = OEmbedSocialClipMetadataService.metaContent(property: "og:description", in: html)
        guard videoURL != nil || thumbnailURL != nil else { return nil }
        return TikTokPageMetadata(
            videoURL: videoURL,
            thumbnailURL: thumbnailURL,
            searchHints: [],
            caption: caption
        )
    }

    private static func metadata(from item: [String: Any]) -> TikTokPageMetadata? {
        let video = item["video"] as? [String: Any]
        let videoURL = ((video?["urls"] as? [String])?.first).flatMap(URL.init(string:))
            ?? (video?["playAddr"] as? String).flatMap(URL.init(string:))
            ?? (((video?["PlayAddrStruct"] as? [String: Any])?["UrlList"] as? [String])?.first)
                .flatMap(URL.init(string:))
        let thumbnailURL = ((item["coversOrigin"] as? [String])?.first).flatMap(URL.init(string:))
            ?? ((item["covers"] as? [String])?.first).flatMap(URL.init(string:))
            ?? (video?["originCover"] as? String).flatMap(URL.init(string:))
            ?? (video?["cover"] as? String).flatMap(URL.init(string:))
        let challengeHints = (item["challengeInfoList"] as? [[String: Any]] ?? [])
            .compactMap { $0["challengeName"] as? String }
        let hints = ((item["suggestedWords"] as? [String] ?? []) + challengeHints)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let caption = (item["desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = (item["diversificationLabels"] as? [String] ?? [])
            + (item["keywordTags"] as? [[String: Any]] ?? []).compactMap { $0["keyword"] as? String }

        guard videoURL != nil || thumbnailURL != nil || !hints.isEmpty || !(caption ?? "").isEmpty else {
            return nil
        }
        return TikTokPageMetadata(
            videoURL: videoURL,
            thumbnailURL: thumbnailURL,
            searchHints: Array(hints.prefix(12)),
            caption: caption?.isEmpty == true ? nil : caption,
            subtitleURL: englishSubtitleURL(in: video),
            durationSeconds: (video?["duration"] as? NSNumber)?.doubleValue,
            contentLabels: Array(labels.prefix(8))
        )
    }

    /// TikTok ships several tracks; prefer an English one and skip burned-in
    /// translations, which are noisier than the original ASR pass.
    private static func englishSubtitleURL(in video: [String: Any]?) -> URL? {
        let tracks = video?["subtitleInfos"] as? [[String: Any]] ?? []
        let english = tracks.filter {
            ($0["LanguageCodeName"] as? String)?.lowercased().hasPrefix("eng") == true
        }
        let preferred = english.first { ($0["Source"] as? String)?.uppercased() == "ASR" }
            ?? english.first
            ?? tracks.first
        guard let urlText = preferred?["Url"] as? String else { return nil }
        return URL(string: urlText)
    }

    private static func universalItem(in html: String) -> [String: Any]? {
        guard let scriptData = scriptJSON(id: "__UNIVERSAL_DATA_FOR_REHYDRATION__", in: html),
              let root = try? JSONSerialization.jsonObject(with: scriptData) as? [String: Any],
              let scope = root["__DEFAULT_SCOPE__"] as? [String: Any] else { return nil }
        // TikTok serves `webapp.video-detail` to desktop clients and
        // `webapp.reflow.video.detail` to mobile ones. Reading only the first
        // meant every mobile fetch silently fell through to a metadata-free path.
        for key in ["webapp.video-detail", "webapp.reflow.video.detail"] {
            guard let detail = scope[key] as? [String: Any],
                  let itemInfo = detail["itemInfo"] as? [String: Any],
                  let item = itemInfo["itemStruct"] as? [String: Any] else { continue }
            return item
        }
        return nil
    }

    private static func embedItem(in html: String) -> [String: Any]? {
        guard let scriptData = scriptJSON(id: "__FRONTITY_CONNECT_STATE__", in: html),
              let root = try? JSONSerialization.jsonObject(with: scriptData) as? [String: Any],
              let source = root["source"] as? [String: Any],
              let data = source["data"] as? [String: Any] else { return nil }
        for value in data.values {
            guard let page = value as? [String: Any],
                  let videoData = page["videoData"] as? [String: Any],
                  let item = videoData["itemInfos"] as? [String: Any] else { continue }
            return item
        }
        return nil
    }

    private static func scriptJSON(id: String, in html: String) -> Data? {
        guard let idRange = html.range(of: "id=\"\(id)\""),
              let openingTagEnd = html[idRange.upperBound...].firstIndex(of: ">"),
              let closingTag = html.range(of: "</script>", range: openingTagEnd..<html.endIndex) else {
            return nil
        }
        return String(html[html.index(after: openingTagEnd)..<closingTag.lowerBound]).data(using: .utf8)
    }
}

protocol TitleArtworkService {
    func artworkURL(
        for mediaTitle: String,
        mediaType: MediaType,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) async -> URL?
}

final class PublicTitleArtworkService: TitleArtworkService {
    private struct TVMazeShow: Decodable {
        struct Image: Decodable {
            let medium: URL?
            let original: URL?
        }
        struct Embedded: Decodable {
            struct Episode: Decodable {
                let season: Int
                let number: Int
                let image: Image?
            }
            let episodes: [Episode]
        }

        let image: Image?
        let embedded: Embedded?

        enum CodingKeys: String, CodingKey {
            case image
            case embedded = "_embedded"
        }
    }

    private struct ITunesResponse: Decodable {
        struct Result: Decodable {
            let artworkUrl100: URL?
        }
        let results: [Result]
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func artworkURL(
        for mediaTitle: String,
        mediaType: MediaType,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) async -> URL? {
        switch mediaType {
        case .television:
            return await televisionArtwork(
                title: mediaTitle,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber
            )
        case .movie:
            return await movieArtwork(title: mediaTitle)
        case .other:
            return nil
        }
    }

    private func televisionArtwork(
        title: String,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) async -> URL? {
        var components = URLComponents(string: "https://api.tvmaze.com/singlesearch/shows")
        components?.queryItems = [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "embed", value: "episodes")
        ]
        guard let url = components?.url,
              let show: TVMazeShow = await decodedResponse(from: url) else { return nil }
        let episodeImage = show.embedded?.episodes.first {
            $0.season == seasonNumber && $0.number == episodeNumber
        }?.image
        return show.image?.original ?? show.image?.medium ?? episodeImage?.original ?? episodeImage?.medium
    }

    private func movieArtwork(title: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "media", value: "movie"),
            URLQueryItem(name: "entity", value: "movie"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url,
              let response: ITunesResponse = await decodedResponse(from: url),
              let artwork = response.results.first?.artworkUrl100 else { return nil }
        return URL(string: artwork.absoluteString.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
    }

    private func decodedResponse<T: Decodable>(from url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
