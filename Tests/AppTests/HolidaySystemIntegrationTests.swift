import XCTest
import EventKit
import UserNotifications
import CourseKit
@testable import CourseFlow

@MainActor final class HolidaySystemIntegrationTests: XCTestCase {
    private func fixture() -> ScheduleSnapshot {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let future = calendar.startOfDay(for: Date.now.addingTimeInterval(21 * 86400))
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: future) + 5) % 7), to: future)!
        let semester = Semester(name: "HOLIDAY TEST \(UUID().uuidString)", firstMonday: monday, weekCount: 1, timeZoneID: "Etc/GMT", calendarOwnerDeviceID: CalendarSyncService.shared.deviceIdentifier)
        let course = Course(semesterID: semester.id, name: semester.name)
        return .init(semesters: [semester], courses: [course], rules: [1, 2].map { .init(courseID: course.id, weekday: $0, weeks: [1], startMinute: 480, endMinute: 525) })
    }
    private func closureEdits(for semester: Semester) -> [HolidayEditing.Edit] {
        [1, 2].map { weekday in
            .init(date: ScheduleEngine.date(week: 1, weekday: weekday, semester: semester), choice: .noClasses, sourceURL: OfficialHolidayYear.seed2026.sourceURL)
        }
    }
    private func replacementBatch(for semester: Semester, target: Date) -> [HolidayEditing.Edit] {
        closureEdits(for: semester) + [.init(date: target, choice: .followDate, sourceDate: semester.firstMonday, sourceURL: OfficialHolidayYear.seed2026.sourceURL)]
    }
    func testConfirmationRemovesAndReplacesActualPendingNotifications() async throws {
        #if targetEnvironment(simulator)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { throw XCTSkip("先在模拟器授权通知") }
        #else
        throw XCTSkip("系统测试只在模拟器运行")
        #endif
        let data = fixture(); let semester = data.semesters[0]
        let service = NotificationService.shared
        addTeardownBlock { _ = await service.refresh(occurrences: [], defaultLeadMinutes: 10, calendarCoveredIDs: [], allowDuplicates: false) }
        let before = ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id)
        let initial = await service.refresh(occurrences: before, defaultLeadMinutes: 10, calendarCoveredIDs: [], allowDuplicates: false)
        XCTAssertEqual(initial.scheduledCount, 2)
        let closed = try HolidayEditing.applyingBatch(closureEdits(for: semester), semesterID: semester.id, to: data)
        let removal = await service.refresh(occurrences: ScheduleEngine.occurrences(snapshot: closed, semesterID: semester.id), defaultLeadMinutes: 10, calendarCoveredIDs: [], allowDuplicates: false)
        XCTAssertEqual(removal.scheduledCount, 0)
        let remaining = await center.pendingNotificationRequests()
        XCTAssertFalse(remaining.contains { $0.content.title == semester.name })
        let target = ScheduleEngine.date(week: 1, weekday: 6, semester: semester)
        // Construct the desired replacement in one atomic batch from unprocessed dates.
        let mapped = try HolidayEditing.applyingBatch(replacementBatch(for: semester, target: target), semesterID: semester.id, to: data)
        XCTAssertEqual(mapped.holidayDecisions.count, 2)
        XCTAssertEqual(mapped.dayOverrides.count, 1)
        let replacement = await service.refresh(occurrences: ScheduleEngine.occurrences(snapshot: mapped, semesterID: semester.id), defaultLeadMinutes: 10, calendarCoveredIDs: [], allowDuplicates: false)
        XCTAssertEqual(replacement.scheduledCount, 1)
        let pending = await center.pendingNotificationRequests()
        let notification = try XCTUnwrap(pending.first { $0.content.title == semester.name })
        XCTAssertEqual((notification.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(), target.addingTimeInterval(470 * 60))
    }
    func testConfirmedRestAndMakeupUpdateActualCalendar() async throws {
        #if targetEnvironment(simulator)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw XCTSkip("先在模拟器授权完整日历") }
        #else
        throw XCTSkip("系统测试只在模拟器运行")
        #endif
        let data = fixture(); let semester = data.semesters[0]; let service = CalendarSyncService.shared
        addTeardownBlock { @MainActor in _ = await service.remove(semester: semester) }
        let initial = await service.sync(semester: semester, occurrences: ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id), defaultLeadMinutes: 10)
        XCTAssertTrue(initial.errors.isEmpty, initial.summary)
        XCTAssertEqual(initial.savedCount, 2)
        let closed = try HolidayEditing.applyingBatch(closureEdits(for: semester), semesterID: semester.id, to: data)
        let removal = await service.sync(semester: semester, occurrences: ScheduleEngine.occurrences(snapshot: closed, semesterID: semester.id), defaultLeadMinutes: 10)
        XCTAssertTrue(removal.errors.isEmpty, removal.summary)
        XCTAssertEqual(removal.removedCount, 2)
        let target = ScheduleEngine.date(week: 1, weekday: 6, semester: semester)
        let mapped = try HolidayEditing.applyingBatch(replacementBatch(for: semester, target: target), semesterID: semester.id, to: data)
        let events = ScheduleEngine.occurrences(snapshot: mapped, semesterID: semester.id)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(semester.calendar.isDate(try XCTUnwrap(events.first).start, inSameDayAs: target))
        let report = await service.sync(semester: semester, occurrences: events, defaultLeadMinutes: 10)
        XCTAssertTrue(report.errors.isEmpty, report.summary)
        XCTAssertEqual(report.savedCount, 1)
        let covered = await service.coveredIDs(for: semester, occurrences: events, defaultLeadMinutes: 10)
        XCTAssertEqual(covered, Set(events.map(\.id)))
    }
}
