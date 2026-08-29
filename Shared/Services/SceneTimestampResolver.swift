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
    private struct TimestampSearchPhrase: Sendable {
        let text: String
        let startSeconds: Double
        let endSeconds: Double
    }

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
        let phrases = Self.timedSearchablePhrases(
            transcript: transcript,
            detectedDialogue: detectedDialogue,
            limit: 3
        )
        if let matchedOffset = await matchedTimelineOffset(title: title, phrases: phrases) {
            let matched = max(0, matchedOffset)
            let end = clipDurationSeconds.map { matched + $0 } ?? estimatedEndSeconds
            return ResolvedSceneTimestamp(
                startSeconds: matched,
                endSeconds: end,
                accuracy: .matchedDialogue,
                basis: "Located by aligning the clip's first/last dialogue against a subtitle index for \(title)."
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
    /// Searches every candidate phrase at once and keeps the earliest-ranked hit.
    /// Sequentially these three lookups cost up to 18s on their own.
    private func matchedTimelineOffset(
        title: String,
        phrases: [TimestampSearchPhrase]
    ) async -> Double? {
        guard !phrases.isEmpty else { return nil }
        return await withTaskGroup(of: (Int, Double?).self) { group in
            for (index, phrase) in phrases.enumerated() {
                group.addTask {
                    let canonical = await self.quoDBSearch(phrase: phrase.text, title: title)
                    return (index, canonical.map { $0 - phrase.startSeconds })
                }
            }
            var hits: [(Int, Double)] = []
            for await case let (index, seconds?) in group { hits.append((index, seconds)) }
            // Phrases are ordered most-distinctive first, so prefer that hit.
            return hits.min { $0.0 < $1.0 }?.1
        }
    }

    /// Lines worth searching for, from a platform caption track when there is
    /// one and otherwise from whatever the model transcribed off the video.
    static func searchablePhrases(
        transcript: ClipTranscript?,
        detectedDialogue: String?,
        limit: Int = 3
    ) -> [String] {
        timedSearchablePhrases(
            transcript: transcript,
            detectedDialogue: detectedDialogue,
            limit: limit
        ).map(\.text)
    }

    private static func timedSearchablePhrases(
        transcript: ClipTranscript?,
        detectedDialogue: String?,
        limit: Int
    ) -> [TimestampSearchPhrase] {
        if let transcript, !transcript.isEmpty {
            var candidates: [TimestampSearchPhrase] = []
            for start in transcript.cues.indices {
                var text = ""
                var end = transcript.cues[start].endSeconds
                for length in 1...3 where start + length <= transcript.cues.count {
                    let cue = transcript.cues[start + length - 1]
                    if length > 1, cue.startSeconds - end > 2.5 { break }
                    text = "\(text) \(cue.text)"
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    end = cue.endSeconds
                    let words = text.split(whereSeparator: \.isWhitespace).count
                    guard (6...26).contains(words), text.count <= 220 else { continue }
                    candidates.append(TimestampSearchPhrase(
                        text: text,
                        startSeconds: transcript.cues[start].startSeconds,
                        endSeconds: end
                    ))
                }
            }
            guard !candidates.isEmpty else { return [] }
            let firstStart = candidates.map(\.startSeconds).min()!
            let lastEnd = candidates.map(\.endSeconds).max()!
            let ranked = candidates.sorted {
                let leftDistance = abs($0.text.split(whereSeparator: \.isWhitespace).count - 11)
                let rightDistance = abs($1.text.split(whereSeparator: \.isWhitespace).count - 11)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
                return $0.text.count > $1.text.count
            }
            var selected: [TimestampSearchPhrase] = []
            func append(_ phrase: TimestampSearchPhrase?) {
                guard let phrase, selected.count < limit,
                      !selected.contains(where: {
                          $0.startSeconds == phrase.startSeconds && $0.endSeconds == phrase.endSeconds
                      }) else { return }
                selected.append(phrase)
            }
            // Boundary anchors are load-bearing for the shared clip window.
            append(ranked.first { $0.startSeconds == firstStart })
            append(ranked.first { $0.endSeconds == lastEnd })
            for phrase in ranked where selected.count < limit {
                guard !selected.contains(where: { abs($0.startSeconds - phrase.startSeconds) < 3 }) else {
                    continue
                }
                append(phrase)
            }
            return selected
        }

        guard let detectedDialogue, !detectedDialogue.isEmpty else { return [] }
        // Without platform timing, only the leading transcribed line has a
        // defensible local offset (zero). Extra lines remain useful for episode
        // research but cannot safely define the shared clip's start.
        return distinctivePhrases(
            in: detectedDialogue
                .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            limit: limit
        ).map { TimestampSearchPhrase(text: $0, startSeconds: 0, endSeconds: 0) }
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
