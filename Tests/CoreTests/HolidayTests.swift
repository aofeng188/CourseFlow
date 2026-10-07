import Foundation
import Testing
@testable import CourseKit

@Suite("官方调休与确认") struct HolidayTests {
    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func fixture() -> ScheduleSnapshot {
        let semester = Semester(firstMonday: instant("2026-09-14T00:00:00+08:00"), weekCount: 10)
        let course = Course(semesterID: semester.id, name: "单双周课程")
        return .init(semesters: [semester], courses: [course], rules: [MeetingRule(courseID: course.id, weekday: 1, weeks: [1,3,5,7,9], startMinute: 480, endMinute: 525)])
    }
    private func html() throws -> String { try String(contentsOf: Bundle.module.url(forResource: "official-2026", withExtension: "html", subdirectory: "Fixtures")!, encoding: .utf8) }
    private var nationalDay: OfficialHolidayGroup { OfficialHolidayYear.seed2026.groups.first { $0.name == "国庆节" }! }
    @Test func officialNoticeMatchesBundledDays() throws {
        let notice = try OfficialHolidayParser.parse(html: html(), year: 2026, sourceURL: OfficialHolidayYear.seed2026.sourceURL)
        #expect(notice.days == OfficialHolidayYear.seed2026.days)
        #expect(notice.days.filter { $0.kind == .makeup }.count == 6)
    }
    @Test func refusesWrongWeekdayCountYearAndUnofficialSource() throws {
        let text = try html()
        for malformed in [text.replacingOccurrences(of: "周四", with: "周三"), text.replacingOccurrences(of: "共9天", with: "共8天"), text.replacingOccurrences(of: "2026年", with: "2027年"), text.replacingOccurrences(of: "四、劳动节", with: "四、未知节")] {
            #expect(throws: (any Error).self) { try OfficialHolidayParser.parse(html: malformed, year: 2026, sourceURL: OfficialHolidayYear.seed2026.sourceURL) }
        }
        #expect(throws: (any Error).self) { try OfficialHolidayParser.parse(html: text, year: 2026, sourceURL: "https://example.com/notice") }
    }
    @Test func promptsSevenDaysBeforeAndThroughDayOnly() {
        let data = fixture(); let semester = data.semesters[0]
        let day = OfficialHolidayYear.seed2026.days.first { $0.dateKey == "2026-10-10" }!
        #expect(!HolidayCalendar.shouldPrompt(day, now: instant("2026-10-02T23:59:59+08:00"), semester: semester, snapshot: data))
        #expect(HolidayCalendar.shouldPrompt(day, now: instant("2026-10-03T00:00:00+08:00"), semester: semester, snapshot: data))
        #expect(HolidayCalendar.shouldPrompt(day, now: instant("2026-10-10T23:59:59+08:00"), semester: semester, snapshot: data))
        #expect(!HolidayCalendar.shouldPrompt(day, now: instant("2026-10-11T00:00:00+08:00"), semester: semester, snapshot: data))
    }
    @Test func pendingDoesNotChangeOriginalScheduleAndManualOverrideResolvesIt() {
        var data = fixture(); let semester = data.semesters[0]
        let day = OfficialHolidayYear.seed2026.days.first { $0.dateKey == "2026-10-10" }!
        let before = ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id)
        #expect(HolidayCalendar.isPending(day, semester: semester, snapshot: data))
        #expect(before.count == 5)
        data.dayOverrides = [.init(semesterID: semester.id, date: day.date(in: semester)!, followsDate: semester.firstMonday)]
        #expect(!HolidayCalendar.isPending(day, semester: semester, snapshot: data))
        var disabled = semester; disabled.holidayHintsEnabled = false
        #expect(!HolidayCalendar.isPending(day, semester: disabled, snapshot: fixture()))
    }
    @Test func followsSourceTeachingWeekRatherThanTargetWeek() throws {
        let data = fixture(); let semester = data.semesters[0]; let target = instant("2026-10-10T00:00:00+08:00")
        let odd = try HolidayEditing.applying(.followDate, date: target, sourceDate: semester.firstMonday, sourceURL: "official", semesterID: semester.id, to: data)
        let even = try HolidayEditing.applying(.followDate, date: target, sourceDate: ScheduleEngine.date(week: 2, weekday: 1, semester: semester), sourceURL: "official", semesterID: semester.id, to: data)
        #expect(ScheduleEngine.occurrences(snapshot: odd, semesterID: semester.id).filter { semester.calendar.isDate($0.start, inSameDayAs: target) }.count == 1)
        #expect(ScheduleEngine.occurrences(snapshot: even, semesterID: semester.id).filter { semester.calendar.isDate($0.start, inSameDayAs: target) }.isEmpty)
        #expect(ScheduleEngine.occurrences(snapshot: odd, semesterID: semester.id).contains { $0.start == ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id)[0].start })
    }
    @Test func closingKeepsExplicitAddedAndMovedLessons() throws {
        var data = fixture(); let semester = data.semesters[0]; let rule = data.rules[0]
        data.exceptions = [
            .init(ruleID: rule.id, originalDate: semester.firstMonday, kind: .added, startMinute: 600, endMinute: 645),
            .init(ruleID: rule.id, originalDate: ScheduleEngine.date(week: 3, weekday: 1, semester: semester), kind: .moved, replacementDate: semester.firstMonday, startMinute: 840, endMinute: 885)
        ]
        let closed = try HolidayEditing.applying(.noClasses, date: semester.firstMonday, sourceDate: nil, sourceURL: "official", semesterID: semester.id, to: data)
        let events = ScheduleEngine.occurrences(snapshot: closed, semesterID: semester.id).filter { semester.calendar.isDate($0.start, inSameDayAs: semester.firstMonday) }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.isException })
        #expect(events.allSatisfy { $0.start > semester.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: semester.firstMonday)! })
    }
    @Test func closingSourceDayStillAllowsExplicitMoveOut() throws {
        var data = fixture(); let semester = data.semesters[0]
        let target = ScheduleEngine.date(week: 1, weekday: 2, semester: semester)
        data.exceptions = [.init(ruleID: data.rules[0].id, originalDate: semester.firstMonday, kind: .moved, replacementDate: target)]
        data = try HolidayEditing.applying(.noClasses, date: semester.firstMonday, sourceDate: nil, sourceURL: "official", semesterID: semester.id, to: data)
        #expect(ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id).contains { semester.calendar.isDate($0.start, inSameDayAs: target) })
    }
    @Test func confirmationIsIdempotentAndResetRetainsManualOverrides() throws {
        let data = fixture(); let semester = data.semesters[0]; let date = semester.firstMonday
        let first = try HolidayEditing.applying(.keepSchedule, date: date, sourceDate: nil, sourceURL: "official", semesterID: semester.id, to: data)
        let second = try HolidayEditing.applying(.keepSchedule, date: date, sourceDate: nil, sourceURL: "official", semesterID: semester.id, to: first)
        #expect(first == second)
        #expect(HolidayEditing.resetting(date: date, semester: semester, in: first).holidayDecisions.isEmpty)
        var manual = data; manual.dayOverrides = [.init(semesterID: semester.id, date: date, followsDate: date)]
        #expect(HolidayEditing.resetting(date: date, semester: semester, in: manual).dayOverrides == manual.dayOverrides)
    }
    @Test func v1ReadsAndV2PreservesDecisions() throws {
        let data = fixture(); let semester = data.semesters[0]
        var old = try #require(JSONSerialization.jsonObject(with: BackupCodec.encode(data)) as? [String: Any])
        old["version"] = 1
        var snapshot = old["snapshot"] as! [String: Any]; snapshot.removeValue(forKey: "holidayDecisions")
        var semesters = snapshot["semesters"] as! [[String: Any]]; semesters[0].removeValue(forKey: "holidayHintsEnabled"); snapshot["semesters"] = semesters
        old["snapshot"] = snapshot
        let restored = try BackupCodec.decode(JSONSerialization.data(withJSONObject: old))
        #expect(restored.holidayDecisions.isEmpty)
        #expect(restored.semesters[0].holidayHintsEnabled == nil)
        let closed = try HolidayEditing.applying(.noClasses, date: semester.firstMonday, sourceDate: nil, sourceURL: "official", semesterID: semester.id, to: restored)
        #expect(try BackupCodec.decode(BackupCodec.encode(closed)) == closed)
        #expect(BackupCodec.currentVersion == 2)
    }
    @Test func rejectsInvalidDecisionDatesAndDuplicateDates() throws {
        var data = fixture(); let semester = data.semesters[0]
        data.holidayDecisions = [.init(semesterID: semester.id, date: .distantPast, kind: .noClasses, sourceURL: "official")]
        #expect(throws: (any Error).self) { try BackupCodec.validate(data) }
        data.holidayDecisions = [.init(semesterID: semester.id, date: semester.firstMonday, kind: .noClasses, sourceURL: "official"), .init(semesterID: semester.id, date: semester.firstMonday, kind: .keepSchedule, sourceURL: "official")]
        #expect(throws: (any Error).self) { try BackupCodec.validate(data) }
    }
    @Test func dayKeysFollowSchoolZoneAcrossMidnight() {
        let data = fixture(); let semester = data.semesters[0]
        #expect(HolidayCalendar.key(instant("2026-10-09T16:00:00Z"), calendar: semester.calendar) == "2026-10-10")
        #expect(HolidayCalendar.date("2026-02-30", calendar: semester.calendar) == nil)
    }
    @Test func festivalGroupingIncludesDistantMakeupDatesAndKeepsMidautumnSeparate() {
        let groups = OfficialHolidayYear.seed2026.groups
        #expect(groups.count == 7)
        #expect(nationalDay.id == "2026-国庆节")
        #expect(nationalDay.days.count == 9)
        #expect(nationalDay.days.first?.dateKey == "2026-09-20")
        #expect(nationalDay.days.last?.dateKey == "2026-10-10")
        #expect(groups.first { $0.name == "中秋节" }?.days.map(\.dateKey) == ["2026-09-25", "2026-09-26", "2026-09-27"])
        let anotherYear = OfficialHolidayYear(year: 2027, title: "2027", sourceURL: "official", days: [.init(dateKey: "2027-10-01", name: "国庆节", kind: .holiday)])
        #expect(anotherYear.groups[0].id != nationalDay.id)
        #expect(anotherYear.groups[0].days.count == 1)
    }
    @Test func festivalPromptStartsBeforeEarliestMakeupAndIncludesWholeFestival() {
        let data = fixture(); let semester = data.semesters[0]
        #expect(!HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-09-12T23:59:59+08:00"), semester: semester, snapshot: data))
        #expect(HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-09-13T00:00:00+08:00"), semester: semester, snapshot: data))
        #expect(HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-10-02T08:00:00+08:00"), semester: semester, snapshot: data))
        #expect(nationalDay.days(in: semester).contains { $0.dateKey == "2026-10-10" })
        #expect(!HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-10-11T00:00:00+08:00"), semester: semester, snapshot: data))
    }
    @Test func partialConfirmationKeepsFestivalWindowStable() throws {
        let data = fixture(); let semester = data.semesters[0]
        let edits = nationalDay.days.filter { $0.kind == .holiday }.map { HolidayEditing.Edit(date: $0.date(in: semester)!, choice: .noClasses, sourceURL: "official") }
        let confirmed = try HolidayEditing.applyingBatch(edits, semesterID: semester.id, to: data)
        #expect(confirmed.holidayDecisions.count == 7)
        // Its remaining future makeup date is more than seven days away; the festival stays visible.
        #expect(HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-10-02T08:00:00+08:00"), semester: semester, snapshot: confirmed))
        let resolved = try HolidayEditing.applyingBatch([.init(date: instant("2026-10-10T00:00:00+08:00"), choice: .keepSchedule, sourceURL: "official")], semesterID: semester.id, to: confirmed)
        // An unresolved past makeup date does not keep a homepage prompt alive.
        #expect(!HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-10-02T08:00:00+08:00"), semester: semester, snapshot: resolved))
    }
    @Test func semesterFilteringDoesNotMoveFestivalPromptAnchor() {
        let data = fixture()
        let semester = Semester(firstMonday: instant("2026-10-05T00:00:00+08:00"), weekCount: 2)
        let term = ScheduleSnapshot(semesters: [semester])
        #expect(nationalDay.days(in: semester).map(\.dateKey) == ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-10"])
        #expect(HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-09-13T00:00:00+08:00"), semester: semester, snapshot: term))
        let after = Semester(firstMonday: instant("2026-10-12T00:00:00+08:00"), weekCount: 2)
        #expect(nationalDay.days(in: after).isEmpty)
        #expect(!HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-10-02T00:00:00+08:00"), semester: after, snapshot: data))
    }
    @Test func disabledHintsDoNotHideExistingArrangementFromBatchProtection() throws {
        var data = fixture(); var semester = data.semesters[0]
        semester.holidayHintsEnabled = false; data.semesters[0] = semester
        let date = instant("2026-10-10T00:00:00+08:00")
        data.dayOverrides = [.init(semesterID: semester.id, date: date, followsDate: semester.firstMonday)]
        #expect(HolidayCalendar.hasArrangement(date, semester: semester, snapshot: data))
        #expect(!HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-10-02T00:00:00+08:00"), semester: semester, snapshot: data))
        #expect(throws: (any Error).self) { try HolidayEditing.applyingBatch([.init(date: date, choice: .noClasses, sourceURL: "official")], semesterID: semester.id, to: data) }
    }
    @Test func batchCombinesClosuresAndTeachingDateMappingAndRoundTripsBackup() throws {
        let data = fixture(); let semester = data.semesters[0]
        let target = instant("2026-10-10T00:00:00+08:00")
        var edits = nationalDay.days.filter { $0.kind == .holiday }.map { HolidayEditing.Edit(date: $0.date(in: semester)!, choice: .noClasses, sourceURL: "official") }
        edits.append(.init(date: target, choice: .followDate, sourceDate: semester.firstMonday, sourceURL: "official"))
        let result = try HolidayEditing.applyingBatch(edits, semesterID: semester.id, to: data)
        #expect(result.holidayDecisions.count == 7)
        #expect(result.dayOverrides.count == 1)
        #expect(result.dayOverrides[0].officialSourceURL == "official")
        #expect(ScheduleEngine.occurrences(snapshot: result, semesterID: semester.id).filter { semester.calendar.isDate($0.start, inSameDayAs: target) }.count == 1)
        #expect(try BackupCodec.decode(BackupCodec.encode(result)) == result)
        #expect(data.holidayDecisions.isEmpty && data.dayOverrides.isEmpty)
    }
    @Test func batchRejectsDuplicateDaysInvalidReferencesAndOutOfTermTargetsAtomically() throws {
        let data = fixture(); let semester = data.semesters[0]
        let first = HolidayEditing.Edit(date: semester.firstMonday, choice: .noClasses, sourceURL: "official")
        let laterSameDay = HolidayEditing.Edit(date: semester.firstMonday.addingTimeInterval(3600), choice: .keepSchedule, sourceURL: "official")
        for edits in [
            [first, laterSameDay],
            [first, .init(date: instant("2026-10-10T00:00:00+08:00"), choice: .followDate, sourceDate: nil, sourceURL: "official")],
            [first, .init(date: instant("2026-10-10T00:00:00+08:00"), choice: .followDate, sourceDate: instant("2027-01-01T00:00:00+08:00"), sourceURL: "official")],
            [first, .init(date: instant("2027-01-01T00:00:00+08:00"), choice: .noClasses, sourceURL: "official")]
        ] {
            #expect(throws: (any Error).self) { try HolidayEditing.applyingBatch(edits, semesterID: semester.id, to: data) }
        }
        #expect(data.holidayDecisions.isEmpty && data.dayOverrides.isEmpty)
    }
    @Test func batchRefusesManualAndOfficialOverridesAndConfirmedDecisions() throws {
        let original = fixture(); let semester = original.semesters[0]
        let target = instant("2026-10-10T00:00:00+08:00")
        var manual = original; manual.dayOverrides = [.init(semesterID: semester.id, date: target, followsDate: semester.firstMonday)]
        let official = try HolidayEditing.applying(.followDate, date: target, sourceDate: semester.firstMonday, sourceURL: "official", semesterID: semester.id, to: original)
        let decided = try HolidayEditing.applying(.keepSchedule, date: target, sourceDate: nil, sourceURL: "official", semesterID: semester.id, to: original)
        for data in [manual, official, decided] {
            let before = data
            let edits: [HolidayEditing.Edit] = [.init(date: semester.firstMonday, choice: .noClasses, sourceURL: "official"), .init(date: target, choice: .noClasses, sourceURL: "official")]
            #expect(throws: (any Error).self) { try HolidayEditing.applyingBatch(edits, semesterID: semester.id, to: data) }
            #expect(data == before)
        }
    }
    @Test func batchClosuresPreserveExplicitAddedAndMovedCourses() throws {
        var data = fixture(); let semester = data.semesters[0]; let rule = data.rules[0]
        data.exceptions = [
            .init(ruleID: rule.id, originalDate: semester.firstMonday, kind: .added, startMinute: 600, endMinute: 645),
            .init(ruleID: rule.id, originalDate: ScheduleEngine.date(week: 3, weekday: 1, semester: semester), kind: .moved, replacementDate: semester.firstMonday, startMinute: 840, endMinute: 885)
        ]
        let edits: [HolidayEditing.Edit] = [semester.firstMonday, ScheduleEngine.date(week: 3, weekday: 1, semester: semester)].map { .init(date: $0, choice: .noClasses, sourceURL: "official") }
        let closed = try HolidayEditing.applyingBatch(edits, semesterID: semester.id, to: data)
        let events = ScheduleEngine.occurrences(snapshot: closed, semesterID: semester.id).filter { semester.calendar.isDate($0.start, inSameDayAs: semester.firstMonday) }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.isException })
    }
}
