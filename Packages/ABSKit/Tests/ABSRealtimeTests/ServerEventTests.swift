import Foundation
import Testing
@testable import ABSRealtime

private func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
}

@Suite struct ServerEventTests {
    @Test func decodesProgressUpdate() {
        let payload = json(#"{"id":"prog1","sessionId":"ses_1","data":{"libraryItemId":"li_1","episodeId":null,"currentTime":42.5,"isFinished":false,"lastUpdate":1751790000000,"duration":100}}"#)
        let event = ServerEvent.decode(event: "user_item_progress_updated", payload: [payload])
        #expect(event == .progressUpdated(ProgressUpdate(
            itemID: "li_1", episodeID: nil, currentTime: 42.5, isFinished: false, lastUpdate: 1751790000000)))
    }

    @Test func decodesItemLifecycleEvents() {
        #expect(ServerEvent.decode(event: "item_updated", payload: [json(#"{"id":"li_9"}"#)]) == .itemChanged(id: "li_9"))
        #expect(ServerEvent.decode(event: "item_added", payload: [json(#"{"id":"li_9"}"#)]) == .itemChanged(id: "li_9"))
        #expect(ServerEvent.decode(event: "item_removed", payload: [json(#"{"id":"li_9"}"#)]) == .itemRemoved(id: "li_9"))
        #expect(ServerEvent.decode(event: "items_updated",
                                   payload: [[json(#"{"id":"a"}"#), json(#"{"id":"b"}"#)]]) == .itemsChanged(ids: ["a", "b"]))
    }

    @Test func unknownOrMalformedYieldsNil() {
        #expect(ServerEvent.decode(event: "pong", payload: []) == nil)
        #expect(ServerEvent.decode(event: "user_item_progress_updated", payload: ["garbage"]) == nil)
        #expect(ServerEvent.decode(event: "item_updated", payload: [json(#"{"noID":true}"#)]) == nil)
    }

    /// `user_updated` fires on web-UI mark-finished / manual progress edits — the server
    /// pushes the WHOLE user object, not a per-item delta, so decoding maps its
    /// `mediaProgress` array into a batch of `ProgressUpdate`s.
    @Test func decodesUserUpdatedProgressBatch() {
        let payload = json(#"""
        {"id":"root","username":"root","mediaProgress":[
          {"id":"prog1","libraryItemId":"li_1","episodeId":null,"currentTime":42.5,"isFinished":false,"lastUpdate":1751790000000,"duration":100},
          {"id":"prog2","libraryItemId":"li_2","episodeId":"ep_9","currentTime":10.0,"isFinished":true,"lastUpdate":1751790005000,"duration":50}
        ]}
        """#)
        let event = ServerEvent.decode(event: "user_updated", payload: [payload])
        #expect(event == .progressBatch([
            ProgressUpdate(itemID: "li_1", episodeID: nil, currentTime: 42.5, isFinished: false, lastUpdate: 1751790000000),
            ProgressUpdate(itemID: "li_2", episodeID: "ep_9", currentTime: 10.0, isFinished: true, lastUpdate: 1751790005000),
        ]))
    }

    @Test func userUpdatedMalformedOrEmptyYieldsNil() {
        #expect(ServerEvent.decode(event: "user_updated", payload: ["garbage"]) == nil)
        #expect(ServerEvent.decode(event: "user_updated", payload: [json(#"{"id":"root"}"#)]) == nil)
        #expect(ServerEvent.decode(event: "user_updated", payload: [json(#"{"id":"root","mediaProgress":[]}"#)]) == nil)
        #expect(ServerEvent.decode(event: "user_updated",
                                   payload: [json(#"{"id":"root","mediaProgress":[{"noItemId":true}]}"#)]) == nil)
    }
}
