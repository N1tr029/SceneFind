import Foundation

struct SharedClipRequest: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let sourceType: SharedSourceType
    let sourcePlatform: SharedPlatform
    let originalURL: URL?
    let localFileName: String?
    let sharedText: String?
    let pageTitle: String?
    let thumbnailFileName: String?
    var status: SharedRequestStatus

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceType: SharedSourceType,
        sourcePlatform: SharedPlatform,
        originalURL: URL? = nil,
        localFileName: String? = nil,
        sharedText: String? = nil,
        pageTitle: String? = nil,
        thumbnailFileName: String? = nil,
        status: SharedRequestStatus = .pending
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceType = sourceType
        self.sourcePlatform = sourcePlatform
        self.originalURL = originalURL
        self.localFileName = localFileName
        self.sharedText = sharedText
        self.pageTitle = pageTitle
        self.thumbnailFileName = thumbnailFileName
        self.status = status
    }
}

enum SharedSourceType: String, Codable, CaseIterable, Hashable {
    case url
    case video
    case image
    case plainText
    case file
    case demo
    case unknown

    var label: String {
        switch self {
        case .url: "URL"
        case .video: "Video"
        case .image: "Image"
        case .plainText: "Text"
        case .file: "File"
        case .demo: "Demo"
        case .unknown: "Unknown"
        }
    }
}

enum SharedPlatform: String, Codable, CaseIterable, Hashable {
    case tiktok
    case youtube
    case instagram
    case facebook
    case reddit
    case x
    case safari
    case photos
    case files
    case genericWeb
    case unknown

    var label: String {
        switch self {
        case .tiktok: "TikTok"
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .facebook: "Facebook"
        case .reddit: "Reddit"
        case .x: "X"
        case .safari: "Safari"
        case .photos: "Photos"
        case .files: "Files"
        case .genericWeb: "Web"
        case .unknown: "Unknown"
        }
    }

    static func detect(url: URL?) -> SharedPlatform {
        guard let host = url?.host()?.lowercased() else { return .unknown }
        if host.contains("tiktok.com") || host == "vm.tiktok.com" { return .tiktok }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("instagram.com") { return .instagram }
        if host.contains("facebook.com") { return .facebook }
        if host.contains("reddit.com") { return .reddit }
        if host.contains("twitter.com") || host.contains("x.com") { return .x }
        return .genericWeb
    }
}

enum SharedRequestStatus: String, Codable, Hashable {
    case pending
    case imported
    case analyzed
    case failed
}

