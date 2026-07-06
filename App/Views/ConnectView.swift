import SwiftUI

struct ConnectView: View {
    @Environment(AppState.self) private var app
    @State private var serverURL = "http://localhost:13378"
    @State private var username = "root"
    @State private var password = ""

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            if let error = app.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            Button(app.phase == .connecting ? "Connecting…" : "Connect") {
                Task { await app.connect(serverURL: serverURL, username: username, password: password) }
            }
            .disabled(app.phase == .connecting)
        }
        .formStyle(.grouped)
        .navigationTitle("Colophon")
        .fontDesign(.serif)
        .frame(maxWidth: 480)
    }
}
