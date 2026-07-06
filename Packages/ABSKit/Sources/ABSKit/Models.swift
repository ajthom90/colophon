import Foundation

public struct ServerStatus: Decodable, Sendable {
    public let isInit: Bool
    public let serverVersion: String?
    public let authMethods: [String]?
}

public struct LoginResponse: Decodable, Sendable {
    public let user: User
    public let userDefaultLibraryId: String?
}

public struct User: Decodable, Sendable {
    public let id: String
    public let username: String
    public let accessToken: String?
    public let refreshToken: String?
}

public struct LibrariesResponse: Decodable, Sendable { public let libraries: [Library] }

public struct Library: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let mediaType: String
    public let icon: String?
    public let displayOrder: Int?
}

public struct ItemsPage: Decodable, Sendable {
    public let results: [LibraryItemSummary]
    public let total: Int
    public let limit: Int
    public let page: Int
}

public struct LibraryItemSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let updatedAt: Int?
    public let media: MinifiedMedia
}

public struct MinifiedMedia: Decodable, Sendable, Hashable {
    public let duration: Double?
    public let metadata: MinifiedMetadata
}

public struct MinifiedMetadata: Decodable, Sendable, Hashable {
    public let title: String?
    public let authorName: String?
}

public struct PlaybackSession: Decodable, Sendable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    public let displayTitle: String?
    public let displayAuthor: String?
    public let duration: Double
    public let startTime: Double
    public let currentTime: Double?
    public let playMethod: Int
    public let audioTracks: [AudioTrack]
    public let chapters: [Chapter]
}

public struct AudioTrack: Decodable, Sendable {
    public let index: Int
    public let startOffset: Double
    public let duration: Double
    public let title: String?
    public let contentUrl: String?
    public let mimeType: String?
}

public struct Chapter: Decodable, Sendable, Identifiable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String?
}

public struct DeviceInfo: Encodable, Sendable {
    public let deviceId: String
    public let clientName: String
    public let clientVersion: String
    public let manufacturer: String
    public let model: String
    public init(deviceId: String, clientName: String = "Colophon",
                clientVersion: String, manufacturer: String = "Apple", model: String) {
        self.deviceId = deviceId; self.clientName = clientName
        self.clientVersion = clientVersion; self.manufacturer = manufacturer; self.model = model
    }
}
