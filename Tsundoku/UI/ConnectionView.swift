import SwiftUI

struct ConnectionView: View {
    enum Authentication: String, CaseIterable, Identifiable {
        case apiKey = "API Key"
        case password = "Email & Password"
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ServerKind = .komga
    @State private var name = ""
    @State private var url = ""
    @State private var authentication: Authentication = .apiKey
    @State private var apiKey = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Existing setup") {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(existingSetupMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Check Again", systemImage: "arrow.clockwise.icloud") {
                    appState.beginSetupReconciliation()
                }
                .accessibilityIdentifier("connection.checkSyncedSetup")
            }

            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(ServerKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Server name", text: $name)
                TextField(provider == .komga ? "https://komga.example.com" : "https://kavita.example.com", text: $url)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            } header: { Text("Content server") }

            Section {
                if provider == .komga {
                    Picker("Authentication", selection: $authentication) {
                        ForEach(Authentication.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                if provider == .kavita || authentication == .apiKey {
                    SecureField(provider == .kavita ? "Auth Key" : "API key", text: $apiKey)
                    if provider == .kavita {
                        Text("Create an Auth Key in Kavita user settings. You can also paste a full Kavita OPDS URL above and Tsundoku will extract its Auth Key.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Email", text: $email).textContentType(.username).textInputAutocapitalization(.never)
                    SecureField("Password", text: $password).textContentType(.password)
                    Text("Your password is used once to create a device-specific API key, then discarded.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if url.lowercased().hasPrefix("http://") {
                Section {
                    Label("LAN HTTP exposes your credentials and reading activity to the local network.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    connect()
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if isConnecting { ProgressView() }
                    }
                }
                .disabled(isConnecting || url.isEmpty || !hasAuthenticationInput)
            }
        }
        .navigationTitle("Add Server")
        .alert("Couldn’t connect", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func connect() {
        isConnecting = true
        Task {
            do {
                try await appState.addServer(
                    kind: provider,
                    name: name,
                    urlInput: url,
                    apiKey: provider == .kavita || authentication == .apiKey ? apiKey : nil,
                    email: provider == .komga && authentication == .password ? email : nil,
                    password: provider == .komga && authentication == .password ? password : nil
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private var hasAuthenticationInput: Bool {
        if provider == .kavita {
            return !apiKey.isEmpty || (try? KavitaURLParser.parse(url).pastedAuthKey) != nil
        }
        return authentication == .apiKey ? !apiKey.isEmpty : !email.isEmpty && !password.isEmpty
    }

    private var existingSetupMessage: String {
        switch appState.cloudSyncStatus {
        case .noAccount:
            "Sign in to iCloud and enable iCloud Keychain to restore setup from another device."
        case .restricted, .temporarilyUnavailable, .failed:
            "iCloud setup is temporarily unavailable. You can retry or add a server manually."
        case .checking, .available:
            "Checking iCloud and iCloud Keychain for setup from another device. You can also add a server manually."
        }
    }
}
