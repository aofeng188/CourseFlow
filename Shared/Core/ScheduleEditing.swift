import Foundation

public enum ScheduleEditing {
    /// Replaces a course's regular rules while preserving one-off changes attached to
    /// rules that remain. A weekday edit moves their original occurrence to the same
    /// teaching week; their explicitly chosen destination and stable exception ID stay.
    public static func replacingAllRules(for course: Course, with replacements: [MeetingRule], in snapshot: ScheduleSnapshot) throws -> ScheduleSnapshot {
        guard let semester = snapshot.semesters.first(where: { $0.id == course.semesterID }),
              !replacements.isEmpty, replacements.allSatisfy({ $0.courseID == course.id }),
              Set(replacements.map(\.id)).count == replacements.count else {
            throw BackupError.invalid(["课程必须属于现有学期，并至少包含一条属于该课程的上课安排"])
        }
        var value = snapshot
        let previousRules = value.rules.filter { $0.courseID == course.id }
        let removed = Set(previousRules.map(\.id)).subtracting(replacements.map(\.id))
        value.courses.removeAll { $0.id == course.id }; value.courses.append(course)
        value.rules.removeAll { $0.courseID == course.id }; value.rules += replacements
        value.exceptions.removeAll { removed.contains($0.ruleID) }
        for index in value.exceptions.indices {
            let change = value.exceptions[index]
            guard change.kind != .added,
                  let previous = previousRules.first(where: { $0.id == change.ruleID }),
                  let replacement = replacements.first(where: { $0.id == change.ruleID }),
                  previous.weekday != replacement.weekday,
                  !value.dayOverrides.contains(where: { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: change.originalDate) }) else { continue }
            let week = ScheduleEngine.weekNumber(on: change.originalDate, semester: semester)
            value.exceptions[index].originalDate = ScheduleEngine.date(week: week, weekday: replacement.weekday, semester: semester)
        }
        try BackupCodec.validate(value)
        return value
    }

    /// Replaces the selected rule from a teaching week onward. Earlier rules retain
    /// their IDs, and exceptions are moved by their source teaching week, not the
    /// potentially different holiday make-up date.
    public static func replacingFuture(ruleID: UUID, startingWeek: Int, with replacements: [MeetingRule], in snapshot: ScheduleSnapshot) throws -> ScheduleSnapshot {
        guard let index = snapshot.rules.firstIndex(where: { $0.id == ruleID }),
              let course = snapshot.courses.first(where: { $0.id == snapshot.rules[index].courseID }),
              let semester = snapshot.semesters.first(where: { $0.id == course.semesterID }),
              let primary = replacements.first else { throw BackupError.invalid(["原上课安排不存在，或没有新的上课安排"]) }
        guard (1...semester.weekCount).contains(startingWeek),
              replacements.allSatisfy({ $0.courseID == course.id && !$0.weeks.isEmpty && $0.weeks.allSatisfy { $0 >= startingWeek && $0 <= semester.weekCount } }),
              Set(replacements.map(\.id)).count == replacements.count,
              !replacements.contains(where: { replacement in snapshot.rules.contains { $0.id == replacement.id } }) else {
            throw BackupError.invalid(["后续安排必须使用新的标识、属于同一课程，且不能包含分界周之前的课程"])
        }
        var value = snapshot
        let original = value.rules[index]
        let oldWeeks = original.weeks.filter { $0 < startingWeek }
        if oldWeeks.isEmpty { value.rules.remove(at: index) } else { value.rules[index].weeks = oldWeeks }
        value.rules += replacements
        for index in value.exceptions.indices where value.exceptions[index].ruleID == original.id {
            let change = value.exceptions[index]
            let dayOverride = value.dayOverrides.first { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: change.originalDate) }
            let referenceDate = change.kind == .added ? change.originalDate : (dayOverride?.followsDate ?? change.originalDate)
            let sourceWeek = ScheduleEngine.weekNumber(on: referenceDate, semester: semester)
            if sourceWeek >= startingWeek || oldWeeks.isEmpty {
                value.exceptions[index].ruleID = primary.id
                // Holiday exceptions attach to the actual replacement day; normal
                // exceptions follow the edited weekly rule's new weekday.
                if change.kind != .added && dayOverride == nil {
                    value.exceptions[index].originalDate = ScheduleEngine.date(week: sourceWeek, weekday: primary.weekday, semester: semester)
                }
            }
        }
        try BackupCodec.validate(value)
        return value
    }
}
