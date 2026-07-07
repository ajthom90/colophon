import Foundation

public struct ServerStatus: Decodable, Sendable {
    public let isInit: Bool
    public let serverVersion: String?
    public let authMethods: [String]?
    public let authFormData: AuthFormData?
}

/// The subset of `/status`'s `authFormData` object the sign-in UI needs to decide what to
/// render: an OIDC button's label, and whether to launch it automatically without waiting for
/// a tap. Server sends more fields (e.g. `authLoginCustomMessage`); unmodeled ones are ignored.
public struct AuthFormData: Decodable, Sendable {
    public let authOpenIDButtonText: String?
    public let authOpenIDAutoLaunch: Bool?
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

/// Full single-item detail from `GET /api/items/:id?expanded=1` — the per-item counterpart to
/// the minified `/items` list page. Used by `ABSClient.item(id:)` for `AppState`'s targeted
/// per-item socket patch (M1c-a Task 3, replacing a coarse full-library `refreshItems` for
/// `item_updated`/`item_added` events) and, in M1c-b, item-detail views. Decodes tolerantly:
/// only the fields Task 3 needs today are modeled here; unknown/future fields (chapters, full
/// relational metadata, progress) are simply ignored by `Decodable`'s default behavior and can
/// be added later without breaking this decode.
public struct LibraryItemDetail: Decodable, Sendable, Identifiable {
    public let id: String
    /// The item's owning library — present on every live server response; optional here only
    /// so a malformed/future response degrades to `AppState`'s `activeLibraryID` fallback
    /// instead of failing the whole decode.
    public let libraryId: String?
    public let updatedAt: Int?
    public let media: ExpandedItemMedia
}

public struct ExpandedItemMedia: Decodable, Sendable {
    public let duration: Double?
    public let metadata: ExpandedItemMetadata
}

/// Mirrors `MinifiedMetadata`'s `title`/`authorName` — `authorName` is a server-computed
/// convenience string (not the raw `authors` relational array), present in both the minified
/// and expanded metadata shapes.
public struct ExpandedItemMetadata: Decodable, Sendable {
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
