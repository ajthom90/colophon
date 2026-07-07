import SwiftUI
import LibraryCache

/// The multi-server hub and the app's root once at least one connection exists. Lists every
/// stored `CachedConnection`, auto-resumes the last-active one on launch (cached-first — the
/// offline first-run fix lives in `AppState.activateConnection`), and offers add / sign-out /
/// remove. Tapping a healthy row activates it and pushes `LibrariesView`; tapping a row that
/// needs sign-in routes to a pre-filled `ConnectView` for re-auth.
struct ConnectionsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// `true` when presented as a modal server switcher from inside the navigation shell (the
    /// account menu): adds a Done button and suppresses the boot auto-resume so it lists the
    /// connections instead of re-activating and pushing the current library. Defaults to `false`
    /// — the root/boot usage is unchanged.
    var isModal = false

    /// Programmatic navigation so auto-resume can push straight into the library browser and a
    /// needs-sign-in tap can push a pre-filled `ConnectView`.
    private enum Route: Hashable {
        case libraries
        case addConnection
        case reauth(CachedConnection)
    }

    // Type-erased so `LibrariesView`'s `NavigationLink(value: CachedLibrary)` can push onto the
    // SAME stack as this view's `Route` values — a typed `[Route]` path would reject the library.
    @State private var path = NavigationPath()
    @State private var didAutoResume = false
    @State private var confirmingRemoval: CachedConnection?
    #if os(iOS)
    @State private var showingSettings = false
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(app.connections) { connection in
                    Button { open(connection) } label: { row(connection) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Remove", role: .destructive) { confirmingRemoval = connection }
                            Button("Sign Out") { Task { await app.signOut(connectionID: connection.id) } }
                                .tint(.orange)
                        }
                        .contextMenu {
                            Button("Sign Out") { Task { await app.signOut(connectionID: connection.id) } }
                            Button("Remove", role: .destructive) { confirmingRemoval = connection }
                        }
                }
            }
            .navigationTitle("Connections")
            .toolbar {
                #if os(iOS)
                // macOS gets its Settings access from the standard `Settings` scene (⌘,) added
                // in `ColophonApp`; iOS/iPadOS have no such menu, so a gear button presents the
                // same `SettingsView` as a sheet instead. Suppressed in the modal switcher, whose
                // host already offers Settings via the account menu.
                if !isModal {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
                #endif
                if isModal {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { path.append(Route.addConnection) } label: {
                        Label("Add Connection", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .libraries:
                    LibrariesView()
                case .addConnection:
                    ConnectView()
                case .reauth(let connection):
                    ConnectView(reauthConnection: connection)
                }
            }
            // Declared at the stack root (not inside the pushed `LibrariesView`, where a
            // destination-for-type registered from within another destination fails to resolve):
            // this is what `LibrariesView`'s `NavigationLink(value: CachedLibrary)` pushes into.
            .navigationDestination(for: CachedLibrary.self) { LibraryItemsView(library: $0) }
            .confirmationDialog(
                "Remove this connection?",
                isPresented: Binding(get: { confirmingRemoval != nil },
                                     set: { if !$0 { confirmingRemoval = nil } }),
                presenting: confirmingRemoval
            ) { connection in
                Button("Remove \(connection.name)", role: .destructive) {
                    Task { await app.removeConnection(connection.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { connection in
                Text("Deletes the offline cache for \(connection.name). Your account on the server is unaffected.")
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
        }
        #endif
        .task {
            app.loadConnections()
            guard !didAutoResume else { return }
            didAutoResume = true
            // Already connected (e.g. presented as the modal server switcher from within the
            // shell): don't re-activate and push — just list the connections so the user can
            // switch. At boot `activeConnectionID` is nil, so the auto-resume below still runs.
            guard app.activeConnectionID == nil else { return }
            // Auto-resume the last-active connection into the library browser — cached-first, so
            // this lands the user in their library even with the server down.
            if let lastID = app.lastActiveConnectionID,
               let lastConnection = app.connections.first(where: { $0.id == lastID }) {
                await app.activateConnection(lastID)
                // A connection with no stored (or rejected) tokens has no re-auth path from
                // inside `LibrariesView`'s offline banner — route straight to re-auth instead of
                // a dead end, same as a manual tap on a needs-sign-in row (see `open` below).
                if app.needsSignIn.contains(lastID) {
                    path.append(Route.reauth(lastConnection))
                } else {
                    path.append(Route.libraries)
                }
            }
        }
    }

    private func open(_ connection: CachedConnection) {
        if app.needsSignIn.contains(connection.id) {
            path.append(Route.reauth(connection))
        } else {
            Task {
                await app.activateConnection(connection.id)
                path.append(Route.libraries)
            }
        }
    }

    @ViewBuilder
    private func row(_ connection: CachedConnection) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(connection.id == app.activeConnectionID ? Color.accentColor : Color.clear)
                .frame(width: 9, height: 9)
                .accessibilityLabel(connection.id == app.activeConnectionID ? "Active" : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name).font(.headline)
                Text(connection.username).font(.subheadline).foregroundStyle(.secondary)
                Text(connection.address).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if app.needsSignIn.contains(connection.id) {
                Label("Sign in", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs sign-in")
            }
        }
        .contentShape(Rectangle())
    }
}
