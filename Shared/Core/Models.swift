import Foundation

public struct Semester: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var firstMonday: Date
    public var weekCount: Int
    public var timeZoneID: String
    public var calendarOwnerDeviceID: String?
    public var holidayHintsEnabled: Bool?
    public init(id: UUID = UUID(), name: String = "新学期", firstMonday: Date, weekCount: Int = 20, timeZoneID: String = "Asia/Shanghai", calendarOwnerDeviceID: String? = nil, holidayHintsEnabled: Bool? = true) {
        self.id = id; self.name = name; self.firstMonday = firstMonday; self.weekCount = weekCount; self.timeZoneID = timeZoneID; self.calendarOwnerDeviceID = calendarOwnerDeviceID; self.holidayHintsEnabled = holidayHintsEnabled
    }
    public var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        value.firstWeekday = 2
        return value
    }
}

public struct Period: Codable, Hashable, Identifiable, Sendable {
    public var number: Int
    public var startMinute: Int
    public var endMinute: Int
    public var id: Int { number }
    public init(number: Int, startMinute: Int, endMinute: Int) { self.number = number; self.startMinute = startMinute; self.endMinute = endMinute }
    public static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

public struct BellSchedule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var semesterID: UUID
    public var name: String
    public var effectiveFrom: Date
    public var periods: [Period]
    public var isConfirmed: Bool
    public init(id: UUID = UUID(), semesterID: UUID, name: String = "学校作息", effectiveFrom: Date, periods: [Period] = [], isConfirmed: Bool = false) {
        self.id = id; self.semesterID = semesterID; self.name = name; self.effectiveFrom = effectiveFrom; self.periods = periods; self.isConfirmed = isConfirmed
    }
}

public struct Course: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var semesterID: UUID
    public var name: String
    public var colorIndex: Int
    public var notes: String
    /// nil inherits the global lead time; -1 disables reminders.
    public var reminderMinutes: Int?
    public init(id: UUID = UUID(), semesterID: UUID, name: String, colorIndex: Int = 0, notes: String = "", reminderMinutes: Int? = nil) {
        self.id = id; self.semesterID = semesterID; self.name = name; self.colorIndex = colorIndex; self.notes = notes; self.reminderMinutes = reminderMinutes
    }
}

public struct MeetingRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var courseID: UUID
    /// Monday = 1, Sunday = 7.
    public var weekday: Int
    public var weeks: [Int]
    public var periodNumbers: [Int]
    public var startMinute: Int?
    public var endMinute: Int?
    public var location: String
    public var teacher: String
    public init(id: UUID = UUID(), courseID: UUID, weekday: Int = 1, weeks: [Int] = [], periodNumbers: [Int] = [], startMinute: Int? = nil, endMinute: Int? = nil, location: String = "", teacher: String = "") {
        self.id = id; self.courseID = courseID; self.weekday = weekday; self.weeks = weeks; self.periodNumbers = periodNumbers; self.startMinute = startMinute; self.endMinute = endMinute; self.location = location; self.teacher = teacher
    }
}

public enum ExceptionKind: String, Codable, Sendable, CaseIterable { case cancelled, moved, added }
public struct LessonException: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var ruleID: UUID
    public var originalDate: Date
    public var kind: ExceptionKind
    public var replacementDate: Date?
    public var startMinute: Int?
    public var endMinute: Int?
    public var location: String?
    public init(id: UUID = UUID(), ruleID: UUID, originalDate: Date, kind: ExceptionKind, replacementDate: Date? = nil, startMinute: Int? = nil, endMinute: Int? = nil, location: String? = nil) {
        self.id = id; self.ruleID = ruleID; self.originalDate = originalDate; self.kind = kind; self.replacementDate = replacementDate; self.startMinute = startMinute; self.endMinute = endMinute; self.location = location
    }
}

public struct DayOverride: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var semesterID: UUID
    public var date: Date
    public var followsDate: Date
    public var officialSourceURL: String?
    public init(id: UUID = UUID(), semesterID: UUID, date: Date, followsDate: Date, officialSourceURL: String? = nil) { self.id = id; self.semesterID = semesterID; self.date = date; self.followsDate = followsDate; self.officialSourceURL = officialSourceURL }
}

public struct TeachingSegment: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var periodNumber: Int?
    public init(start: Date, end: Date, periodNumber: Int? = nil) { self.start = start; self.end = end; self.periodNumber = periodNumber }
}

public struct Occurrence: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var semesterID: UUID
    public var courseID: UUID
    public var ruleID: UUID
    public var originalDate: Date
    public var courseName: String
    public var colorIndex: Int
    public var location: String
    public var teacher: String
    public var week: Int
    public var segments: [TeachingSegment]
    public var reminderMinutes: Int?
    public var isException: Bool
    public var start: Date { segments.first?.start ?? originalDate }
    public var end: Date { segments.last?.end ?? originalDate }
    public init(id: String, semesterID: UUID, courseID: UUID, ruleID: UUID, originalDate: Date, courseName: String, colorIndex: Int, location: String, teacher: String, week: Int, segments: [TeachingSegment], reminderMinutes: Int? = nil, isException: Bool = false) {
        self.id = id; self.semesterID = semesterID; self.courseID = courseID; self.ruleID = ruleID; self.originalDate = originalDate; self.courseName = courseName; self.colorIndex = colorIndex; self.location = location; self.teacher = teacher; self.week = week; self.segments = segments; self.reminderMinutes = reminderMinutes; self.isException = isException
    }
}

public struct ScheduleSnapshot: Codable, Equatable, Sendable {
    public var semesters: [Semester]
    public var bellSchedules: [BellSchedule]
    public var courses: [Course]
    public var rules: [MeetingRule]
    public var exceptions: [LessonException]
    public var dayOverrides: [DayOverride]
    public var holidayDecisions: [HolidayDecision]
    public init(semesters: [Semester] = [], bellSchedules: [BellSchedule] = [], courses: [Course] = [], rules: [MeetingRule] = [], exceptions: [LessonException] = [], dayOverrides: [DayOverride] = [], holidayDecisions: [HolidayDecision] = []) {
        self.semesters = semesters; self.bellSchedules = bellSchedules; self.courses = courses; self.rules = rules; self.exceptions = exceptions; self.dayOverrides = dayOverrides; self.holidayDecisions = holidayDecisions
    }
    private enum CodingKeys: String, CodingKey { case semesters, bellSchedules, courses, rules, exceptions, dayOverrides, holidayDecisions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        semesters = try c.decode([Semester].self, forKey: .semesters)
        bellSchedules = try c.decode([BellSchedule].self, forKey: .bellSchedules)
        courses = try c.decode([Course].self, forKey: .courses)
        rules = try c.decode([MeetingRule].self, forKey: .rules)
        exceptions = try c.decode([LessonException].self, forKey: .exceptions)
        dayOverrides = try c.decode([DayOverride].self, forKey: .dayOverrides)
        holidayDecisions = try c.decodeIfPresent([HolidayDecision].self, forKey: .holidayDecisions) ?? []
    }
}

public struct DraftLesson: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var weekday: Int?
    public var weeks: [Int]
    public var periods: [Int]
    public var startMinute: Int?
    public var endMinute: Int?
    public var location: String
    public var teacher: String
    public var sourceText: String
    public var sourcePage: Int?
    public var warnings: [String]
    public var selected: Bool
    public init(id: UUID = UUID(), name: String = "", weekday: Int? = nil, weeks: [Int] = [], periods: [Int] = [], startMinute: Int? = nil, endMinute: Int? = nil, location: String = "", teacher: String = "", sourceText: String = "", sourcePage: Int? = nil, warnings: [String] = [], selected: Bool = true) {
        self.id = id; self.name = name; self.weekday = weekday; self.weeks = weeks; self.periods = periods; self.startMinute = startMinute; self.endMinute = endMinute; self.location = location; self.teacher = teacher; self.sourceText = sourceText; self.sourcePage = sourcePage; self.warnings = warnings; self.selected = selected
    }
}

public enum ImportKind: String, Codable, Sendable, CaseIterable { case timetable, bellSchedule }
public struct ImportDraft: Codable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ImportKind
    public var createdAt: Date
    public var sourceName: String
    public var sourceText: String
    public var lessons: [DraftLesson]
    public var periods: [Period]
    public var warnings: [String]
    public init(id: UUID = UUID(), kind: ImportKind = .timetable, createdAt: Date = .now, sourceName: String = "", sourceText: String = "", lessons: [DraftLesson] = [], periods: [Period] = [], warnings: [String] = []) {
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.sourceName = sourceName; self.sourceText = sourceText; self.lessons = lessons; self.periods = periods; self.warnings = warnings
    }
}

public struct WidgetSnapshot: Codable, Sendable {
    public var generatedAt: Date
    public var semester: Semester?
    public var occurrences: [Occurrence]
    public init(generatedAt: Date = .now, semester: Semester?, occurrences: [Occurrence]) { self.generatedAt = generatedAt; self.semester = semester; self.occurrences = occurrences }
}
