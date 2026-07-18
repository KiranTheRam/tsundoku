import Foundation

struct ServerID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    init?(string: String) {
        guard let value = UUID(uuidString: string) else { return nil }
        rawValue = value
    }

    var id: UUID { rawValue }
    var description: String { rawValue.uuidString }
}

struct SeriesKey: Hashable, Codable, Sendable, Identifiable {
    let serverID: ServerID
    let remoteID: String
    var id: String { "\(serverID.description):series:\(remoteID)" }
}

struct BookKey: Hashable, Codable, Sendable, Identifiable {
    let serverID: ServerID
    let remoteID: String
    var id: String { "\(serverID.description):book:\(remoteID)" }
}

struct PageKey: Hashable, Codable, Sendable, Identifiable {
    let book: BookKey
    let index: Int
    var id: String { "\(book.id):page:\(index)" }
}

