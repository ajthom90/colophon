import Foundation

public struct ProgressUpdate: Sendable, Equatable {
    public let itemID: String
    public let episodeID: String?
    public let currentTime: Double
    public let isFinished: Bool
    public let lastUpdate: Int
    public init(itemID: String, episodeID: String?, currentTime: Double, isFinished: Bool, lastUpdate: Int) {
        self.itemID = itemID; self.episodeID = episodeID
        self.currentTime = currentTime; self.isFinished = isFinished; self.lastUpdate = lastUpdate
    }
}

public enum ServerEvent: Sendable, Equatable {
    case progressUpdated(ProgressUpdate)
    /// `user_updated`: the server pushes the WHOLE user object (web-UI mark-finished / manual
    /// progress edits don't get a per-item `user_item_progress_updated` — the only signal is
    /// this batch), so decoding maps its `mediaProgress` array into one update per entry.
    case progressBatch([ProgressUpdate])
    case itemChanged(id: String)
    case itemsChanged(ids: [String])
    case itemRemoved(id: String)

    public static func decode(event: String, payload: [Any]) -> ServerEvent? {
        switch event {
        case "user_item_progress_updated":
            guard let dict = payload.first as? [String: Any],
                  let data = dict["data"] as? [String: Any],
                  let itemID = data["libraryItemId"] as? String,
                  let currentTime = data["currentTime"] as? Double,
                  let lastUpdate = data["lastUpdate"] as? Int else { return nil }
            return .progressUpdated(ProgressUpdate(
                itemID: itemID,
                episodeID: data["episodeId"] as? String,
                currentTime: currentTime,
                isFinished: data["isFinished"] as? Bool ?? false,
                lastUpdate: lastUpdate))
        case "user_updated":
            guard let user = payload.first as? [String: Any],
                  let mediaProgress = user["mediaProgress"] as? [[String: Any]],
                  !mediaProgress.isEmpty else { return nil }
            let updates = mediaProgress.compactMap { entry -> ProgressUpdate? in
                guard let itemID = entry["libraryItemId"] as? String,
                      let currentTime = entry["currentTime"] as? Double,
                      let lastUpdate = entry["lastUpdate"] as? Int else { return nil }
                return ProgressUpdate(
                    itemID: itemID,
                    episodeID: entry["episodeId"] as? String,
                    currentTime: currentTime,
                    isFinished: entry["isFinished"] as? Bool ?? false,
                    lastUpdate: lastUpdate)
            }
            return updates.isEmpty ? nil : .progressBatch(updates)
        case "item_updated", "item_added":
            guard let dict = payload.first as? [String: Any], let id = dict["id"] as? String else { return nil }
            return .itemChanged(id: id)
        case "item_removed":
            guard let dict = payload.first as? [String: Any], let id = dict["id"] as? String else { return nil }
            return .itemRemoved(id: id)
        case "items_updated", "items_added":
            guard let array = payload.first as? [[String: Any]] else { return nil }
            let ids = array.compactMap { $0["id"] as? String }
            return ids.isEmpty ? nil : .itemsChanged(ids: ids)
        default:
            return nil
        }
    }
}
