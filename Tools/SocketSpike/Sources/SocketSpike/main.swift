import Foundation
import SocketIO

// Usage: swift run SocketSpike http://localhost:13378 <accessToken>
let args = CommandLine.arguments
guard args.count == 3, let url = URL(string: args[1]) else {
    print("usage: SocketSpike <serverURL> <accessToken>"); exit(2)
}
let token = args[2]

// Reconnect-probe knobs (env-controlled so the exact-per-brief single-shot
// behavior is unchanged by default):
//   SPIKE_WINDOW=<seconds>   how long to keep the RunLoop alive (default 15)
//   SPIKE_KEEP_ALIVE=1       don't exit(0) on the first "init" — keep running
//                            so a container restart / reconnect can be observed
let window = Double(ProcessInfo.processInfo.environment["SPIKE_WINDOW"] ?? "") ?? 15
let keepAlive = ProcessInfo.processInfo.environment["SPIKE_KEEP_ALIVE"] == "1"

let manager = SocketManager(socketURL: url, config: [
    .log(true), .forceWebsockets(true), .version(.three), .compress,
])
let socket = manager.defaultSocket
var outcome = 1

socket.on(clientEvent: .connect) { _, _ in
    print("CONNECTED — emitting auth")
    socket.emit("auth", token)
}
socket.on(clientEvent: .disconnect) { data, _ in
    print("DISCONNECTED: \(data)")
}
socket.on(clientEvent: .reconnect) { data, _ in
    print("RECONNECT ATTEMPT: \(data)")
}
socket.on(clientEvent: .statusChange) { data, _ in
    print("STATUS CHANGE: \(data)")
}
socket.on("init") { data, _ in
    print("INIT RECEIVED: \(data)")
    outcome = 0
    if !keepAlive { exit(0) }
}
socket.on("auth_failed") { data, _ in
    print("AUTH FAILED: \(data)")
    exit(1)
}
socket.on(clientEvent: .error) { data, _ in print("ERROR: \(data)") }

socket.connect()
RunLoop.main.run(until: Date().addingTimeInterval(window))
if outcome != 0 {
    print("TIMEOUT — no init/auth_failed within \(window)s")
} else {
    print("RUN WINDOW ELAPSED (\(window)s) — init was received during the run")
}
exit(Int32(outcome))
