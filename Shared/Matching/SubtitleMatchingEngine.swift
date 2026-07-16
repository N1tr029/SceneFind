import Foundation

final class SubtitleMatchingEngine {
    private let stopWords: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have", "i", "in", "is", "it", "of", "on", "or", "our", "that", "the", "this", "to", "was", "we", "with", "you", "your"]

    func rankedMatches(query: String, library: [MediaTitle], limit: Int = 8) -> [SubtitleMatch] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let queryTokens = tokens(normalizedQuery)

        var matches: [SubtitleMatch] = []
        for title in library {
            for episode in title.episodes {
                for segment in episode.subtitleSegments {
                    let normalizedSegment = normalize(segment.text)
                    let segmentTokens = tokens(normalizedSegment)
                    let phraseScore = phraseScore(query: normalizedQuery, segment: normalizedSegment)
                    let overlapScore = tokenOverlap(queryTokens, segmentTokens)
                    let editScore = normalizedEditSimilarity(normalizedQuery, normalizedSegment)
                    let lengthBoost = min(Double(queryTokens.count), 10) / 10.0
                    let score = min(1, phraseScore * 0.45 + overlapScore * 0.35 + editScore * 0.15 + lengthBoost * 0.05)
                    if score > 0.18 {
                        matches.append(SubtitleMatch(mediaID: title.id, episodeID: episode.id, segmentID: segment.id, score: score, matchedText: segment.text))
                    }
                }
            }
        }

        return matches.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters.union(.symbols))
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func tokens(_ normalized: String) -> Set<String> {
        Set(normalized.split(separator: " ").map(String.init).filter { !stopWords.contains($0) })
    }

    private func phraseScore(query: String, segment: String) -> Double {
        if query == segment { return 1.0 }
        if segment.contains(query) || query.contains(segment) { return 0.82 }
        let queryWords = query.split(separator: " ").map(String.init)
        guard queryWords.count >= 3 else { return 0 }
        var bestRun = 0
        for start in queryWords.indices {
            var run = 0
            for end in start..<queryWords.count {
                let phrase = queryWords[start...end].joined(separator: " ")
                if segment.contains(phrase) {
                    run = max(run, end - start + 1)
                }
            }
            bestRun = max(bestRun, run)
        }
        return min(0.75, Double(bestRun) / Double(max(queryWords.count, 1)))
    }

    private func tokenOverlap(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return Double(intersection) / Double(union)
    }

    private func normalizedEditSimilarity(_ left: String, _ right: String) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let distance = levenshtein(Array(left), Array(right))
        let maxLength = max(left.count, right.count)
        return max(0, 1 - Double(distance) / Double(maxLength))
    }

    private func levenshtein(_ left: [Character], _ right: [Character]) -> Int {
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[right.count]
    }
}

