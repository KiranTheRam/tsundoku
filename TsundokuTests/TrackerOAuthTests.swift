import Foundation
import Testing
@testable import Tsundoku

struct TrackerOAuthTests {
    @MainActor
    @Test func parsesAniListFragmentAndMALQueryCallbacks() throws {
        let aniList = try #require(URL(string: "tsundoku://oauth/anilist#access_token=abc123&state=state-a"))
        let mal = try #require(URL(string: "tsundoku://oauth/mal?code=code-1&state=state-b"))

        #expect(TrackerOAuth.callbackParameters(from: aniList)["access_token"] == "abc123")
        #expect(TrackerOAuth.callbackParameters(from: aniList)["state"] == "state-a")
        #expect(TrackerOAuth.callbackParameters(from: mal)["code"] == "code-1")
        #expect(TrackerOAuth.callbackParameters(from: mal)["state"] == "state-b")
    }

    @MainActor
    @Test func buildsAniListImplicitAuthorizationRequestWithoutRedirectOverride() throws {
        let url = TrackerOAuth.aniListAuthorizationURL(clientID: "12345", state: "state-a")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let parameters = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        #expect(components.scheme == "https")
        #expect(components.host == "anilist.co")
        #expect(components.path == "/api/v2/oauth/authorize")
        #expect(parameters["client_id"] == "12345")
        #expect(parameters["response_type"] == "token")
        #expect(parameters["state"] == "state-a")
        #expect(parameters["redirect_uri"] == nil)
    }

    @MainActor
    @Test func storesTrackerClientIDsInAppConfiguration() throws {
        let suiteName = "TrackerConfigurationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try AppModelContainer.make(inMemory: true)
        let engine = TrackerSyncEngine(
            modelContainer: container,
            credentials: CredentialStore(),
            defaults: defaults
        )

        engine.setClientID("  anilist-id  ", for: .aniList)
        engine.setClientID("mal-id", for: .myAnimeList)

        #expect(engine.configuredClientID(for: .aniList) == "anilist-id")
        #expect(engine.configuredClientID(for: .myAnimeList) == "mal-id")

        let secondSuiteName = "TrackerConfigurationTests.Second.\(UUID().uuidString)"
        let secondDefaults = try #require(UserDefaults(suiteName: secondSuiteName))
        defer { secondDefaults.removePersistentDomain(forName: secondSuiteName) }
        let restored = TrackerSyncEngine(
            modelContainer: container,
            credentials: CredentialStore(),
            defaults: secondDefaults
        )
        restored.refreshConfiguration()

        #expect(restored.configuredClientID(for: .aniList) == "anilist-id")
        #expect(restored.configuredClientID(for: .myAnimeList) == "mal-id")
    }

    @Test func buildsMALRefreshRequestWithPKCEPublicClientFields() throws {
        let request = TrackerOAuth.malRefreshRequest(clientID: "mal-client", refreshToken: "refresh-token")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let parameters = Dictionary(
            uniqueKeysWithValues: (URLComponents(string: "?\(body)")?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        #expect(request.url?.absoluteString == "https://myanimelist.net/v1/oauth2/token")
        #expect(request.httpMethod == "POST")
        #expect(parameters["client_id"] == "mal-client")
        #expect(parameters["grant_type"] == "refresh_token")
        #expect(parameters["refresh_token"] == "refresh-token")
    }

}
