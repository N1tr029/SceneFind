import Foundation

/// How much a scene timestamp can be trusted.
///
/// This distinction exists because language models are confidently wrong about
/// timestamps. Asked where one scene falls in a 2011 film, two different models
/// answered "52 minutes" and "33 minutes", and one cited a YouTube URL it had
/// invented. Anything the app cannot corroborate against real subtitle data is
/// labelled an estimate and shown as such.
enum SceneTimestampAccuracy: String, Codable, Hashable, Sendable {
    /// Located by matching transcribed dialogue against a subtitle index.
    case matchedDialogue
    /// A model's recollection, bounded by the title's real runtime.
    case estimated

    var label: String {
        switch self {
        case .matchedDialogue: "Matched to dialogue"
        case .estimated: "Estimated"
        }
    }

    var isVerified: Bool { self == .matchedDialogue }
}

struct ResolvedSceneTimestamp: Codable, Hashable, Sendable {
    let startSeconds: Double
    let endSeconds: Double?
    let accuracy: SceneTimestampAccuracy
    let basis: String
}

/// Turns "which scene is this" into "where in the episode is it".
///
/// Order of preference:
/// 1. Match the clip's transcribed dialogue against a real subtitle index. This
///    also independently corroborates the title, since the index says which film
///    or episode the line came from.
/// 2. Otherwise fall back to the model's estimate, but bound it by the title's
///    real runtime so a 22-minute episode can never report a 40-minute mark.
struct SceneTimestampResolver {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(
        title: String,
        mediaType: MediaType,
        seasonNumber: Int?,
        episodeNumber: Int?,
        transcript: ClipTranscript?,
        detectedDialogue: String? = nil,
        estimatedStartSeconds: Double?,
        estimatedEndSeconds: Double?,
        clipDurationSeconds: Double?
    ) async -> ResolvedSceneTimestamp? {
        let phrases = Self.searchablePhrases(transcript: transcript, detectedDialogue: detectedDialogue)
        if let matched = await matchedTimestamp(title: title, phrases: phrases) {
            let end = clipDurationSeconds.map { matched + $0 } ?? estimatedEndSeconds
            return ResolvedSceneTimestamp(
                startSeconds: matched,
                endSeconds: end,
                accuracy: .matchedDialogue,
                basis: "Located by matching the clip's dialogue against a subtitle index for \(title)."
            )
        }

        guard let estimate = estimatedStartSeconds, estimate >= 0 else { return nil }
        let runtime = await runtimeSeconds(
            title: title,
            mediaType: mediaType,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
        if let runtime, estimate > runtime {
            // The estimate falls outside the real runtime, so it is provably
            // wrong. Reporting nothing beats reporting a fabricated position.
            return nil
        }
        let end = estimatedEndSeconds ?? clipDurationSeconds.map { estimate + $0 }
        return ResolvedSceneTimestamp(
            startSeconds: estimate,
            endSeconds: end.map { value in runtime.map { min(value, $0) } ?? value },
            accuracy: .estimated,
            basis: runtime == nil
                ? "Estimated from the model's knowledge of the title; not confirmed against subtitles."
                : "Estimated from the model's knowledge and checked against the title's real runtime."
        )
    }

    // MARK: - Dialogue matching

    /// QuoDB indexes subtitle lines and answers "which title said this, and when"
    /// in a single keyless request. Its catalogue is incomplete, so a miss is
    /// normal and simply falls through to the estimate path.
    private func matchedTimestamp(title: String, phrases: [String]) async -> Double? {
        for phrase in phrases {
            guard let hit = await quoDBSearch(phrase: phrase, title: title) else { continue }
            return hit
        }
        return nil
    }

    /// Lines worth searching for, from a platform caption track when there is
    /// one and otherwise from whatever the model transcribed off the video.
    static func searchablePhrases(
        transcript: ClipTranscript?,
        detectedDialogue: String?,
        limit: Int = 3
    ) -> [String] {
        if let transcript, !transcript.isEmpty {
            return distinctivePhrases(in: transcript.cues.map(\.text), limit: limit)
        }
        guard let detectedDialogue, !detectedDialogue.isEmpty else { return [] }
        // Model-transcribed dialogue arrives as prose, so split it on sentence
        // and line boundaries to recover individual spoken lines.
        let lines = detectedDialogue
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return distinctivePhrases(in: lines, limit: limit)
    }

    /// Long, content-bearing lines identify a scene; "Yes, that's right." matches
    /// half of cinema. Longest-first also puts the most searchable line first.
    static func distinctivePhrases(in lines: [String], limit: Int = 3) -> [String] {
        var phrases: [String] = []
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = text.split(whereSeparator: { $0.isWhitespace })
            if words.count >= 6 { phrases.append(text) }
        }
        phrases.sort { $0.count > $1.count }
        return Array(phrases.prefix(limit))
    }

    private func quoDBSearch(phrase: String, title: String) async -> Double? {
        let trimmed = phrase.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\"'"))
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "https://api.quodb.com/search/\(encoded)") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "titles_per_page", value: "5"),
            URLQueryItem(name: "phrases_per_title", value: "3")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("SceneFind/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let payload = try? JSONDecoder().decode(QuoDBResponse.self, from: data) else { return nil }

        // Only accept a hit whose own title agrees with the identification. The
        // index is global, so an unfiltered match could come from any film.
        for doc in payload.docs {
            let candidates = [doc.serie, doc.title].compactMap { $0 }
            guard candidates.contains(where: { Self.titlesMatch($0, title) }),
                  let milliseconds = doc.time, milliseconds > 0 else { continue }
            return Double(milliseconds) / 1000
        }
        return nil
    }

    static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Runtime bounds

    /// Runtime in seconds from a free, keyless source: TVmaze for episodes,
    /// the iTunes Search API for films.
    func runtimeSeconds(
        title: String,
        mediaType: MediaType,
        seasonNumber: Int?,
        episodeNumber: Int?
    ) async -> Double? {
        switch mediaType {
        case .television:
            return await televisionRuntime(title: title, season: seasonNumber, episode: episodeNumber)
        case .movie:
            return await movieRuntime(title: title)
        case .other:
            return nil
        }
    }

    private func televisionRuntime(title: String, season: Int?, episode: Int?) async -> Double? {
        var components = URLComponents(string: "https://api.tvmaze.com/singlesearch/shows")
        components?.queryItems = [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "embed", value: "episodes")
        ]
        guard let url = components?.url,
              let show: TVMazeRuntimeShow = await decoded(from: url) else { return nil }
        let episodeRuntime = show.embedded?.episodes.first {
            $0.season == season && $0.number == episode
        }?.runtime
        guard let minutes = episodeRuntime ?? show.runtime ?? show.averageRuntime else { return nil }
        return Double(minutes) * 60
    }

    private func movieRuntime(title: String) async -> Double? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "media", value: "movie"),
            URLQueryItem(name: "entity", value: "movie"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url,
              let response: ITunesRuntimeResponse = await decoded(from: url),
              let milliseconds = response.results.first?.trackTimeMillis else { return nil }
        return Double(milliseconds) / 1000
    }

    private func decoded<T: Decodable>(from url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("SceneFind/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

private struct QuoDBResponse: Decodable {
    struct Document: Decodable {
        let title: String?
        let serie: String?
        let year: Int?
        let time: Int?
        let phrase: String?
    }
    let docs: [Document]
}

private struct TVMazeRuntimeShow: Decodable {
    struct Embedded: Decodable {
        struct Episode: Decodable {
            let season: Int
            let number: Int
            let runtime: Int?
        }
        let episodes: [Episode]
    }
    let runtime: Int?
    let averageRuntime: Int?
    let embedded: Embedded?

    enum CodingKeys: String, CodingKey {
        case runtime
        case averageRuntime
        case embedded = "_embedded"
    }
}

private struct ITunesRuntimeResponse: Decodable {
    struct Result: Decodable {
        let trackTimeMillis: Int?
    }
    let results: [Result]
}
