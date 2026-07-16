import Foundation

enum SharedURLExtractor {
    static func firstURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let url = detector.firstMatch(in: text, options: [], range: range)?.url,
           isWebURL(url) {
            return url
        }

        return text
            .split(whereSeparator: { $0.isWhitespace })
            .lazy
            .compactMap { token -> URL? in
                let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>[](){}.,!\"'"))
                return URL(string: cleaned)
            }
            .first(where: isWebURL)
    }

    static func isWebURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
    }
}
