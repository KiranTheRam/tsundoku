import SwiftData
import SwiftUI

struct TrackerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Query private var mutations: [TrackerMutationRecord]

    var body: some View {
        List {
            Section {
                ForEach(TrackerService.allCases) { service in
                    NavigationLink {
                        TrackerServiceSettingsView(service: service)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: service.symbol)
                                .font(.title2)
                                .frame(width: 32)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(service.title)
                                Text(status(for: service))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Open a tracker to enter its Client ID, sign in on the provider’s website, and test the connection. Tokens are stored in Keychain.")
            }

            if !mutations.isEmpty {
                Section("Pending updates") {
                    ForEach(mutations) { mutation in
                        VStack(alignment: .leading) {
                            Text("\(mutation.service) · media \(mutation.mediaID)")
                            Text(mutation.lastError ?? "Queued").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Retry now") { Task { await appState.trackers.retryPending() } }
                }
            }
        }
        .navigationTitle("Trackers")
        .task { await appState.trackers.refreshConnections() }
    }

    private func status(for service: TrackerService) -> String {
        if appState.trackers.connected.contains(service) { return "Connected" }
        return appState.trackers.configuredClientID(for: service).isEmpty ? "Client ID required" : "Ready to sign in"
    }
}

private struct TrackerServiceSettingsView: View {
    @Environment(AppState.self) private var appState
    let service: TrackerService

    @State private var clientID = ""
    @State private var isWorking = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("OAuth application") {
                TextField(service == .aniList ? "Client ID (number)" : "Client ID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(service == .aniList ? .numberPad : .asciiCapable)
                    .accessibilityIdentifier("tracker.clientID.\(service.rawValue)")

                Button("Save Client ID", systemImage: "square.and.arrow.down") {
                    saveConfiguration()
                }
                .disabled(normalizedClientID.isEmpty)

                Link("Open \(service.title) developer settings", destination: service.developerSettingsURL)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Registered callback URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(service.callbackURL)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }

                Text(configurationHelp)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Account") {
                LabeledContent("Status", value: isConnected ? "Connected" : "Not connected")

                Button {
                    signIn()
                } label: {
                    if isWorking {
                        HStack { ProgressView(); Text("Opening \(service.title)…") }
                    } else {
                        Label(isConnected ? "Sign in again" : "Sign in with \(service.title)", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(normalizedClientID.isEmpty || isWorking)
                .accessibilityIdentifier("tracker.signIn.\(service.rawValue)")

                Button("Test connection", systemImage: "checkmark.icloud") {
                    testConnection()
                }
                .disabled(!isConnected || isWorking)

                if isConnected {
                    Button("Disconnect", systemImage: "link.badge.minus", role: .destructive) {
                        Task {
                            await appState.trackers.disconnect(service)
                            resultMessage = "Disconnected from \(service.title)."
                        }
                    }
                }

                if let resultMessage {
                    Label(resultMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Text("Reading updates are sent only after the active content server accepts progress. A tracker outage never blocks reading synchronization.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(service.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            clientID = appState.trackers.configuredClientID(for: service)
            await appState.trackers.refreshConnections()
        }
        .alert("Tracker error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var normalizedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var configurationHelp: String {
        if service == .aniList {
            return "Create an AniList OAuth application, register the callback URL exactly as shown, then enter the numeric Client ID—not the Client Secret. AniList’s mobile implicit flow intentionally uses the public Client ID only."
        }
        return "Create a MyAnimeList OAuth application, register the callback URL exactly as shown, then paste its Client ID above. The app uses PKCE and does not store a client secret."
    }

    private var isConnected: Bool {
        appState.trackers.connected.contains(service)
    }

    private func saveConfiguration() {
        guard validateClientID() else { return }
        appState.trackers.setClientID(normalizedClientID, for: service)
        resultMessage = "Client ID saved."
    }

    private func signIn() {
        guard validateClientID() else { return }
        appState.trackers.setClientID(normalizedClientID, for: service)
        isWorking = true
        resultMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let account = try await appState.trackers.connect(service)
                resultMessage = "Connected as \(account)."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func validateClientID() -> Bool {
        guard !normalizedClientID.isEmpty else {
            errorMessage = "Enter the Client ID first."
            return false
        }
        if service == .aniList, !normalizedClientID.allSatisfy(\.isNumber) {
            errorMessage = "AniList’s Client ID is the short number shown in Developer Settings. Do not paste the Client Secret here."
            return false
        }
        return true
    }

    private func testConnection() {
        isWorking = true
        resultMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let account = try await appState.trackers.testConnection(service)
                resultMessage = "Connected as \(account)."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension TrackerService {
    var symbol: String {
        self == .aniList ? "chart.bar.doc.horizontal" : "list.bullet.rectangle"
    }

    var callbackURL: String {
        self == .aniList ? "tsundoku://oauth/anilist" : "tsundoku://oauth/mal"
    }

    var developerSettingsURL: URL {
        if self == .aniList { return URL(string: "https://anilist.co/settings/developer")! }
        return URL(string: "https://myanimelist.net/apiconfig")!
    }
}
