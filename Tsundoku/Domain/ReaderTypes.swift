import Foundation

enum PagedDirection: String, Codable, CaseIterable, Sendable, Identifiable {
    case leftToRight
    case rightToLeft

    var id: String { rawValue }
    var title: String { self == .leftToRight ? "Left to right" : "Right to left" }
}

enum ReaderMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case pagedLeftToRight
    case pagedRightToLeft
    case verticalContinuous

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pagedLeftToRight: "Paged · Left to right"
        case .pagedRightToLeft: "Paged · Right to left"
        case .verticalContinuous: "Vertical continuous"
        }
    }

    var direction: PagedDirection? {
        switch self {
        case .pagedLeftToRight: .leftToRight
        case .pagedRightToLeft: .rightToLeft
        case .verticalContinuous: nil
        }
    }
}

enum SpreadMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic
    case single
    case double
    var id: String { rawValue }
}

enum WidePagePolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case fit
    case split
    var id: String { rawValue }
}

enum CropPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case automatic
    var id: String { rawValue }
}

struct ReaderPreferences: Codable, Hashable, Sendable {
    var mode: ReaderMode
    var spreadMode: SpreadMode
    var widePagePolicy: WidePagePolicy
    var cropPolicy: CropPolicy
    var pageGap: Double
    var showsStatusBar: Bool
    var keepsCoverSingle: Bool
    var brightness: Double

    init(
        mode: ReaderMode = .pagedRightToLeft,
        spreadMode: SpreadMode = .automatic,
        widePagePolicy: WidePagePolicy = .split,
        cropPolicy: CropPolicy = .none,
        pageGap: Double = 8,
        showsStatusBar: Bool = false,
        keepsCoverSingle: Bool = true,
        brightness: Double = 1
    ) {
        self.mode = mode
        self.spreadMode = spreadMode
        self.widePagePolicy = widePagePolicy
        self.cropPolicy = cropPolicy
        self.pageGap = pageGap
        self.showsStatusBar = showsStatusBar
        self.keepsCoverSingle = keepsCoverSingle
        self.brightness = brightness
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(ReaderMode.self, forKey: .mode) ?? .pagedRightToLeft
        spreadMode = try values.decodeIfPresent(SpreadMode.self, forKey: .spreadMode) ?? .automatic
        widePagePolicy = try values.decodeIfPresent(WidePagePolicy.self, forKey: .widePagePolicy) ?? .split
        cropPolicy = try values.decodeIfPresent(CropPolicy.self, forKey: .cropPolicy) ?? .none
        pageGap = try values.decodeIfPresent(Double.self, forKey: .pageGap) ?? 8
        showsStatusBar = try values.decodeIfPresent(Bool.self, forKey: .showsStatusBar) ?? false
        keepsCoverSingle = try values.decodeIfPresent(Bool.self, forKey: .keepsCoverSingle) ?? true
        brightness = try values.decodeIfPresent(Double.self, forKey: .brightness) ?? 1
    }
}

enum TrackerProgressRule: Hashable, Codable, Sendable {
    case bookNumber(offset: Int)
    case completedBookCount(offset: Int)
    case manualPerBook([String: Int])

    func progress(completedBooks: [TrackerBookProgress]) -> Int {
        switch self {
        case .bookNumber(let offset):
            let number = completedBooks.filter(\.completed).map(\.numberSort).max() ?? 0
            return max(0, Int(floor(number)) + offset)
        case .completedBookCount(let offset):
            return max(0, completedBooks.filter(\.completed).count + offset)
        case .manualPerBook(let mapping):
            return completedBooks.filter(\.completed).compactMap { mapping[$0.bookID] }.max() ?? 0
        }
    }
}

struct TrackerBookProgress: Hashable, Codable, Sendable {
    let bookID: String
    let numberSort: Double
    let completed: Bool
    let trackerProgressUnit: TrackerProgressUnit

    init(
        bookID: String,
        numberSort: Double,
        completed: Bool,
        trackerProgressUnit: TrackerProgressUnit = .chapter
    ) {
        self.bookID = bookID
        self.numberSort = numberSort
        self.completed = completed
        self.trackerProgressUnit = trackerProgressUnit
    }
}

struct TrackerProgressUpdate: Equatable, Sendable {
    let chapterProgress: Int
    let volumeProgress: Int?
    let completed: Bool
}

enum TrackerMatchPolicy {
    static func confidentMatch(
        for seriesTitle: String,
        in candidates: [TrackerMedia]
    ) -> TrackerMedia? {
        let query = normalized(seriesTitle)
        guard !query.isEmpty else { return nil }

        let scored = candidates.map { candidate in
            let titles = [candidate.title, candidate.alternateTitle].compactMap { $0 }
            let values = titles.map { similarity(query, normalized($0)) }
            return (candidate, values.max() ?? 0)
        }
        .sorted {
            if $0.1 == $1.1 { return $0.0.id < $1.0.id }
            return $0.1 > $1.1
        }

        guard let best = scored.first else { return nil }
        let runnerUp = scored.dropFirst().first?.1 ?? 0
        if best.1 == 1 { return runnerUp < 1 ? best.0 : nil }
        guard best.1 >= 0.82, best.1 - runnerUp >= 0.15 else { return nil }
        return best.0
    }

    private static func normalized(_ title: String) -> String {
        let folded = title
            .replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        let left = Set(lhs.split(separator: " ").map(String.init))
        let right = Set(rhs.split(separator: " ").map(String.init))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let overlap = left.intersection(right).count
        return (2 * Double(overlap)) / Double(left.count + right.count)
    }
}

struct TrackerPromptDecision: Codable, Equatable, Hashable, Sendable {
    let seriesID: String
    let handledAt: Date
}

struct TrackerPromptState: Codable, Equatable, Sendable {
    let decisions: [TrackerPromptDecision]
    let resetAt: Date?

    static let empty = TrackerPromptState(decisions: [], resetAt: nil)
}

enum TrackerPromptSyncPolicy {
    static func merge(_ lhs: TrackerPromptState, _ rhs: TrackerPromptState) -> TrackerPromptState {
        let resetAt = [lhs.resetAt, rhs.resetAt].compactMap { $0 }.max()
        var newest: [String: TrackerPromptDecision] = [:]
        for decision in lhs.decisions + rhs.decisions
            where decision.handledAt > (resetAt ?? .distantPast)
            && (newest[decision.seriesID]?.handledAt ?? .distantPast) < decision.handledAt {
            newest[decision.seriesID] = decision
        }
        return TrackerPromptState(
            decisions: newest.values.sorted { $0.seriesID < $1.seriesID },
            resetAt: resetAt
        )
    }
}

enum TrackerProgressCalculator {
    static func update(
        rule: TrackerProgressRule,
        books: [TrackerBookProgress]
    ) -> TrackerProgressUpdate {
        let volumeBooks = books.filter { $0.trackerProgressUnit == .volume }
        return TrackerProgressUpdate(
            chapterProgress: rule.progress(completedBooks: books),
            volumeProgress: volumeBooks.isEmpty ? nil : volumeBooks.filter(\.completed).count,
            completed: !books.isEmpty && books.allSatisfy(\.completed)
        )
    }
}

struct ReadingCheckpoint: Hashable, Codable, Sendable {
    let book: BookKey
    var page: Int
    var pageCount: Int
    var completed: Bool
    var observedAt: Date
    var intentionalRegression: Bool
    var remoteContext: RemoteBookContext?
    var epubLocator: String?

    init(
        book: BookKey,
        zeroBasedPage: Int,
        pageCount: Int,
        completed: Bool = false,
        observedAt: Date = .now,
        intentionalRegression: Bool = false,
        remoteContext: RemoteBookContext? = nil,
        epubLocator: String? = nil
    ) {
        self.book = book
        page = max(0, zeroBasedPage) + 1
        self.pageCount = pageCount
        self.completed = completed || page >= pageCount
        self.observedAt = observedAt
        self.intentionalRegression = intentionalRegression
        self.remoteContext = remoteContext
        self.epubLocator = epubLocator
    }

    init(
        book: Book,
        zeroBasedPage: Int,
        pageCount: Int? = nil,
        completed: Bool = false,
        observedAt: Date = .now,
        intentionalRegression: Bool = false,
        epubLocator: String? = nil
    ) {
        self.init(
            book: book.key,
            zeroBasedPage: zeroBasedPage,
            pageCount: pageCount ?? book.pageCount,
            completed: completed,
            observedAt: observedAt,
            intentionalRegression: intentionalRegression,
            remoteContext: book.remoteContext,
            epubLocator: epubLocator
        )
    }
}

struct RemoteProgress: Hashable, Codable, Sendable {
    let position: Int?
    let completed: Bool
    let modifiedAt: Date?
    let epubLocator: String?
}

enum EPUBReaderMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case paged
    case scrolling

    var id: String { rawValue }
    var title: String {
        switch self {
        case .paged: "Paged"
        case .scrolling: "Vertical scroll"
        }
    }
}

enum EPUBTheme: String, Codable, CaseIterable, Sendable, Identifiable {
    case dark
    case light
    case sepia

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum EPUBFontFamily: String, Codable, CaseIterable, Sendable, Identifiable {
    case publisher
    case system
    case serif

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct EPUBReaderPreferences: Codable, Hashable, Sendable {
    var mode: EPUBReaderMode = .paged
    var theme: EPUBTheme = .dark
    var fontFamily: EPUBFontFamily = .publisher
    var fontSize: Double = 18
    var lineHeight: Double = 1.55
    var horizontalMargin: Double = 24
}

enum ProgressConflictResolution: Equatable, Sendable {
    case keepRemote
    case pushLocal
    case pushCompletion
    case pushRegression
}

struct ProgressMergePolicy: Sendable {
    func resolve(
        local: ReadingCheckpoint,
        remotePage: Int?,
        remoteCompleted: Bool,
        remoteObservedAt: Date?
    ) -> ProgressConflictResolution {
        if local.intentionalRegression { return .pushRegression }
        if let remoteObservedAt, remoteObservedAt > local.observedAt { return .keepRemote }
        if local.completed { return .pushCompletion }
        guard let remotePage else { return .pushLocal }
        if remoteCompleted || local.page < remotePage { return .pushRegression }
        return local.page == remotePage ? .keepRemote : .pushLocal
    }
}
