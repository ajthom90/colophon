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
                        .alert("Playback error", isPresented: Binding(
                            get: { app.errorMessage != nil },
                            set: { if !$0 { app.errorMessage = nil } })
                        ) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text(app.errorMessage ?? "")
                        }
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
