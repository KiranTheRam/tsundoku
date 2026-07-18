import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

@MainActor
final class TrackerOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticateAniList(clientID: String) async throws -> String {
        guard !clientID.isEmpty else { throw TrackerClientError.notConfigured("AniList") }
        let state = Self.verifier()
        let callback = try await authenticate(url: Self.aniListAuthorizationURL(clientID: clientID, state: state))
        let parameters = Self.callbackParameters(from: callback)
        if let message = parameters["error_description"] ?? parameters["error"] { throw TrackerClientError.service(message) }
        guard Self.isAniListCallback(callback),
              parameters["state"] == state,
              let token = parameters["access_token"],
              !token.isEmpty else {
            throw TrackerClientError.invalidResponse
        }
        return token
    }

    func authenticateMAL(clientID: String) async throws -> (access: String, refresh: String?) {
        guard !clientID.isEmpty else { throw TrackerClientError.notConfigured("MyAnimeList") }
        let verifier = Self.verifier()
        let state = Self.verifier()
        let redirectURI = "tsundoku://oauth/mal"
        var components = URLComponents(string: "https://myanimelist.net/v1/oauth2/authorize")!
        components.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
            .init(name: "code_challenge", value: verifier), .init(name: "code_challenge_method", value: "plain"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "state", value: state)
        ]
        let callback = try await authenticate(url: components.url!)
        let parameters = Self.callbackParameters(from: callback)
        if let message = parameters["error_description"] ?? parameters["error"] { throw TrackerClientError.service(message) }
        guard parameters["state"] == state, let code = parameters["code"] else { throw TrackerClientError.invalidResponse }
        var request = URLRequest(url: URL(string: "https://myanimelist.net/v1/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier), .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: redirectURI)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateOAuthResponse(response, data: data)
        let token = try JSONDecoder().decode(MALTokenResponse.self, from: data)
        return (token.accessToken, token.refreshToken)
    }

    nonisolated static func refreshMAL(clientID: String, refreshToken: String) async throws -> (access: String, refresh: String?) {
        guard !clientID.isEmpty else { throw TrackerClientError.notConfigured("MyAnimeList") }
        let request = malRefreshRequest(clientID: clientID, refreshToken: refreshToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateOAuthResponse(response, data: data)
        let token = try JSONDecoder().decode(MALTokenResponse.self, from: data)
        return (token.accessToken, token.refreshToken)
    }

    nonisolated static func malRefreshRequest(clientID: String, refreshToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://myanimelist.net/v1/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("tsundoku")) { [weak self] url, error in
                self?.session = nil
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: TrackerClientError.invalidResponse) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: TrackerClientError.service("The sign-in session could not be started."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            return window
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            preconditionFailure("Tracker authentication requires an active window scene.")
        }
        return ASPresentationAnchor(windowScene: scene)
    }

    private static func verifier() -> String {
        Data((0..<64).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func aniListAuthorizationURL(clientID: String, state: String) -> URL {
        var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
        // AniList's implicit grant uses the redirect registered on the OAuth
        // application. Supplying redirect_uri here can be rejected after login.
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "token"),
            .init(name: "state", value: state)
        ]
        return components.url!
    }

    private static func isAniListCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "tsundoku"
            && url.host?.lowercased() == "oauth"
            && url.path == "/anilist"
    }

    static func callbackParameters(from url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var items = components.queryItems ?? []
        if let fragment = components.fragment {
            items += URLComponents(string: "?\(fragment)")?.queryItems ?? []
        }
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, latest in latest })
    }
}

private func validateOAuthResponse(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { throw TrackerClientError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        let message = (try? JSONDecoder().decode(OAuthErrorResponse.self, from: data).message) ?? "The tracker rejected the authorization request."
        throw TrackerClientError.service(message)
    }
}

private struct OAuthErrorResponse: Decodable {
    let message: String
    enum CodingKeys: String, CodingKey { case message = "error" }
}

private struct MALTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case refreshToken = "refresh_token" }
}
