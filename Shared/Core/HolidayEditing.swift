import Foundation

public enum HolidayEditing {
    public enum Choice: String, CaseIterable, Sendable { case followDate, keepSchedule, noClasses }
    public struct Edit: Sendable {
        public var date: Date
        public var choice: Choice
        public var sourceDate: Date?
        public var sourceURL: String
        public init(date: Date, choice: Choice, sourceDate: Date? = nil, sourceURL: String) {
            self.date = date; self.choice = choice; self.sourceDate = sourceDate; self.sourceURL = sourceURL
        }
    }
    /// Confirm unresolved days together. If any edit is invalid or was already arranged, nothing is returned.
    public static func applyingBatch(_ edits: [Edit], semesterID: UUID, to snapshot: ScheduleSnapshot) throws -> ScheduleSnapshot {
        try BackupCodec.validate(snapshot)
        guard let semester = snapshot.semesters.first(where: { $0.id == semesterID }) else { throw BackupError.invalid(["调休安排关联的学期不存在"]) }
        var dates = Set<Date>()
        for edit in edits {
            guard edit.date.timeIntervalSinceReferenceDate.isFinite,
                  (1...semester.weekCount).contains(ScheduleEngine.weekNumber(on: edit.date, semester: semester)) else { throw BackupError.invalid(["调休日期必须属于当前学期"]) }
            let target = semester.calendar.startOfDay(for: edit.date)
            guard dates.insert(target).inserted else { throw BackupError.invalid(["批量确认中同一天不能出现两次"]) }
            guard !HolidayCalendar.hasArrangement(target, semester: semester, snapshot: snapshot) else { throw BackupError.invalid(["部分日期已有学校安排，请重新核对后确认"]) }
            if edit.choice == .followDate {
                guard let source = edit.sourceDate, source.timeIntervalSinceReferenceDate.isFinite,
                      (1...semester.weekCount).contains(ScheduleEngine.weekNumber(on: source, semester: semester)) else { throw BackupError.invalid(["调休参照日期必须属于当前学期"]) }
            }
        }
        var result = snapshot
        for edit in edits {
            result = try applying(edit.choice, date: edit.date, sourceDate: edit.sourceDate, sourceURL: edit.sourceURL, semesterID: semesterID, to: result)
        }
        return result
    }
    public static func applying(_ choice: Choice, date: Date, sourceDate: Date?, sourceURL: String, semesterID: UUID, to snapshot: ScheduleSnapshot) throws -> ScheduleSnapshot {
        guard let semester = snapshot.semesters.first(where: { $0.id == semesterID }),
              (1...semester.weekCount).contains(ScheduleEngine.weekNumber(on: date, semester: semester)) else { throw BackupError.invalid(["调休日期必须属于当前学期"]) }
        let target = semester.calendar.startOfDay(for: date)
        let existingOverride = snapshot.dayOverrides.first { $0.semesterID == semesterID && semester.calendar.isDate($0.date, inSameDayAs: target) }
        let existingDecision = snapshot.holidayDecisions.first { $0.semesterID == semesterID && semester.calendar.isDate($0.date, inSameDayAs: target) }
        var result = snapshot
        result.dayOverrides.removeAll { $0.semesterID == semesterID && semester.calendar.isDate($0.date, inSameDayAs: target) }
        result.holidayDecisions.removeAll { $0.semesterID == semesterID && semester.calendar.isDate($0.date, inSameDayAs: target) }
        if choice == .followDate {
            guard let sourceDate else { throw BackupError.invalid(["请选择参照日期"]) }
            result.dayOverrides.append(.init(id: existingOverride?.id ?? UUID(), semesterID: semesterID, date: target, followsDate: semester.calendar.startOfDay(for: sourceDate), officialSourceURL: sourceURL))
        } else {
            result.holidayDecisions.append(.init(id: existingDecision?.id ?? UUID(), semesterID: semesterID, date: target, kind: choice == .noClasses ? .noClasses : .keepSchedule, sourceURL: sourceURL))
        }
        try BackupCodec.validate(result)
        return result
    }
    public static func resetting(date: Date, semester: Semester, in snapshot: ScheduleSnapshot) -> ScheduleSnapshot {
        var result = snapshot
        result.holidayDecisions.removeAll { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: date) }
        // A manual whole-day override remains the school's confirmed authority.
        result.dayOverrides.removeAll { $0.semesterID == semester.id && $0.officialSourceURL != nil && semester.calendar.isDate($0.date, inSameDayAs: date) }
        return result
    }
}
