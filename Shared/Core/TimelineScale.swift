import Foundation

/// Vertical layout for the week grid. Every class period gets the same height, short breaks
/// shrink to a thin gap, and long breaks such as lunch and dinner become a narrow band, so a
/// whole school day fits on screen instead of mostly showing empty break time.
///
/// Time outside the bell schedule, and any break that a lesson starts or ends in, stays
/// proportional so lessons on custom times are never squashed.
public struct TimelineScale: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A bell-schedule period, by number.
        case period(Int)
        /// An hour slot, used when the day has no bell schedule.
        case hour
        /// A short break between periods.
        case gap
        /// A break of at least `Metrics.longBreakMinutes`, such as lunch.
        case longBreak
        /// Proportional time outside the schedule, or a break that a lesson starts or ends in.
        case open
    }

    public struct Segment: Equatable, Sendable {
        public var startMinute: Int
        public var endMinute: Int
        public var y: Double
        public var height: Double
        public var kind: Kind
        public var maxY: Double { y + height }
    }

    public struct Metrics: Equatable, Sendable {
        public var periodHeight: Double
        public var gapHeight: Double
        public var longBreakHeight: Double
        public var longBreakMinutes: Int
        public init(periodHeight: Double = 52, gapHeight: Double = 4, longBreakHeight: Double = 22, longBreakMinutes: Int = 30) {
            self.periodHeight = periodHeight; self.gapHeight = gapHeight; self.longBreakHeight = longBreakHeight; self.longBreakMinutes = longBreakMinutes
        }
    }

    public let segments: [Segment]
    public var height: Double { segments.last?.maxY ?? 0 }
    public var startMinute: Int { segments.first?.startMinute ?? 0 }
    public var endMinute: Int { segments.last?.endMinute ?? 0 }

    /// - Parameters:
    ///   - periods: The day's bell schedule; may be empty or unordered.
    ///   - lessons: Minute-of-day ranges of the lessons to show.
    public init(periods: [Period], lessons: [Range<Int>], metrics: Metrics = Metrics()) {
        let lessons = lessons.filter { !$0.isEmpty }
        let valid = periods.filter { $0.endMinute > $0.startMinute }.sorted { ($0.startMinute, $0.number) < ($1.startMinute, $1.number) }
        var slots: [(start: Int, end: Int, kind: Kind)] = []
        let earliest = lessons.map(\.lowerBound).min(), latest = lessons.map(\.upperBound).max()

        if valid.isEmpty {
            // Hour rows from 08:00 to 18:00, widened to fit every lesson.
            let low = min(480, earliest ?? 480) / 60 * 60
            let high = min(1440, (max(1080, latest ?? 1080) + 59) / 60 * 60)
            slots = stride(from: low, to: high, by: 60).map { ($0, $0 + 60, Kind.hour) }
        } else {
            var cursor: Int?
            for period in valid {
                var start = period.startMinute
                if let cursor {
                    start = max(start, cursor)
                    guard period.endMinute > start else { continue }
                    if start > cursor { slots.append((cursor, start, Self.breakKind(cursor..<start, lessons: lessons, metrics: metrics))) }
                }
                slots.append((start, period.endMinute, .period(period.number)))
                cursor = period.endMinute
            }
            if let earliest, let first = slots.first, earliest < first.start { slots.insert((earliest, first.start, .open), at: 0) }
            if let latest, let last = slots.last, latest > last.end { slots.append((last.end, latest, .open)) }
        }

        let durations = valid.map { $0.endMinute - $0.startMinute }.sorted()
        let typical = durations.isEmpty ? 60 : durations[durations.count / 2]
        let perMinute = metrics.periodHeight / Double(max(1, typical))
        var y = 0.0
        segments = slots.map { slot in
            let height: Double
            switch slot.kind {
            case .period, .hour: height = metrics.periodHeight
            case .gap: height = metrics.gapHeight
            case .longBreak: height = metrics.longBreakHeight
            case .open: height = Double(slot.end - slot.start) * perMinute
            }
            defer { y += height }
            return Segment(startMinute: slot.start, endMinute: slot.end, y: y, height: height, kind: slot.kind)
        }
    }

    /// A lesson that starts or ends inside a break needs real space there.
    private static func breakKind(_ range: Range<Int>, lessons: [Range<Int>], metrics: Metrics) -> Kind {
        let interior = range.lowerBound + 1..<range.upperBound
        if lessons.contains(where: { interior.contains($0.lowerBound) || interior.contains($0.upperBound) }) { return .open }
        return range.count >= metrics.longBreakMinutes ? .longBreak : .gap
    }

    /// The vertical offset of a minute of the day, clamped to the scale's range.
    public func y(at minute: Int) -> Double {
        guard let first = segments.first, minute > first.startMinute else { return 0 }
        for segment in segments where minute < segment.endMinute {
            return segment.y + segment.height * Double(minute - segment.startMinute) / Double(segment.endMinute - segment.startMinute)
        }
        return height
    }

    public func segment(containing minute: Int) -> Segment? {
        segments.first { $0.startMinute <= minute && minute < $0.endMinute }
    }
}
