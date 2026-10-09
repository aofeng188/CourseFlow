import Foundation
import Testing
@testable import CourseKit

@Suite("周课表重叠课程分栏")
struct OccurrenceLayoutTests {
    private let base = ISO8601DateFormatter().date(from: "2026-09-07T00:00:00Z")!

    private func lesson(_ id: String, _ startMinute: Int, _ endMinute: Int) -> Occurrence {
        let start = base.addingTimeInterval(Double(startMinute) * 60), end = base.addingTimeInterval(Double(endMinute) * 60)
        return Occurrence(id: id, semesterID: UUID(), courseID: UUID(), ruleID: UUID(), originalDate: base, courseName: id,
                          colorIndex: 0, location: "", teacher: "", week: 1, segments: [TeachingSegment(start: start, end: end)])
    }

    @Test func separateLessonsUseFullWidth() {
        let lanes = OccurrenceLayout.lanes(for: [lesson("a", 480, 570), lesson("b", 600, 690)])
        #expect(lanes["a"] == LanePlacement(lane: 0, laneCount: 1))
        #expect(lanes["b"] == LanePlacement(lane: 0, laneCount: 1))
    }

    @Test func touchingLessonsDoNotShareAGroup() {
        let lanes = OccurrenceLayout.lanes(for: [lesson("a", 480, 570), lesson("b", 570, 660)])
        #expect(lanes["a"]?.laneCount == 1)
        #expect(lanes["b"]?.laneCount == 1)
    }

    /// A overlaps B and B overlaps C, but A and C do not: all three share one lane count,
    /// and C reuses A's lane, so no block is drawn over another.
    @Test func chainedOverlapsShareLaneCount() {
        let lanes = OccurrenceLayout.lanes(for: [lesson("c", 600, 690), lesson("a", 480, 570), lesson("b", 540, 630)])
        #expect(lanes["a"] == LanePlacement(lane: 0, laneCount: 2))
        #expect(lanes["b"] == LanePlacement(lane: 1, laneCount: 2))
        #expect(lanes["c"] == LanePlacement(lane: 0, laneCount: 2))
    }

    @Test func identicalSlotsGetDistinctLanes() {
        let lanes = OccurrenceLayout.lanes(for: [lesson("y", 480, 570), lesson("x", 480, 570), lesson("z", 480, 570)])
        #expect(Set(["x", "y", "z"].compactMap { lanes[$0]?.lane }) == [0, 1, 2])
        #expect(["x", "y", "z"].allSatisfy { lanes[$0]?.laneCount == 3 })
        #expect(lanes["x"]?.lane == 0, "Ties are ordered by id so the layout is stable")
    }

    @Test func groupEndsBeforeALaterLesson() {
        let lanes = OccurrenceLayout.lanes(for: [lesson("a", 480, 570), lesson("b", 500, 560), lesson("c", 840, 930)])
        #expect(lanes["a"]?.laneCount == 2)
        #expect(lanes["b"] == LanePlacement(lane: 1, laneCount: 2))
        #expect(lanes["c"] == LanePlacement(lane: 0, laneCount: 1))
    }
}
