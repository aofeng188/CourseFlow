import Foundation

public struct CurrentStatus: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case inClass, onBreak, upcoming, finishedToday, beforeSemester, afterSemester, empty
    }
    public var kind: Kind
    public var current: Occurrence?
    public var next: Occurrence?
    public var segment: TeachingSegment?
    public var nextSegment: TeachingSegment?
    /// Other courses teaching at the same instant as the selected current course.
    public var conflicts: [Occurrence]
    public init(kind: Kind, current: Occurrence? = nil, next: Occurrence? = nil, segment: TeachingSegment? = nil, nextSegment: TeachingSegment? = nil, conflicts: [Occurrence] = []) {
        self.kind = kind; self.current = current; self.next = next; self.segment = segment
        self.nextSegment = nextSegment; self.conflicts = conflicts
    }
}

public struct ScheduleConflict: Equatable, Identifiable, Sendable {
    public var firstID: String
    public var secondID: String
    public var overlapStart: Date
    public var overlapEnd: Date
    public var id: String { [firstID, secondID].sorted().joined(separator: "|") }
    public init(firstID: String, secondID: String, overlapStart: Date, overlapEnd: Date) {
        self.firstID = firstID; self.secondID = secondID
        self.overlapStart = overlapStart; self.overlapEnd = overlapEnd
    }
}

public enum ScheduleEngine {
    public static func weekNumber(on date: Date, semester: Semester) -> Int {
        let calendar = semester.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: semester.firstMonday), to: calendar.startOfDay(for: date)).day ?? 0
        return Int(floor(Double(days) / 7)) + 1
    }

    public static func date(week: Int, weekday: Int, semester: Semester) -> Date {
        semester.calendar.date(byAdding: .day, value: (week - 1) * 7 + weekday - 1, to: semester.calendar.startOfDay(for: semester.firstMonday)) ?? semester.firstMonday
    }

    public static func bellSchedule(on date: Date, semester: Semester, schedules: [BellSchedule]) -> BellSchedule? {
        let day = semester.calendar.startOfDay(for: date)
        return schedules.filter {
            $0.semesterID == semester.id && $0.isConfirmed && semester.calendar.startOfDay(for: $0.effectiveFrom) <= day
        }.sorted {
            if $0.effectiveFrom != $1.effectiveFrom { return $0.effectiveFrom > $1.effectiveFrom }
            return $0.id.uuidString < $1.id.uuidString
        }.first
    }

    public static func occurrences(snapshot: ScheduleSnapshot, semesterID: UUID) -> [Occurrence] {
        guard let semester = snapshot.semesters.first(where: { $0.id == semesterID }),
              (1...60).contains(semester.weekCount) else { return [] }
        let calendar = semester.calendar
        var courses: [UUID: Course] = [:]
        for course in snapshot.courses where course.semesterID == semesterID { courses[course.id] = course }
        let rules = snapshot.rules.filter { courses[$0.courseID] != nil }
        var daySources: [Date: Date] = [:]
        for offset in 0..<(semester.weekCount * 7) {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: semester.firstMonday))!
            daySources[day] = day
        }
        // The target day replaces its usual pattern. The source is interpreted directly,
        // not recursively, so a school's two-way holiday swap cannot create a cycle.
        for change in snapshot.dayOverrides.filter({ $0.semesterID == semesterID }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            daySources[calendar.startOfDay(for: change.date)] = calendar.startOfDay(for: change.followsDate)
        }
        var result: [String: Occurrence] = [:]
        for (day, source) in daySources {
            let week = weekNumber(on: source, semester: semester)
            let weekday = (calendar.component(.weekday, from: source) + 5) % 7 + 1
            for rule in rules where rule.weekday == weekday && rule.weeks.contains(week) {
                guard let course = courses[rule.courseID],
                      let occurrence = makeOccurrence(rule: rule, course: course, originalDay: day, actualDay: day, week: week, semester: semester, schedules: snapshot.bellSchedules, isException: source != day) else { continue }
                result[occurrence.id] = occurrence
            }
        }
        var rulesByID: [UUID: MeetingRule] = [:]
        for rule in rules { rulesByID[rule.id] = rule }
        for change in snapshot.exceptions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let rule = rulesByID[change.ruleID], let course = courses[rule.courseID] else { continue }
            let originalDay = calendar.startOfDay(for: change.originalDate)
            let originalID = occurrenceID(ruleID: rule.id, day: originalDay, semester: semester)
            if change.kind == .cancelled {
                result.removeValue(forKey: originalID)
                continue
            }
            let previous = result[originalID]
            // A move cannot create a class where no original class existed. Added classes
            // deliberately ignore the rule's weekday/week mask and have their own identity.
            guard change.kind == .added || previous != nil else { continue }
            let actualDay = calendar.startOfDay(for: change.replacementDate ?? originalDay)
            let week = previous?.week ?? weekNumber(on: actualDay, semester: semester)
            let id = change.kind == .added ? "added-\(change.id.uuidString.lowercased())" : originalID
            guard let changed = makeOccurrence(rule: rule, course: course, originalDay: originalDay, actualDay: actualDay, week: week, semester: semester, schedules: snapshot.bellSchedules, id: id, startMinute: change.startMinute, endMinute: change.endMinute, location: change.location, isException: true) else { continue }
            if change.kind == .moved { result.removeValue(forKey: originalID) }
            result[changed.id] = changed
        }
        let closedDays = Set(snapshot.holidayDecisions.filter { $0.semesterID == semesterID && $0.kind == .noClasses }.map { calendar.startOfDay(for: $0.date) })
        let overriddenDays = Set(snapshot.dayOverrides.filter { $0.semesterID == semesterID }.map { calendar.startOfDay(for: $0.date) })
        let explicitIDs = Set(snapshot.exceptions.filter { $0.kind == .added || $0.kind == .moved }.map { change in
            change.kind == .added ? "added-\(change.id.uuidString.lowercased())" : occurrenceID(ruleID: change.ruleID, day: calendar.startOfDay(for: change.originalDate), semester: semester)
        })
        return result.values.filter { event in
            let day = calendar.startOfDay(for: event.start)
            return !closedDays.contains(day) || overriddenDays.contains(day) || explicitIDs.contains(event.id)
        }.sorted(by: occurrenceOrder)
    }

    public static func status(at now: Date, occurrences: [Occurrence], semester: Semester?) -> CurrentStatus {
        let items = occurrences.filter { !$0.segments.isEmpty && (semester == nil || $0.semesterID == semester?.id) }.sorted(by: occurrenceOrder)
        guard !items.isEmpty else { return CurrentStatus(kind: .empty) }
        let teaching = items.filter { occurrence in occurrence.segments.contains { $0.start <= now && now < $0.end } }
        let spans = items.filter { $0.start <= now && now < $0.end }
        let current = teaching.first ?? spans.first
        let next = items.first { $0.start > now && $0.id != current?.id }
        if let current {
            let segment = current.segments.first { $0.start <= now && now < $0.end }
            let nextSegment = current.segments.first { $0.start > now } ?? next?.segments.first
            return CurrentStatus(kind: segment == nil ? .onBreak : .inClass, current: current, next: next, segment: segment, nextSegment: nextSegment, conflicts: teaching.filter { $0.id != current.id })
        }
        if let semester {
            let start = semester.calendar.startOfDay(for: semester.firstMonday)
            let end = date(week: semester.weekCount + 1, weekday: 1, semester: semester)
            if now < start { return CurrentStatus(kind: .beforeSemester, next: next, nextSegment: next?.segments.first) }
            if now >= end && next == nil { return CurrentStatus(kind: .afterSemester) }
            let hadClassToday = items.contains { semester.calendar.isDate($0.start, inSameDayAs: now) && $0.end <= now }
            let nextIsToday = next.map { semester.calendar.isDate($0.start, inSameDayAs: now) } ?? false
            if hadClassToday && !nextIsToday { return CurrentStatus(kind: .finishedToday, next: next, nextSegment: next?.segments.first) }
        }
        return CurrentStatus(kind: next == nil ? .finishedToday : .upcoming, next: next, nextSegment: next?.segments.first)
    }

    public static func conflicts(in occurrences: [Occurrence]) -> [ScheduleConflict] {
        let items = occurrences.sorted(by: occurrenceOrder)
        var result: [ScheduleConflict] = []
        for (index, first) in items.enumerated() {
            for second in items.dropFirst(index + 1) {
                if second.start >= first.end { break }
                guard first.id != second.id else { continue }
                var overlap: (Date, Date)?
                for a in first.segments {
                    for b in second.segments {
                        let start = max(a.start, b.start), end = min(a.end, b.end)
                        if start < end, overlap == nil || start < overlap!.0 { overlap = (start, end) }
                    }
                }
                if let overlap { result.append(ScheduleConflict(firstID: first.id, secondID: second.id, overlapStart: overlap.0, overlapEnd: overlap.1)) }
            }
        }
        return result
    }

    private static func occurrenceOrder(_ a: Occurrence, _ b: Occurrence) -> Bool {
        a.start == b.start ? a.id < b.id : a.start < b.start
    }

    private static func occurrenceID(ruleID: UUID, day: Date, semester: Semester) -> String {
        let parts = semester.calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%@-%04d%02d%02d", ruleID.uuidString.lowercased(), parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func makeOccurrence(rule: MeetingRule, course: Course, originalDay: Date, actualDay: Date, week: Int, semester: Semester, schedules: [BellSchedule], id: String? = nil, startMinute: Int? = nil, endMinute: Int? = nil, location: String? = nil, isException: Bool) -> Occurrence? {
        let calendar = semester.calendar
        func instant(_ minute: Int) -> Date? {
            guard (0...1440).contains(minute) else { return nil }
            if minute == 1440 { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: actualDay)) }
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: actualDay)
        }
        var segments: [TeachingSegment] = []
        let explicitStart = startMinute ?? rule.startMinute
        let explicitEnd = endMinute ?? rule.endMinute
        if let start = explicitStart, let end = explicitEnd, start < end,
           let begin = instant(start), let finish = instant(end), begin < finish {
            segments = [TeachingSegment(start: begin, end: finish)]
        } else {
            guard explicitStart == nil && explicitEnd == nil,
                  !rule.periodNumbers.isEmpty,
                  let schedule = bellSchedule(on: actualDay, semester: semester, schedules: schedules) else { return nil }
            for number in Set(rule.periodNumbers).sorted() {
                guard let period = schedule.periods.first(where: { $0.number == number }),
                      period.startMinute < period.endMinute,
                      let begin = instant(period.startMinute), let finish = instant(period.endMinute), begin < finish else { return nil }
                segments.append(TeachingSegment(start: begin, end: finish, periodNumber: number))
            }
            segments.sort { $0.start < $1.start }
            for pair in zip(segments, segments.dropFirst()) where pair.0.end > pair.1.start { return nil }
        }
        return Occurrence(id: id ?? occurrenceID(ruleID: rule.id, day: originalDay, semester: semester), semesterID: semester.id, courseID: course.id, ruleID: rule.id, originalDate: originalDay, courseName: course.name, colorIndex: course.colorIndex, location: location ?? rule.location, teacher: rule.teacher, week: week, segments: segments, reminderMinutes: course.reminderMinutes, isException: isException)
    }
}
