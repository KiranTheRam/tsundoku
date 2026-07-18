import Foundation
import XCTest
@testable import Tsundoku

final class TrackerClientPayloadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TrackerMockURLProtocol.requests = []
        TrackerMockURLProtocol.requestBodies = []
    }

    func testAniListSendsChapterAndVolumeProgress() async throws {
        let client = AniListClient(token: "test-token", session: makeSession())
        try await client.update(mediaID: 42, progress: 18, volumeProgress: 2, status: "CURRENT")

        let request = try XCTUnwrap(TrackerMockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.host, "graphql.anilist.co")
        let body = try XCTUnwrap(TrackerMockURLProtocol.requestBodies.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try XCTUnwrap(object["variables"] as? [String: Any])
        XCTAssertEqual(variables["mediaId"] as? Int, 42)
        XCTAssertEqual(variables["progress"] as? Int, 18)
        XCTAssertEqual(variables["progressVolumes"] as? Int, 2)
        XCTAssertEqual(variables["status"] as? String, "CURRENT")
    }

    func testMALSendsChapterAndVolumeProgress() async throws {
        let client = MyAnimeListClient(token: "test-token", session: makeSession())
        try await client.update(mediaID: 42, progress: 18, volumeProgress: 2, status: "CURRENT")

        let request = try XCTUnwrap(TrackerMockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v2/manga/42/my_list_status")
        let body = try XCTUnwrap(TrackerMockURLProtocol.requestBodies.first.flatMap { String(data: $0, encoding: .utf8) })
        let values = Dictionary(uniqueKeysWithValues: (URLComponents(string: "?\(body)")?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(values["status"], "reading")
        XCTAssertEqual(values["num_chapters_read"], "18")
        XCTAssertEqual(values["num_volumes_read"], "2")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackerMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TrackerMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        Self.requests.append(request)
        if let body = Self.bodyData(for: request) { Self.requestBodies.append(body) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":{"SaveMediaListEntry":{"id":1}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
