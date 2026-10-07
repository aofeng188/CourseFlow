import Foundation
import Testing
@testable import CourseKit

private struct Fixture {
    let semester: Semester
    let course: Course
    let bell: BellSchedule
    let rule: MeetingRule
    init(timeZone: String = "Asia/Shanghai", start: String = "2026-09-07T00:00:00+08:00") {
        semester = Semester(name: "秋季学期", firstMonday: ISO8601DateFormatter().date(from: start)!, weekCount: 4, timeZoneID: timeZone)
        course = Course(semesterID: semester.id, name: "高等数学", colorIndex: 1)
        bell = BellSchedule(semesterID: semester.id, effectiveFrom: semester.firstMonday, periods: [Period(number: 1, startMinute: 480, endMinute: 525), Period(number: 2, startMinute: 535, endMinute: 580)], isConfirmed: true)
        rule = MeetingRule(courseID: course.id, weekday: 1, weeks: [1, 2, 3, 4], periodNumbers: [1, 2], location: "A301")
    }
    var snapshot: ScheduleSnapshot { ScheduleSnapshot(semesters: [semester], bellSchedules: [bell], courses: [course], rules: [rule]) }
    func date(_ week: Int = 1, _ weekday: Int = 1, _ minute: Int = 0) -> Date {
        let day = ScheduleEngine.date(week: week, weekday: weekday, semester: semester)
        return semester.calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)!
    }
    func occurrences(_ snapshot: ScheduleSnapshot? = nil) -> [Occurrence] { ScheduleEngine.occurrences(snapshot: snapshot ?? self.snapshot, semesterID: semester.id) }
}

@Suite("学期时间和实际课次")
struct ScheduleEngineTests {
    @Test func weekBoundariesUseSchoolTimezone() {
        let f = Fixture()
        #expect(ScheduleEngine.weekNumber(on: f.date(), semester: f.semester) == 1)
        #expect(ScheduleEngine.weekNumber(on: f.date().addingTimeInterval(-1), semester: f.semester) == 0)
        #expect(ScheduleEngine.weekNumber(on: f.date(2), semester: f.semester) == 2)
        #expect(ScheduleEngine.weekNumber(on: f.date(1, 7, 1439), semester: f.semester) == 1)
    }

    @Test func respectsWeekMaskAndSegments() {
        let f = Fixture()
        var snapshot = f.snapshot
        snapshot.rules[0].weeks = [1, 3]
        let items = f.occurrences(snapshot)
        #expect(items.map(\.week) == [1, 3])
        #expect(items[0].segments.count == 2)
        #expect(items[0].start == f.date(1, 1, 480))
        #expect(items[0].end == f.date(1, 1, 580))
    }

    @Test func classAndBreakBoundariesAreHalfOpen() {
        let f = Fixture(), items = f.occurrences()
        #expect(ScheduleEngine.status(at: f.date(1, 1, 480), occurrences: items, semester: f.semester).kind == .inClass)
        let rest = ScheduleEngine.status(at: f.date(1, 1, 525), occurrences: items, semester: f.semester)
        #expect(rest.kind == .onBreak)
        #expect(rest.segment == nil)
        #expect(rest.nextSegment?.start == f.date(1, 1, 535))
        #expect(rest.next?.start == f.date(2, 1, 480))
        #expect(ScheduleEngine.status(at: f.date(1, 1, 535), occurrences: items, semester: f.semester).kind == .inClass)
        #expect(ScheduleEngine.status(at: f.date(1, 1, 580), occurrences: items, semester: f.semester).kind == .finishedToday)
    }

    @Test func upcomingAndSemesterStates() {
        let f = Fixture(), items = f.occurrences()
        #expect(ScheduleEngine.status(at: f.date(1, 1, 470), occurrences: items, semester: f.semester).kind == .upcoming)
        #expect(ScheduleEngine.status(at: f.date().addingTimeInterval(-1), occurrences: items, semester: f.semester).kind == .beforeSemester)
        #expect(ScheduleEngine.status(at: f.date(5), occurrences: items, semester: f.semester).kind == .afterSemester)
        #expect(ScheduleEngine.status(at: f.date(), occurrences: [], semester: f.semester).kind == .empty)
        let tomorrow = ScheduleEngine.status(at: f.date(1, 7, 600), occurrences: items, semester: f.semester)
        #expect(tomorrow.kind == .upcoming)
        #expect(tomorrow.next?.start == f.date(2, 1, 480))
    }

    @Test func effectiveBellScheduleUsesTargetDate() {
        let f = Fixture()
        var snapshot = f.snapshot
        snapshot.bellSchedules.append(BellSchedule(semesterID: f.semester.id, name: "冬季", effectiveFrom: f.date(3), periods: [Period(number: 1, startMinute: 510, endMinute: 555), Period(number: 2, startMinute: 565, endMinute: 610)], isConfirmed: true))
        let items = f.occurrences(snapshot)
        #expect(items[1].start == f.date(2, 1, 480))
        #expect(items[2].start == f.date(3, 1, 510))
        #expect(items[0].id == f.occurrences()[0].id)
    }

    @Test func unconfirmedAndMissingPeriodsDoNotGenerateClasses() {
        let f = Fixture()
        var snapshot = f.snapshot
        snapshot.bellSchedules[0].isConfirmed = false
        #expect(f.occurrences(snapshot).isEmpty)
        snapshot.bellSchedules[0].isConfirmed = true
        snapshot.bellSchedules[0].periods.removeLast()
        #expect(f.occurrences(snapshot).isEmpty)
    }

    @Test func moveAndLocationEditsPreserveCalendarIdentity() {
        let f = Fixture(), original = f.occurrences()[0]
        var snapshot = f.snapshot
        snapshot.exceptions = [LessonException(ruleID: f.rule.id, originalDate: f.date(), kind: .moved, replacementDate: f.date(1, 2), startMinute: 840, endMinute: 930, location: "实验楼 B202")]
        let items = f.occurrences(snapshot)
        let moved = items.first { $0.id == original.id }
        #expect(items.count == 4)
        #expect(moved?.start == f.date(1, 2, 840))
        #expect(moved?.location == "实验楼 B202")
        #expect(moved?.originalDate == original.originalDate)
        #expect(moved?.isException == true)
    }

    @Test func cancellationAndAddedClassHaveSeparateIdentities() {
        let f = Fixture()
        var snapshot = f.snapshot
        let added = LessonException(ruleID: f.rule.id, originalDate: f.date(1, 2), kind: .added, startMinute: 600, endMinute: 645)
        snapshot.exceptions = [LessonException(ruleID: f.rule.id, originalDate: f.date(), kind: .cancelled), added]
        let items = f.occurrences(snapshot)
        #expect(items.count == 4)
        #expect(!items.contains { $0.id == f.occurrences()[0].id })
        #expect(items.contains { $0.id == "added-\(added.id.uuidString.lowercased())" })
        snapshot.exceptions[1].replacementDate = f.date(1, 3)
        #expect(f.occurrences(snapshot).contains { $0.id == "added-\(added.id.uuidString.lowercased())" })
    }

    @Test func dayOverrideReplacesTargetAndMatchesSourceWeek() {
        let f = Fixture()
        var snapshot = f.snapshot
        snapshot.rules[0].weeks = [1]
        snapshot.rules.append(MeetingRule(courseID: f.course.id, weekday: 6, weeks: [2], startMinute: 840, endMinute: 885, location: "原周六课程"))
        snapshot.dayOverrides = [DayOverride(semesterID: f.semester.id, date: f.date(2, 6), followsDate: f.date(1, 1))]
        let target = f.occurrences(snapshot).filter { f.semester.calendar.isDate($0.start, inSameDayAs: f.date(2, 6)) }
        #expect(target.count == 1)
        #expect(target.first?.week == 1)
        #expect(target.first?.ruleID == f.rule.id)
        #expect(target.first?.start == f.date(2, 6, 480))
        #expect(target.first?.isException == true)
    }

    @Test func dayOverrideThenTargetCancellation() {
        let f = Fixture()
        var snapshot = f.snapshot
        snapshot.dayOverrides = [DayOverride(semesterID: f.semester.id, date: f.date(1, 6), followsDate: f.date())]
        snapshot.exceptions = [LessonException(ruleID: f.rule.id, originalDate: f.date(1, 6), kind: .cancelled)]
        #expect(f.occurrences(snapshot).count == 4)
    }

    @Test func conflictsIgnoreBreaksAndTouchingBoundaries() {
        let f = Fixture()
        var snapshot = f.snapshot
        snapshot.rules.append(MeetingRule(courseID: f.course.id, weekday: 1, weeks: [1], startMinute: 525, endMinute: 535))
        #expect(ScheduleEngine.conflicts(in: f.occurrences(snapshot)).isEmpty)
        snapshot.rules[1].startMinute = 524
        let conflicts = ScheduleEngine.conflicts(in: f.occurrences(snapshot))
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.overlapEnd == f.date(1, 1, 525))
        let status = ScheduleEngine.status(at: f.date(1, 1, 524), occurrences: f.occurrences(snapshot), semester: f.semester)
        #expect(status.conflicts.count == 1)
    }

    @Test func teachingAnotherCourseDuringBreakTakesPrecedence() {
        let f = Fixture()
        var snapshot = f.snapshot
        let other = MeetingRule(courseID: f.course.id, weekday: 1, weeks: [1], startMinute: 525, endMinute: 535)
        snapshot.rules.append(other)
        let status = ScheduleEngine.status(at: f.date(1, 1, 530), occurrences: f.occurrences(snapshot), semester: f.semester)
        #expect(status.kind == .inClass)
        #expect(status.current?.ruleID == other.id)
        #expect(status.conflicts.isEmpty)
    }

    @Test func calendarArithmeticSurvivesDST() {
        let f = Fixture(timeZone: "America/New_York", start: "2026-03-02T00:00:00-05:00")
        let secondMonday = f.date(2)
        #expect(secondMonday.timeIntervalSince(f.date()) == 7 * 86400 - 3600)
        #expect(ScheduleEngine.weekNumber(on: secondMonday, semester: f.semester) == 2)
        #expect(f.semester.calendar.component(.hour, from: f.occurrences()[1].start) == 8)
    }

    @Test func invalidMoveDoesNotCreatePhantomClass() {
        let f = Fixture()
        var snapshot = f.snapshot
        snapshot.exceptions = [LessonException(ruleID: f.rule.id, originalDate: f.date(1, 2), kind: .moved, replacementDate: f.date(1, 3))]
        #expect(f.occurrences(snapshot).count == 4)
    }
}

@Suite("输入验证与周数解析")
struct ValidationTests {
    @Test func parsesRangesParityChineseAndExclusions() throws {
        #expect(try WeekSelection.parse("第一到八周", maxWeek: 20) == Array(1...8))
        #expect(try WeekSelection.parse("1-16周（单周），排除第7周", maxWeek: 20) == [1, 3, 5, 9, 11, 13, 15])
        #expect(try WeekSelection.parse("双周", maxWeek: 8) == [2, 4, 6, 8])
        #expect(try WeekSelection.parse("１－３，５、７－８", maxWeek: 20) == [1, 2, 3, 5, 7, 8])
        #expect(try WeekSelection.parse("每周", maxWeek: 3) == [1, 2, 3])
        #expect(try WeekSelection.parse("1-8周(双),11,13", maxWeek: 20) == [2, 4, 6, 8, 11, 13])
        #expect(try WeekSelection.parse("十一至十八周", maxWeek: 20) == Array(11...18))
    }

    @Test func rejectsInvalidWeekExpressions() {
        for text in ["", "0-8", "1-21", "8-1", "1-", "1,,2", "一二三周", "1-3排除1-3", "周一上午"] {
            #expect(throws: (any Error).self) { try WeekSelection.parse(text, maxWeek: 20) }
        }
    }

    @Test func summariesRoundTrip() throws {
        for values in [[1], [1, 2, 3, 7, 8], [1, 3, 5, 7], [2, 4, 6], [3, 6, 9]] {
            #expect(try WeekSelection.parse(WeekSelection.summary(values), maxWeek: 20) == values)
        }
    }

    @Test func draftNeedsKnownTimesAcrossEveryWeek() {
        let f = Fixture()
        let lesson = DraftLesson(name: "数学", weekday: 1, weeks: [1, 2], periods: [1, 2])
        #expect(DraftValidator.issues(for: lesson, semester: f.semester, bellSchedules: [f.bell]).isEmpty)
        var lateBell = f.bell
        lateBell.effectiveFrom = f.date(2)
        #expect(!DraftValidator.issues(for: lesson, semester: f.semester, bellSchedules: [lateBell]).isEmpty)
        var winter = f.bell
        winter.id = UUID(); winter.effectiveFrom = f.date(2); winter.periods.removeLast()
        #expect(!DraftValidator.issues(for: lesson, semester: f.semester, bellSchedules: [f.bell, winter]).isEmpty)
    }

    @Test func draftRejectsMixedOrInvalidTimes() {
        let f = Fixture()
        var lesson = DraftLesson(name: "数学", weekday: 1, weeks: [1], periods: [1], startMinute: 600, endMinute: 500)
        #expect(DraftValidator.issues(for: lesson, semester: f.semester, bellSchedules: [f.bell]).count == 2)
        lesson.periods = []; lesson.endMinute = 645
        #expect(DraftValidator.issues(for: lesson, semester: f.semester, bellSchedules: []).isEmpty)
        lesson.weekday = nil; lesson.weeks = []
        #expect(DraftValidator.issues(for: lesson, semester: f.semester, bellSchedules: []).count == 2)
    }
}

@Suite("备份与日历导出")
struct ExportTests {
    @Test func backupRoundTripIncludingRelationships() throws {
        let f = Fixture()
        var snapshot = f.snapshot
        snapshot.exceptions = [LessonException(ruleID: f.rule.id, originalDate: f.date(), kind: .cancelled)]
        snapshot.dayOverrides = [DayOverride(semesterID: f.semester.id, date: f.date(2, 6), followsDate: f.date(1))]
        #expect(try BackupCodec.decode(BackupCodec.encode(snapshot)) == snapshot)
    }

    @Test func backupRejectsFutureVersionsBeforePayloadDecode() {
        let data = Data(#"{"format":"CourseKitBackup","version":99,"snapshot":{}}"#.utf8)
        #expect(throws: BackupError.unsupportedVersion(99)) { try BackupCodec.decode(data) }
    }

    @Test func backupRejectsBrokenReferencesAndDuplicateIDs() {
        let f = Fixture()
        var broken = f.snapshot
        broken.courses = []
        #expect(throws: (any Error).self) { try BackupCodec.encode(broken) }
        broken = f.snapshot; broken.semesters.append(f.semester)
        #expect(throws: (any Error).self) { try BackupCodec.encode(broken) }
        broken = f.snapshot; broken.exceptions = [LessonException(ruleID: UUID(), originalDate: f.date(), kind: .cancelled)]
        #expect(throws: (any Error).self) { try BackupCodec.encode(broken) }
    }

    @Test func backupRejectsInvalidTimeZonesAndDuplicateOverrideDates() {
        let f = Fixture()
        var broken = f.snapshot
        broken.semesters[0].timeZoneID = "Unknown/Invalid"
        #expect(throws: (any Error).self) { try BackupCodec.encode(broken) }
        broken = f.snapshot
        broken.dayOverrides = [DayOverride(semesterID: f.semester.id, date: f.date(1, 6), followsDate: f.date()), DayOverride(semesterID: f.semester.id, date: f.date(1, 6, 600), followsDate: f.date(2))]
        #expect(throws: (any Error).self) { try BackupCodec.encode(broken) }
    }

    @Test func calendarEscapesFoldsAndKeepsStableUIDs() {
        let f = Fixture()
        var item = f.occurrences()[0]
        item.courseName = String(repeating: "高等数学", count: 20) + ",实验;进阶\n补充\\说明"
        item.location = "A301;B楼"
        let text = ICSExporter.export(occurrences: [item, item], semester: f.semester, generatedAt: f.date())
        #expect(text.contains("DTSTART:20260907T000000Z"))
        #expect(text.contains("UID:\(item.id)@coursekit.local"))
        #expect(text.components(separatedBy: "BEGIN:VEVENT").count == 2)
        #expect(text.contains("LOCATION:A301\\;B楼"))
        let unfolded = text.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains("\\,实验\\;进阶\\n补充\\\\说明"))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        #expect(text.hasSuffix("END:VCALENDAR\r\n"))
    }

    @Test func calendarHonorsDisabledReminder() {
        let f = Fixture()
        var item = f.occurrences()[0]; item.reminderMinutes = -1
        #expect(!ICSExporter.export(occurrences: [item], semester: f.semester).contains("BEGIN:VALARM"))
    }

    @Test func exampleIsAValidRestorableSnapshot() throws {
        let snapshot = SampleData.make(now: ISO8601DateFormatter().date(from: "2026-09-10T10:00:00+08:00")!)
        #expect(try BackupCodec.decode(BackupCodec.encode(snapshot)) == snapshot)
        #expect(ScheduleEngine.weekNumber(on: ISO8601DateFormatter().date(from: "2026-09-10T10:00:00+08:00")!, semester: snapshot.semesters[0]) == 4)
        #expect(!ScheduleEngine.occurrences(snapshot: snapshot, semesterID: snapshot.semesters[0].id).isEmpty)
    }
}
