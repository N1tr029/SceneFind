import Foundation

/// Timed dialogue lifted from a social clip.
///
/// TikTok publishes an automatic-speech-recognition WebVTT track alongside every
/// video (`video.subtitleInfos`), and YouTube exposes caption tracks. Reading one
/// of those is dramatically cheaper than downloading the clip and shipping it to a
/// video model: it costs a single small GET and gives the identifier verbatim
/// dialogue, which is the strongest evidence there is for naming a scene.
struct ClipTranscript: Codable, Hashable, Sendable {
    struct Cue: Codable, Hashable, Sendable {
        let startSeconds: Double
        let endSeconds: Double
        let text: String
    }

    enum Source: String, Codable, Hashable, Sendable {
        case tikTokASR
        case youTubeCaptions

        var label: String {
            switch self {
            case .tikTokASR: "TikTok auto-captions"
            case .youTubeCaptions: "YouTube captions"
            }
        }
    }

    let cues: [Cue]
    let source: Source

    var isEmpty: Bool { cues.isEmpty }

    /// The spoken dialogue as one block, which is what an identifier model reads.
    var plainText: String {
        cues.map(\.text).joined(separator: " ")
    }

    /// Word count is a better "is this worth trusting" signal than cue count: a
    /// clip with music-only captions produces many cues holding almost no words.
    var wordCount: Int {
        plainText.split(whereSeparator: \.isWhitespace).count
    }

    func prefix(maxCharacters: Int) -> String {
        let text = plainText
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters))
    }
}

enum WebVTTParser {
    /// Parses the WebVTT dialects TikTok and YouTube actually emit. Anything that
    /// is not a well-formed cue is skipped rather than failing the whole track —
    /// a partial transcript is still useful evidence.
    static func cues(from text: String) -> [ClipTranscript.Cue] {
        var cues: [ClipTranscript.Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = seconds(from: timing[0]),
                  let end = seconds(from: timing[1]) else { continue }
            let spoken = lines[(timingIndex + 1)...]
                .joined(separator: " ")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { continue }
            cues.append(ClipTranscript.Cue(startSeconds: start, endSeconds: end, text: spoken))
        }
        return cues
    }

    /// Accepts `HH:MM:SS.mmm`, `MM:SS.mmm`, and trailing cue settings such as
    /// `00:00:04.000 align:start position:0%`.
    private static func seconds(from rawValue: String) -> Double? {
        let stamp = rawValue
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .first ?? ""
        let parts = stamp.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
