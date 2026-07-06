import Foundation
import GRDB

public struct CachedConnection: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedConnection"

    public var id: String
    public var address: String
    public var name: String
    public var username: String
    public var authMethod: String
    public var sortIndex: Int

    public init(id: String, address: String, name: String, username: String, authMethod: String, sortIndex: Int) {
        self.id = id
        self.address = address
        self.name = name
        self.username = username
        self.authMethod = authMethod
        self.sortIndex = sortIndex
    }
}

public struct CachedLibrary: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedLibrary"

    public var id: String
    public var connectionID: String
    public var name: String
    public var mediaType: String
    public var displayOrder: Int

    public init(id: String, connectionID: String, name: String, mediaType: String, displayOrder: Int) {
        self.id = id
        self.connectionID = connectionID
        self.name = name
        self.mediaType = mediaType
        self.displayOrder = displayOrder
    }
}

public struct CachedItem: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedItem"

    public var id: String
    public var connectionID: String
    public var libraryID: String
    public var title: String
    public var authorName: String?
    public var duration: Double?
    public var updatedAt: Int?

    public init(
        id: String,
        connectionID: String,
        libraryID: String,
        title: String,
        authorName: String? = nil,
        duration: Double? = nil,
        updatedAt: Int? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.libraryID = libraryID
        self.title = title
        self.authorName = authorName
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

public struct CachedProgress: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable, Hashable {
    public static let databaseTableName = "cachedProgress"

    public var connectionID: String
    public var itemID: String
    public var episodeID: String?
    public var currentTime: Double
    public var isFinished: Bool
    public var lastUpdate: Int

    public var id: String { connectionID + "/" + itemID }

    public init(
        connectionID: String,
        itemID: String,
        episodeID: String? = nil,
        currentTime: Double,
        isFinished: Bool,
        lastUpdate: Int
    ) {
        self.connectionID = connectionID
        self.itemID = itemID
        self.episodeID = episodeID
        self.currentTime = currentTime
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate
    }

    enum CodingKeys: String, CodingKey {
        case connectionID, itemID, episodeID, currentTime, isFinished, lastUpdate
    }
}
