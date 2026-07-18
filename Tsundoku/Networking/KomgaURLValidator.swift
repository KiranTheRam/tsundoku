import Foundation

enum KomgaURLValidationError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedScheme
    case publicHTTP
    case embeddedCredentials

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a complete server URL."
        case .unsupportedScheme: "Server URLs must use HTTPS or local-network HTTP."
        case .publicHTTP: "Unencrypted HTTP is only allowed for private or local-network hosts."
        case .embeddedCredentials: "Do not put credentials in the server URL."
        }
    }
}

enum KomgaURLValidator {
    static func validate(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty else {
            throw KomgaURLValidationError.invalidURL
        }
        guard components.user == nil, components.password == nil else { throw KomgaURLValidationError.embeddedCredentials }
        guard scheme == "https" || scheme == "http" else { throw KomgaURLValidationError.unsupportedScheme }
        if scheme == "http", !isLocalHost(host) { throw KomgaURLValidationError.publicHTTP }
        components.scheme = scheme
        components.path = components.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        guard let url = components.url else { throw KomgaURLValidationError.invalidURL }
        return url
    }

    static func isLocalHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".local") || !lowered.contains(".") { return true }
        if lowered == "::1" || lowered.hasPrefix("fe80:") || lowered.hasPrefix("fc") || lowered.hasPrefix("fd") { return true }
        let parts = lowered.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ 0...255 ~= $0 }) else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }
}

struct KavitaConnectionInput: Equatable, Sendable {
    let baseURL: URL
    let pastedAuthKey: String?
}

enum KavitaURLParser {
    static func parse(_ input: String) throws -> KavitaConnectionInput {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let host = components.host else {
            throw KomgaURLValidationError.invalidURL
        }
        let pastedKey = components.queryItems?
            .first { $0.name.caseInsensitiveCompare("apiKey") == .orderedSame }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        components.query = nil
        components.fragment = nil
        if let apiRange = components.path.range(of: "/api/", options: [.caseInsensitive]) {
            components.path = String(components.path[..<apiRange.lowerBound])
        } else if components.path.lowercased().hasSuffix("/api") {
            components.path.removeLast(4)
        }
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let candidate = components.url else { throw KomgaURLValidationError.invalidURL }
        let validated = try KomgaURLValidator.validate(candidate.absoluteString)
        guard validated.host == host else { throw KomgaURLValidationError.invalidURL }
        return KavitaConnectionInput(
            baseURL: validated,
            pastedAuthKey: pastedKey?.isEmpty == false ? pastedKey : nil
        )
    }
}
