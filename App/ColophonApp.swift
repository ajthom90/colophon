import SwiftUI

@main
struct ColophonApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if app.phase == .connected {
                    NavigationStack { LibrariesView() }
                        .safeAreaInset(edge: .bottom) { PlayerBarView() }
                } else {
                    NavigationStack { ConnectView() }
                }
            }
            .environment(app)
            .task {
                #if DEBUG
                await app.runAutoConnectIfRequested()
                #endif
            }
        }
    }
}
