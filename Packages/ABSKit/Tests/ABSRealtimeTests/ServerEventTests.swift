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
}
