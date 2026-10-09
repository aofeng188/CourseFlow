import Foundation

/// Column placement for lessons that overlap within one day.
public struct LanePlacement: Equatable, Sendable {
    public var lane: Int
    public var laneCount: Int
    public init(lane: Int, laneCount: Int) { self.lane = lane; self.laneCount = laneCount }
}

public enum OccurrenceLayout {
    /// Groups lessons that overlap directly or through a chain (A overlaps B, B overlaps C)
    /// and gives every lesson in a group the same lane count, so blocks never cover each other.
    /// Each lesson takes the first lane that is free when it starts.
    public static func lanes(for occurrences: [Occurrence]) -> [String: LanePlacement] {
        let items = occurrences.sorted { $0.start == $1.start ? ($0.end == $1.end ? $0.id < $1.id : $0.end > $1.end) : $0.start < $1.start }
        var result: [String: LanePlacement] = [:]
        var group: [(id: String, lane: Int)] = []
        var laneEnds: [Date] = []
        var groupEnd = Date.distantPast
        func closeGroup() {
            for item in group { result[item.id] = LanePlacement(lane: item.lane, laneCount: laneEnds.count) }
            group.removeAll(); laneEnds.removeAll()
        }
        for item in items {
            if !group.isEmpty && item.start >= groupEnd { closeGroup() }
            if let free = laneEnds.firstIndex(where: { $0 <= item.start }) {
                laneEnds[free] = item.end
                group.append((item.id, free))
            } else {
                laneEnds.append(item.end)
                group.append((item.id, laneEnds.count - 1))
            }
            groupEnd = group.count == 1 ? item.end : max(groupEnd, item.end)
        }
        closeGroup()
        return result
    }
}
