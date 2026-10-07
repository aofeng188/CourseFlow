import Foundation
import Testing
@testable import CourseKit

@Suite("后续安排编辑")
struct ScheduleEditingTests {
    private func fixture() -> ScheduleSnapshot {
        let semester = Semester(firstMonday: ISO8601DateFormatter().date(from: "2026-09-07T00:00:00+08:00")!, weekCount: 4)
        let course = Course(semesterID: semester.id, name: "数学")
        let rule = MeetingRule(courseID: course.id, weeks: [1, 2, 3, 4], startMinute: 480, endMinute: 525, location: "A301")
        return ScheduleSnapshot(semesters: [semester], courses: [course], rules: [rule])
    }

    @Test func preservesHistoryAndMovedExceptionDestination() throws {
        var data = fixture(); let semester = data.semesters[0], original = data.rules[0]
        let cancelled = LessonException(ruleID: original.id, originalDate: ScheduleEngine.date(week: 1, weekday: 1, semester: semester), kind: .cancelled)
        let destination = ScheduleEngine.date(week: 3, weekday: 2, semester: semester)
        let moved = LessonException(ruleID: original.id, originalDate: ScheduleEngine.date(week: 3, weekday: 1, semester: semester), kind: .moved, replacementDate: destination, startMinute: 600, endMinute: 645)
        data.exceptions = [cancelled, moved]
        let previousID = ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id).first { $0.week == 2 }!.id
        var future = original; future.id = UUID(); future.weeks = [3, 4]; future.weekday = 3
        let changed = try ScheduleEditing.replacingFuture(ruleID: original.id, startingWeek: 3, with: [future], in: data)
        #expect(changed.rules.first { $0.id == original.id }?.weeks == [1, 2])
        #expect(changed.exceptions.first { $0.id == cancelled.id } == cancelled)
        let revised = changed.exceptions.first { $0.id == moved.id }
        #expect(revised?.ruleID == future.id)
        #expect(revised?.replacementDate == destination)
        #expect(revised?.originalDate == ScheduleEngine.date(week: 3, weekday: 3, semester: semester))
        let events = ScheduleEngine.occurrences(snapshot: changed, semesterID: semester.id)
        #expect(events.first { $0.week == 2 }?.id == previousID)
        #expect(events.contains { $0.ruleID == future.id && semester.calendar.isDate($0.start, inSameDayAs: destination) })
    }

    @Test func preservesHolidayExceptionBasedOnSourceWeek() throws {
        var data = fixture(); let semester = data.semesters[0], original = data.rules[0]
        let target = ScheduleEngine.date(week: 4, weekday: 6, semester: semester)
        let source = ScheduleEngine.date(week: 1, weekday: 1, semester: semester)
        data.dayOverrides = [DayOverride(semesterID: semester.id, date: target, followsDate: source)]
        let cancelled = LessonException(ruleID: original.id, originalDate: target, kind: .cancelled)
        data.exceptions = [cancelled]
        var future = original; future.id = UUID(); future.weeks = [3, 4]; future.weekday = 3
        let changed = try ScheduleEditing.replacingFuture(ruleID: original.id, startingWeek: 3, with: [future], in: data)
        #expect(changed.exceptions.first == cancelled)
        #expect(!ScheduleEngine.occurrences(snapshot: changed, semesterID: semester.id).contains { semester.calendar.isDate($0.start, inSameDayAs: target) })
    }

    @Test func reattachesAddedLessonWithoutChangingItsDate() throws {
        var data = fixture(); let semester = data.semesters[0], original = data.rules[0]
        let addedDate = ScheduleEngine.date(week: 2, weekday: 6, semester: semester)
        let added = LessonException(ruleID: original.id, originalDate: addedDate, kind: .added, startMinute: 600, endMinute: 645)
        data.exceptions = [added]
        var future = original; future.id = UUID(); future.weekday = 4
        let changed = try ScheduleEditing.replacingFuture(ruleID: original.id, startingWeek: 1, with: [future], in: data)
        #expect(!changed.rules.contains { $0.id == original.id })
        #expect(changed.exceptions.first?.ruleID == future.id)
        #expect(changed.exceptions.first?.originalDate == addedDate)
        let event = ScheduleEngine.occurrences(snapshot: changed, semesterID: semester.id).first { $0.id == "added-\(added.id.uuidString.lowercased())" }
        #expect(event != nil)
        #expect(semester.calendar.isDate(event!.start, inSameDayAs: addedDate))
    }

    @Test func rejectsReusedIDsAndEarlierWeeks() {
        let data = fixture(); let original = data.rules[0]
        #expect(throws: (any Error).self) { try ScheduleEditing.replacingFuture(ruleID: original.id, startingWeek: 3, with: [original], in: data) }
        var bad = original; bad.id = UUID(); bad.weeks = [1, 3]
        #expect(throws: (any Error).self) { try ScheduleEditing.replacingFuture(ruleID: original.id, startingWeek: 3, with: [bad], in: data) }
    }

    @Test func editingAllWeekdaysPreservesOneOffDestinationsAndCancellations() throws {
        var data = fixture(); let semester = data.semesters[0], original = data.rules[0]
        let cancelled = LessonException(ruleID: original.id, originalDate: ScheduleEngine.date(week: 2, weekday: 1, semester: semester), kind: .cancelled)
        let destination = ScheduleEngine.date(week: 3, weekday: 5, semester: semester)
        let moved = LessonException(ruleID: original.id, originalDate: ScheduleEngine.date(week: 3, weekday: 1, semester: semester), kind: .moved, replacementDate: destination, startMinute: 600, endMinute: 645, location: "实验楼")
        let added = LessonException(ruleID: original.id, originalDate: ScheduleEngine.date(week: 4, weekday: 6, semester: semester), kind: .added, startMinute: 900, endMinute: 945)
        data.exceptions = [cancelled, moved, added]
        var revised = original; revised.weekday = 2
        let changed = try ScheduleEditing.replacingAllRules(for: data.courses[0], with: [revised], in: data)
        #expect(Set(changed.exceptions.map(\.id)) == Set(data.exceptions.map(\.id)))
        #expect(changed.exceptions.first { $0.id == cancelled.id }?.originalDate == ScheduleEngine.date(week: 2, weekday: 2, semester: semester))
        let revisedMove = changed.exceptions.first { $0.id == moved.id }
        #expect(revisedMove?.originalDate == ScheduleEngine.date(week: 3, weekday: 2, semester: semester))
        #expect(revisedMove?.replacementDate == destination)
        #expect(revisedMove?.startMinute == 600)
        #expect(revisedMove?.location == "实验楼")
        #expect(changed.exceptions.first { $0.id == added.id } == added)
        let events = ScheduleEngine.occurrences(snapshot: changed, semesterID: semester.id)
        #expect(!events.contains { semester.calendar.isDate($0.start, inSameDayAs: ScheduleEngine.date(week: 2, weekday: 2, semester: semester)) })
        #expect(events.contains { semester.calendar.isDate($0.start, inSameDayAs: destination) && $0.location == "实验楼" })
        #expect(events.contains { $0.id == "added-\(added.id.uuidString.lowercased())" })
    }

    @Test func editingAllKeepsHolidayDatesAndDropsOnlyDeletedRuleExceptions() throws {
        var data = fixture(); let semester = data.semesters[0], original = data.rules[0]
        let target = ScheduleEngine.date(week: 4, weekday: 6, semester: semester)
        data.dayOverrides = [DayOverride(semesterID: semester.id, date: target, followsDate: ScheduleEngine.date(week: 1, weekday: 1, semester: semester))]
        let holiday = LessonException(ruleID: original.id, originalDate: target, kind: .cancelled)
        var removedRule = original; removedRule.id = UUID(); removedRule.weekday = 3
        data.rules.append(removedRule)
        let removedException = LessonException(ruleID: removedRule.id, originalDate: ScheduleEngine.date(week: 1, weekday: 3, semester: semester), kind: .cancelled)
        data.exceptions = [holiday, removedException]
        var revised = original; revised.weekday = 2
        let changed = try ScheduleEditing.replacingAllRules(for: data.courses[0], with: [revised], in: data)
        #expect(changed.exceptions == [holiday])
        #expect(changed.rules.map(\.id) == [original.id])
    }
}
