import SwiftUI
import AuthenticationServices
import ABSKit
import LibraryCache

/// Two-step sign-in: (1) the user enters a server URL and the app probes `/status`; (2) once the
/// server's advertised auth methods are known, render a password form (if `"local"` is active),
/// an OIDC button (if `"openid"` is active, labeled from `authFormData.authOpenIDButtonText`), or
/// both. `authOpenIDAutoLaunch` skips straight past the button and opens the sign-in sheet.
///
/// Doubles as the re-auth screen: when handed a `reauthConnection` (a connection whose stored
/// tokens went stale), it pre-fills that server's URL + username, probes `/status` immediately,
/// and dismisses itself back to `ConnectionsView` once the sign-in succeeds.
struct ConnectView: View {
    @Environment(AppState.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthSession
    @Environment(\.dismiss) private var dismiss

    /// Non-nil when this view is re-authenticating an existing connection (see the type doc).
    let reauthConnection: CachedConnection?

    @State private var serverURL: String
    @State private var username: String
    @State private var password = ""

    @State private var status: ServerStatus?
    @State private var isCheckingStatus = false
    @State private var statusError: String?

    init(reauthConnection: CachedConnection? = nil) {
        self.reauthConnection = reauthConnection
        _serverURL = State(initialValue: reauthConnection?.address ?? "http://localhost:13378")
        _username = State(initialValue: reauthConnection?.username ?? "root")
    }

    private var supportsLocal: Bool { status?.authMethods?.contains("local") ?? false }
    private var supportsOpenID: Bool { status?.authMethods?.contains("openid") ?? false }
    private var openIDButtonText: String { status?.authFormData?.authOpenIDButtonText ?? "Sign in with SSO" }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disabled(status != nil)
                if status == nil {
                    if let statusError {
                        Text(statusError).foregroundStyle(.red)
                    }
                    Button(isCheckingStatus ? "Checking…" : "Continue") { checkStatus() }
                        .disabled(isCheckingStatus || serverURL.isEmpty)
                } else {
                    Button("Change Server") { resetStatus() }
                }
            }

            if status != nil {
                if supportsLocal {
                    Section("Password") {
                        TextField("Username", text: $username)
                        SecureField("Password", text: $password)
                        Button(app.phase == .connecting ? "Connecting…" : "Sign In") {
                            Task { await app.connect(serverURL: serverURL, username: username, password: password) }
                        }
                        .disabled(app.phase == .connecting)
                    }
                }
                if supportsOpenID {
                    Section {
                        Button(app.phase == .connecting ? "Connecting…" : openIDButtonText) { startOIDC() }
                            .disabled(app.phase == .connecting)
                    }
                }
                if let error = app.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(reauthConnection == nil ? "Colophon" : "Sign In")
        .frame(maxWidth: 480)
        .task {
            // Re-auth: skip straight to the credential form for the known server.
            if reauthConnection != nil, status == nil { checkStatus() }
        }
        .onChange(of: app.phase) { _, phase in
            // A successful (re)connect pops this pushed screen back to `ConnectionsView`; on the
            // first-run root instance there's nothing to pop, so this is a harmless no-op there.
            if phase == .connected { dismiss() }
        }
    }

    private func checkStatus() {
        Task {
            isCheckingStatus = true
            statusError = nil
            defer { isCheckingStatus = false }
            do {
                let result = try await app.fetchStatus(serverURL: serverURL)
                status = result
                // Auto-launch skips the button entirely — the server wants the OIDC sheet to
                // appear the moment its auth methods are known, with no extra tap.
                if result.authFormData?.authOpenIDAutoLaunch == true {
                    startOIDC()
                }
            } catch {
                statusError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func resetStatus() {
        status = nil
        statusError = nil
        app.errorMessage = nil
    }

    private func startOIDC() {
        Task {
            await app.connectWithOIDC(serverURL: serverURL) { authorizeURL in
                try await webAuthSession.authenticate(using: authorizeURL, callbackURLScheme: "colophon")
            }
        }
    }
}
