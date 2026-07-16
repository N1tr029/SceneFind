import Foundation

protocol ResultRepository {
    func save(_ result: ClipAnalysisResult) throws
    func fetchAll() throws -> [ClipAnalysisResult]
    func delete(id: UUID) throws
    func clear() throws
}

final class LocalJSONResultRepository: ResultRepository {
    static let shared = LocalJSONResultRepository()

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    private var rootURL: URL {
        SharedContainerStore.shared.rootURL.appendingPathComponent("Results", isDirectory: true)
    }

    func save(_ result: ClipAnalysisResult) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try encoder.encode(result)
        try data.write(to: rootURL.appendingPathComponent("\(result.id.uuidString).json"), options: [.atomic])
    }

    func fetchAll() throws -> [ClipAnalysisResult] {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ClipAnalysisResult.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func delete(id: UUID) throws {
        let url = rootURL.appendingPathComponent("\(id.uuidString).json")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func clear() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
    }
}

