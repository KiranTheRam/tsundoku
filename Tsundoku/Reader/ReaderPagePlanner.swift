import CoreGraphics
import Foundation

struct PageSegment: Hashable, Sendable {
    let pageIndex: Int
    let normalizedCrop: CGRect
}

struct ReaderDisplayUnit: Hashable, Sendable, Identifiable {
    let segments: [PageSegment]
    var id: String { segments.map { "\($0.pageIndex):\($0.normalizedCrop.minX)" }.joined(separator: "+") }
    var firstPage: Int { segments.first?.pageIndex ?? 0 }
}

enum ReaderPagePlanner {
    static func units(pages: [BookPage], preferences: ReaderPreferences, landscape: Bool) -> [ReaderDisplayUnit] {
        let split = pages.flatMap { page -> [PageSegment] in
            guard page.isWide, preferences.widePagePolicy == .split, preferences.mode != .verticalContinuous else {
                return [PageSegment(pageIndex: page.number - 1, normalizedCrop: CGRect(x: 0, y: 0, width: 1, height: 1))]
            }
            let left = PageSegment(pageIndex: page.number - 1, normalizedCrop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
            let right = PageSegment(pageIndex: page.number - 1, normalizedCrop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
            return preferences.mode == .pagedRightToLeft ? [right, left] : [left, right]
        }

        guard preferences.mode != .verticalContinuous else { return split.map { ReaderDisplayUnit(segments: [$0]) } }
        let useSpreads = preferences.spreadMode == .double || (preferences.spreadMode == .automatic && landscape)
        guard useSpreads else { return split.map { ReaderDisplayUnit(segments: [$0]) } }

        var output: [ReaderDisplayUnit] = []
        var index = 0
        if preferences.keepsCoverSingle, !split.isEmpty {
            output.append(ReaderDisplayUnit(segments: [split[0]]))
            index = 1
        }
        while index < split.count {
            let end = min(index + 2, split.count)
            var pair = Array(split[index..<end])
            if preferences.mode == .pagedRightToLeft { pair.reverse() }
            output.append(ReaderDisplayUnit(segments: pair))
            index = end
        }
        return output
    }
}

