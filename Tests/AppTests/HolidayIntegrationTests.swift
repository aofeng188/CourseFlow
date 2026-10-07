import XCTest
import CourseKit
@testable import CourseFlow

@MainActor final class HolidayIntegrationTests: XCTestCase {
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testTimeStatusBoundariesAndAgendaInsertion() throws {
        let data = SampleData.make(now: instant("2026-10-05T08:20:00+08:00")); let semester = data.semesters[0]
        let events = ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id).filter { semester.calendar.isDate($0.start, inSameDayAs: instant("2026-10-05T08:20:00+08:00")) }
        let event = try XCTUnwrap(events.first)
        XCTAssertNil(ScheduleTime.status(event, now: event.start.addingTimeInterval(-1)))
        XCTAssertEqual(ScheduleTime.status(event, now: event.start), "正在上课")
        XCTAssertEqual(ScheduleTime.status(event, now: event.segments[0].end), "课间休息")
        XCTAssertNil(ScheduleTime.status(event, now: event.end))
        XCTAssertEqual(ScheduleTime.insertionIndex(events, now: event.start), 0)
        XCTAssertEqual(ScheduleTime.insertionIndex(events, now: event.end), 1)
        XCTAssertEqual(ScheduleTime.insertionIndex(events, now: .distantFuture), events.count)
        XCTAssertEqual(ScheduleTime.insertionIndex([], now: event.start), 0)
    }
    func testDayNightUsesSchoolZone() {
        let semester = Semester(firstMonday: instant("2026-09-14T00:00:00+08:00"))
        XCTAssertEqual(ScheduleTime.symbol(now: instant("2026-10-05T05:59:59+08:00"), semester: semester), "moon.stars")
        XCTAssertEqual(ScheduleTime.symbol(now: instant("2026-10-05T06:00:00+08:00"), semester: semester), "sun.max")
        XCTAssertEqual(ScheduleTime.symbol(now: instant("2026-10-05T09:59:59Z"), semester: semester), "sun.max")
        XCTAssertEqual(ScheduleTime.symbol(now: instant("2026-10-05T10:00:00Z"), semester: semester), "moon.stars")
    }
    func testHolidayDecisionPersistenceUndoAndMappingReset() throws {
        let persistence = try Persistence(inMemory: true); let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        let data = SampleData.make(now: instant("2026-10-05T08:20:00+08:00")); let semester = data.semesters[0]
        XCTAssertTrue(store.apply("示例") { $0 = data })
        let closed = try HolidayEditing.applying(.noClasses, date: semester.firstMonday, sourceDate: nil, sourceURL: OfficialHolidayYear.seed2026.sourceURL, semesterID: semester.id, to: data)
        XCTAssertTrue(store.apply("停课") { $0 = closed })
        XCTAssertEqual(try persistence.read().holidayDecisions, closed.holidayDecisions)
        store.undo()
        XCTAssertTrue(try persistence.read().holidayDecisions.isEmpty, store.errorMessage ?? "")
        let followed = try HolidayEditing.applying(.followDate, date: semester.firstMonday, sourceDate: semester.firstMonday, sourceURL: OfficialHolidayYear.seed2026.sourceURL, semesterID: semester.id, to: store.snapshot)
        XCTAssertTrue(store.apply("换课") { $0 = followed })
        XCTAssertEqual(try persistence.read().dayOverrides.first?.officialSourceURL, OfficialHolidayYear.seed2026.sourceURL)
        XCTAssertTrue(store.apply("恢复待确认") { $0 = HolidayEditing.resetting(date: semester.firstMonday, semester: semester, in: $0) })
        XCTAssertTrue(try persistence.read().dayOverrides.isEmpty)
    }
    func testBatchPersistenceSingleUndoAndV2BackupRoundTrip() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        let data = SampleData.make(now: instant("2026-10-05T08:20:00+08:00"))
        let semester = data.semesters[0]
        XCTAssertTrue(store.apply("示例") { $0 = data })
        let before = try persistence.read()
        let second = ScheduleEngine.date(week: 1, weekday: 2, semester: semester)
        let makeup = ScheduleEngine.date(week: 1, weekday: 6, semester: semester)
        let edits: [HolidayEditing.Edit] = [
            .init(date: semester.firstMonday, choice: .noClasses, sourceURL: OfficialHolidayYear.seed2026.sourceURL),
            .init(date: second, choice: .keepSchedule, sourceURL: OfficialHolidayYear.seed2026.sourceURL),
            .init(date: makeup, choice: .followDate, sourceDate: semester.firstMonday, sourceURL: OfficialHolidayYear.seed2026.sourceURL)
        ]
        var editError: Error?
        XCTAssertTrue(store.apply("批量确认节日") { snapshot in
            do { snapshot = try HolidayEditing.applyingBatch(edits, semesterID: semester.id, to: snapshot) }
            catch { editError = error }
        })
        XCTAssertNil(editError)
        let saved = try persistence.read()
        XCTAssertEqual(saved.holidayDecisions.count, 2)
        XCTAssertEqual(saved.dayOverrides.count, 1)
        XCTAssertEqual(saved.dayOverrides.first?.followsDate, semester.firstMonday)
        XCTAssertEqual(saved.dayOverrides.first?.officialSourceURL, OfficialHolidayYear.seed2026.sourceURL)
        let backup = try BackupCodec.encode(saved)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        XCTAssertEqual(header["version"] as? Int, 2)
        let restored = try BackupCodec.decode(backup)
        XCTAssertEqual(restored.holidayDecisions, saved.holidayDecisions)
        XCTAssertEqual(restored.dayOverrides, saved.dayOverrides)
        XCTAssertEqual(ScheduleEngine.occurrences(snapshot: restored, semesterID: semester.id), ScheduleEngine.occurrences(snapshot: saved, semesterID: semester.id))
        store.undo()
        XCTAssertEqual(try persistence.read(), before, store.errorMessage ?? "")
        XCTAssertFalse(store.canUndo)
    }
    func testBatchRejectsNewlySyncedDecisionsAndManualOverridesWithoutPartialSave() async throws {
        for manualOverride in [false, true] {
            let persistence = try Persistence(inMemory: true)
            let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
            let data = SampleData.make(now: instant("2026-10-05T08:20:00+08:00"))
            let semester = data.semesters[0]
            XCTAssertTrue(store.apply("示例") { $0 = data })
            let first = semester.firstMonday
            let changedDate = ScheduleEngine.date(week: 1, weekday: 2, semester: semester)
            let staged: [HolidayEditing.Edit] = [
                .init(date: first, choice: .noClasses, sourceURL: OfficialHolidayYear.seed2026.sourceURL),
                .init(date: changedDate, choice: .noClasses, sourceURL: OfficialHolidayYear.seed2026.sourceURL)
            ]
            var latest = try persistence.read()
            if manualOverride {
                latest.dayOverrides.append(.init(semesterID: semester.id, date: changedDate, followsDate: first))
            } else {
                latest.holidayDecisions.append(.init(semesterID: semester.id, date: changedDate, kind: .keepSchedule, sourceURL: OfficialHolidayYear.seed2026.sourceURL))
            }
            try persistence.write(latest)
            let expected = try persistence.read()
            var editError: Error?
            XCTAssertTrue(store.apply("批量确认节日") { snapshot in
                do { snapshot = try HolidayEditing.applyingBatch(staged, semesterID: semester.id, to: snapshot) }
                catch { editError = error }
            })
            XCTAssertNotNil(editError)
            XCTAssertEqual(store.snapshot, expected)
            XCTAssertEqual(try persistence.read(), expected)
            XCTAssertFalse(store.canUndo, "不能用旧撤销覆盖新同步的学校安排")
            await store.waitForRefresh()
            XCTAssertEqual(store.occurrences, ScheduleEngine.occurrences(snapshot: expected, semesterID: semester.id))
            store.undo()
            XCTAssertEqual(try persistence.read(), expected)
            XCTAssertFalse(store.snapshot.holidayDecisions.contains { semester.calendar.isDate($0.date, inSameDayAs: first) })
        }
    }
    func testOfflineSeedMissingYearAndInvalidCache() throws {
        let service = HolidayService(cacheURL: nil)
        let semester = Semester(firstMonday: instant("2026-12-28T00:00:00+08:00"), weekCount: 4)
        XCTAssertEqual(service.relevantYears(semester), [2026, 2027])
        XCTAssertEqual(service.missingYears(for: semester), [2027])
        XCTAssertEqual(service.years[2026]?.days.count, 39)
        let autumn = Semester(firstMonday: instant("2026-09-14T00:00:00+08:00"), weekCount: 18)
        let groups = try XCTUnwrap(service.years[2026]).groups
        XCTAssertEqual(groups.count, 7)
        let nationalDay = try XCTUnwrap(groups.first { $0.name == "国庆节" })
        XCTAssertEqual(nationalDay.days(in: autumn).map(\.dateKey), ["2026-09-20", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07", "2026-10-10"])
        let snapshot = ScheduleSnapshot(semesters: [autumn])
        XCTAssertFalse(HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-09-12T12:00:00+08:00"), semester: autumn, snapshot: snapshot))
        XCTAssertTrue(HolidayCalendar.shouldPrompt(nationalDay, now: instant("2026-09-13T12:00:00+08:00"), semester: autumn, snapshot: snapshot))
        XCTAssertFalse(HolidayService.isOfficialURL(URL(string: "https://www.gov.cn.example.com/notice")))
        XCTAssertFalse(HolidayService.isOfficialURL(URL(string: "http://www.gov.cn/notice")))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a cache".utf8).write(to: url)
        XCTAssertEqual(HolidayService(cacheURL: url).years[2026], .seed2026)
    }
}
