import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct EPUBPreparedDocument: Sendable {
    let fragment: String
    let html: String
    let resources: [String: String]
}

enum EPUBDocumentBuilder {
    static func prepare(
        fragment: String,
        preferences: EPUBReaderPreferences,
        baseURL: URL
    ) -> EPUBPreparedDocument {
        let sanitized = removeUntrustedMarkup(from: fragment)
        let pairs = resourcePairs(in: sanitized, baseURL: baseURL)
        let mappings = Dictionary(uniqueKeysWithValues: pairs.map { pair in
            (pair.sanitized.absoluteString, customResourceURL(for: pair.sanitized).absoluteString)
        })
        var rewritten = sanitized
        for pair in pairs.sorted(by: { $0.original.count > $1.original.count }) {
            let local = mappings[pair.sanitized.absoluteString]!
            rewritten = rewritten.replacingOccurrences(of: pair.original, with: local)
        }
        rewritten = removeCredentialQueries(from: rewritten)
        return EPUBPreparedDocument(
            fragment: rewritten,
            html: wrap(rewritten, preferences: preferences),
            resources: Dictionary(uniqueKeysWithValues: mappings.map { ($0.value, $0.key) })
        )
    }

    static func resourceReferences(in html: String, baseURL: URL) -> [URL] {
        var seen = Set<String>()
        return resourcePairs(in: html, baseURL: baseURL)
            .map(\.sanitized)
            .filter { seen.insert($0.absoluteString).inserted }
    }

    private static func resourcePairs(in html: String, baseURL: URL) -> [(original: String, sanitized: URL)] {
        let patterns = [
            #"(?i)(?:src|href)\s*=\s*["']([^"']*?/book-resources\?[^"']+)["']"#,
            #"(?i)url\(\s*["']?([^"')]*?/book-resources\?[^"')]+)["']?\s*\)"#
        ]
        var seen = Set<String>()
        var result: [(String, URL)] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for match in expression.matches(in: html, range: range) {
                guard match.numberOfRanges > 1,
                      let valueRange = Range(match.range(at: 1), in: html) else { continue }
                let value = String(html[valueRange]).replacingOccurrences(of: "&amp;", with: "&")
                guard let url = EPUBResourceReference.sanitized(value, relativeTo: baseURL),
                      seen.insert(value).inserted else { continue }
                result.append((value, url))
            }
        }
        return result
    }

    static func customResourceURL(for remoteURL: URL) -> URL {
        let token = Data(remoteURL.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "tsundoku-resource://remote/\(token)")!
    }

    static func remoteURL(from customURL: URL) -> URL? {
        guard customURL.scheme == "tsundoku-resource", customURL.host == "remote" else { return nil }
        var token = customURL.lastPathComponent
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while token.count % 4 != 0 { token.append("=") }
        guard let data = Data(base64Encoded: token),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: value)
    }

    static func resourceFileName(for remoteURL: URL) -> String {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let pathExtension = remoteURL.pathExtension.nilIfEmpty ?? "resource"
        return "\(hash).\(pathExtension)"
    }

    static func resourceMIMEType(for remoteURL: URL) -> String {
        let resourcePath = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("file") == .orderedSame })?
            .value
        let pathExtension = resourcePath
            .flatMap { URL(fileURLWithPath: $0).pathExtension.nilIfEmpty }
            ?? remoteURL.pathExtension.nilIfEmpty
        guard let pathExtension = pathExtension?.lowercased() else {
            return "application/octet-stream"
        }
        let knownFontType: String? = switch pathExtension {
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        default: nil
        }
        return knownFontType
            ?? UTType(filenameExtension: pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    static func unwrapServerPage(_ data: Data) throws -> String {
        if let decoded = try? JSONDecoder().decode(String.self, from: data) { return decoded }
        guard let raw = String(data: data, encoding: .utf8) else { throw KavitaClientError.invalidResponse }
        return raw
    }

    private static func removeUntrustedMarkup(from html: String) -> String {
        var value = replacing(
            pattern: #"(?is)<script\b[^>]*>.*?</script\s*>"#,
            in: html,
            with: ""
        )
        value = replacing(
            pattern: #"(?i)\s+on[a-z]+\s*=\s*(["']).*?\1"#,
            in: value,
            with: ""
        )
        value = replacing(
            pattern: #"(?i)(href|src)\s*=\s*(["'])\s*javascript:[^"']*\2"#,
            in: value,
            with: "$1=\"#\""
        )
        return value
    }

    private static func removeCredentialQueries(from html: String) -> String {
        replacing(
            pattern: #"(?i)([?&](?:apiKey|api_key|token|auth)=)[^&"'\s)>]*"#,
            in: html,
            with: ""
        )
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    private static func wrap(_ fragment: String, preferences: EPUBReaderPreferences) -> String {
        let colors: (background: String, foreground: String, link: String) = switch preferences.theme {
        case .dark: ("#111111", "#f0f0f0", "#8ab4f8")
        case .light: ("#ffffff", "#171717", "#2459a8")
        case .sepia: ("#f4ecd8", "#3d3427", "#735c2e")
        }
        let family: String = switch preferences.fontFamily {
        case .publisher: "inherit"
        case .system: "-apple-system, system-ui, sans-serif"
        case .serif: "ui-serif, Georgia, serif"
        }
        let pagination = preferences.mode == .paged
            ? "html{height:100%!important;width:100%!important;overflow-x:auto!important;overflow-y:hidden!important}body{height:100%!important;width:100vw!important;margin:0!important;padding:0!important;overflow:visible!important}.book-content{height:100vh!important;width:100vw!important;margin:0!important;padding:0 \(preferences.horizontalMargin)px!important;column-width:calc(100vw - \(preferences.horizontalMargin * 2)px)!important;column-gap:\(preferences.horizontalMargin * 2)px!important;column-fill:auto!important;overflow:visible!important}html::-webkit-scrollbar{display:none}"
            : "html,body{min-height:100%;overflow-x:hidden}.book-content{max-width:760px;margin:0 auto}"
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob: tsundoku-resource:; font-src data: tsundoku-resource:; style-src 'unsafe-inline' tsundoku-resource:; media-src tsundoku-resource:; connect-src 'none'; frame-src 'none'">
        <style>
        *{box-sizing:border-box} html,body{margin:0;padding:0;background:\(colors.background);color:\(colors.foreground)}
        body{font-family:\(family);font-size:\(preferences.fontSize)px;line-height:\(preferences.lineHeight);padding:0 \(preferences.horizontalMargin)px;-webkit-text-size-adjust:none}
        a{color:\(colors.link)} img,svg,video{max-width:100%;height:auto} table{max-width:100%}
        \(pagination)
        </style></head><body><main class="book-content">\(fragment)</main></body></html>
        """
    }
}

struct EPUBPackageManifest: Codable, Hashable, Sendable {
    let bookID: String
    let contentRevision: String
    let spineCount: Int
    var tableOfContents: [EPUBTableOfContentsItem]
    var resourceFiles: [String: String]
    var completedSpineIndexes: Set<Int>
    var completedResourceURLs: Set<String>

    var isComplete: Bool {
        completedSpineIndexes.count == spineCount
            && Set(resourceFiles.keys).isSubset(of: completedResourceURLs)
    }
}

enum EPUBOfflinePackage {
    static func manifestURL(for book: BookKey) -> URL {
        DownloadPaths.book(book).appending(path: "epub-manifest.json")
    }

    static func spineURL(for book: BookKey, index: Int) -> URL {
        let directory = DownloadPaths.book(book).appending(path: "spine", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(index).html")
    }

    static func resourceURL(for book: BookKey, remoteURL: URL) -> URL {
        let directory = DownloadPaths.book(book).appending(path: "resources", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: EPUBDocumentBuilder.resourceFileName(for: remoteURL))
    }

    static func loadManifest(for book: BookKey) -> EPUBPackageManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: book)) else { return nil }
        return try? JSONDecoder().decode(EPUBPackageManifest.self, from: data)
    }

    static func saveManifest(_ manifest: EPUBPackageManifest, for book: BookKey) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: manifestURL(for: book),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
