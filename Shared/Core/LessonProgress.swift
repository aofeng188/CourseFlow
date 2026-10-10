import Foundation

/// How far a lesson has run across all of its teaching segments. Breaks between segments
/// take no share: the bar holds still while the class rests.
public struct LessonProgress: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public var periodNumber: Int?
        /// This segment's share of the lesson's total teaching time.
        public var weight: Double
        /// The completed share of this segment, 0...1.
        public var fraction: Double
        public init(periodNumber: Int? = nil, weight: Double, fraction: Double) { self.periodNumber = periodNumber; self.weight = weight; self.fraction = fraction }
    }
    public var parts: [Part]
    /// 1-based position of the segment being taught, or of the next one during a break.
    public var position: Int
    /// The completed share of all teaching time, 0...1.
    public var overall: Double
    /// When the last segment ends.
    public var end: Date
    public init(parts: [Part], position: Int, overall: Double, end: Date) { self.parts = parts; self.position = position; self.overall = overall; self.end = end }
}

extension Occurrence {
    /// nil when the lesson has no segment with a positive duration.
    public func progress(at now: Date) -> LessonProgress? {
        let teaching = segments.filter { $0.end > $0.start }
        let total = teaching.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard let last = teaching.last, total > 0 else { return nil }
        let parts = teaching.map { segment in
            let duration = segment.end.timeIntervalSince(segment.start)
            return LessonProgress.Part(periodNumber: segment.periodNumber, weight: duration / total, fraction: min(1, max(0, now.timeIntervalSince(segment.start) / duration)))
        }
        let position = (parts.firstIndex { $0.fraction < 1 } ?? parts.count - 1) + 1
        return LessonProgress(parts: parts, position: position, overall: parts.reduce(0) { $0 + $1.weight * $1.fraction }, end: last.end)
    }
}
