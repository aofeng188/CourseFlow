import XCTest
import EventKit
import UserNotifications
import WidgetKit
import CourseKit
@testable import CourseFlow

/// Deliberately simulator-only: these tests never request permissions or operate on a physical device.
@MainActor
final class SystemIntegrationTests: XCTestCase {
    private let verificationStore = EKEventStore()

    func testWidgetBridgeRoundTripInSharedAppGroupAndRestoreSnapshot() throws {
        try requireSimulator()
        guard let url = CourseAppGroup.snapshotURL else {
            throw XCTSkip("模拟器宿主未配置 App Group；不能验证真实共享容器。")
        }
        let existed = FileManager.default.fileExists(atPath: url.path)
        let originalData = existed ? try Data(contentsOf: url) : nil
        addTeardownBlock { @MainActor in
            if let originalData {
                try originalData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                XCTAssertEqual(try Data(contentsOf: url), originalData, "必须原样恢复已有的小组件快照")
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            WidgetCenter.shared.reloadAllTimelines()
        }

        let semester = makeSemester()
        let occurrences = makeOccurrences(count: 2, semester: semester)
        let snapshot = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      semester: semester, occurrences: occurrences)
        try WidgetBridge.write(snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let diskSnapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(diskSnapshot.semester, semester)
        let widgetSnapshot = CourseAppGroup.readSnapshot()
        XCTAssertEqual(widgetSnapshot.generatedAt, snapshot.generatedAt)
        XCTAssertEqual(widgetSnapshot.semester, semester)
        XCTAssertEqual(widgetSnapshot.occurrences, occurrences, "小组件使用的共享读取路径必须读到主 App 写入的数据")
    }

    func testCalendarRoundTripDeduplicationAndManualEditProtection() async throws {
        try requireSimulator()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("模拟器未预先授予完整日历权限；测试不自动弹窗。")
        }
        guard verificationStore.defaultCalendarForNewEvents?.source != nil || verificationStore.sources.contains(where: { $0.sourceType == .local }) else {
            throw XCTSkip("模拟器尚未配置可写入的日历账户。")
        }
        let semester = makeSemester()
        var occurrences = makeOccurrences(count: 2, semester: semester)
        let service = CalendarSyncService.shared
        addTeardownBlock { @MainActor in
            let store = EKEventStore()
            let name = "课序 · \(semester.name)"
            for calendar in store.calendars(for: .event) where calendar.title == name {
                try store.removeCalendar(calendar, commit: true)
            }
            _ = await CalendarSyncService.shared.remove(semester: semester)
        }

        let first = await service.sync(semester: semester, occurrences: occurrences, defaultLeadMinutes: 10)
        XCTAssertTrue(first.errors.isEmpty, first.summary)
        XCTAssertEqual(first.savedCount, 2)
        XCTAssertEqual(first.coveredIDs, Set(occurrences.map(\.id)))
        XCTAssertEqual(try calendarEvents(semester).count, 2)

        let repeated = await service.sync(semester: semester, occurrences: occurrences, defaultLeadMinutes: 10)
        XCTAssertTrue(repeated.errors.isEmpty, repeated.summary)
        XCTAssertEqual(repeated.savedCount, 0, "重复同步不应再次写入相同课次")
        XCTAssertEqual(try calendarEvents(semester).count, 2)

        // A Calendar event with its alarm removed must not suppress the app reminder.
        let alarmStore = verificationStore
        let firstEvent = try XCTUnwrap(calendarEvents(semester).first { $0.title == occurrences[0].courseName })
        let alarmEvent = try XCTUnwrap(alarmStore.calendarItem(withIdentifier: firstEvent.calendarItemIdentifier) as? EKEvent)
        alarmEvent.alarms = []
        try alarmStore.save(alarmEvent, span: .thisEvent, commit: true)
        let withoutAlarm = service.coveredIDs(for: semester, occurrences: occurrences, defaultLeadMinutes: 10)
        XCTAssertFalse(withoutAlarm.contains(occurrences[0].id), "无日历alarm不能抑制App提醒")
        XCTAssertTrue(withoutAlarm.contains(occurrences[1].id))
        XCTAssertTrue(service.hasManagedEvents(for: semester), "无alarm也仍是已导出的课程")
        XCTAssertTrue(service.coveredIDs(for: semester, occurrences: occurrences, defaultLeadMinutes: 30).isEmpty,
                      "旧提前量不能当作新提前量已经覆盖")
        alarmEvent.alarms = [EKAlarm(relativeOffset: -600)]
        try alarmStore.save(alarmEvent, span: .thisEvent, commit: true)

        let original = occurrences[0].segments[0]
        occurrences[0].segments = [TeachingSegment(start: original.start.addingTimeInterval(15 * 60), end: original.end.addingTimeInterval(15 * 60))]
        occurrences[0].location = "调整后的测试教室"
        let changed = await service.sync(semester: semester, occurrences: occurrences, defaultLeadMinutes: 10)
        XCTAssertTrue(changed.errors.isEmpty, changed.summary)
        XCTAssertEqual(changed.savedCount, 1)
        let moved = try XCTUnwrap(calendarEvents(semester).first { $0.title == occurrences[0].courseName })
        XCTAssertEqual(moved.startDate, occurrences[0].start)
        XCTAssertEqual(moved.location, occurrences[0].location)
        let movedIdentifier = moved.calendarItemIdentifier
        XCTAssertEqual(try calendarEvents(semester).count, 2)

        // Use a different event store to model an edit made from the Calendar app.
        let externalStore = verificationStore
        let externalEvent = try XCTUnwrap(externalStore.calendarItem(withIdentifier: movedIdentifier) as? EKEvent)
        externalEvent.location = "用户手动保留的教室"
        externalEvent.notes = (externalEvent.notes ?? "") + "\n用户手工备注"
        try externalStore.save(externalEvent, span: .thisEvent, commit: true)
        let externalIdentifier = externalEvent.calendarItemIdentifier

        let protected = await service.sync(semester: semester, occurrences: occurrences, defaultLeadMinutes: 10)
        XCTAssertTrue(protected.errors.isEmpty, protected.summary)
        XCTAssertFalse(protected.conflicts.isEmpty)
        XCTAssertEqual(try calendarEvents(semester).first { $0.title == occurrences[0].courseName }?.location, "用户手动保留的教室")

        let shiftedEvent = try XCTUnwrap(externalStore.calendarItem(withIdentifier: externalIdentifier) as? EKEvent)
        shiftedEvent.startDate = shiftedEvent.startDate.addingTimeInterval(30 * 60)
        shiftedEvent.endDate = shiftedEvent.endDate.addingTimeInterval(30 * 60)
        try externalStore.save(shiftedEvent, span: .thisEvent, commit: true)
        XCTAssertFalse(service.coveredIDs(for: semester, occurrences: occurrences, defaultLeadMinutes: 10).contains(occurrences[0].id),
                       "日历手动改时后，原计划仍需要App提醒")

        let removed = await service.remove(semester: semester)
        XCTAssertTrue(removed.errors.isEmpty, removed.summary)
        XCTAssertEqual(removed.removedCount, 1, "仅移除未经用户修改的事件")
        XCTAssertEqual(try calendarEvents(semester).count, 1)
        XCTAssertEqual(try calendarEvents(semester).first?.location, "用户手动保留的教室")
        XCTAssertFalse(removed.conflicts.isEmpty)
    }

    func testNotificationsRespectBudgetReconcileAndPreserveOtherRequests() async throws {
        try requireSimulator()
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            throw XCTSkip("模拟器未预先授予通知权限；测试不自动弹窗。")
        }
        let semester = makeSemester()
        let occurrences = makeOccurrences(count: 65, semester: semester)
        let otherID = "integration.unrelated.\(UUID().uuidString)"
        addTeardownBlock {
            _ = await NotificationService.shared.refresh(occurrences: [], defaultLeadMinutes: 10, calendarCoveredIDs: [], allowDuplicates: false)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [otherID])
        }
        let content = UNMutableNotificationContent()
        content.title = "独立测试请求"
        let other = UNNotificationRequest(identifier: otherID, content: content,
                                          trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false))
        try await center.add(other)
        let first = await NotificationService.shared.refresh(occurrences: occurrences, defaultLeadMinutes: 10,
                                                              calendarCoveredIDs: [], allowDuplicates: false)
        XCTAssertTrue(first.errors.isEmpty, first.summary)
        XCTAssertEqual(first.scheduledCount, 60)
        XCTAssertEqual(first.coverageEnd, occurrences[59].start)
        let firstPending = await center.pendingNotificationRequests()
        let initialIDs = Set(firstPending.filter { $0.identifier.hasPrefix("com.courseflow.lesson.") }.map(\.identifier))
        XCTAssertEqual(initialIDs.count, 60)
        XCTAssertTrue(firstPending.contains { $0.identifier == otherID })

        let repeated = await NotificationService.shared.refresh(occurrences: occurrences, defaultLeadMinutes: 10,
                                                                 calendarCoveredIDs: [], allowDuplicates: false)
        XCTAssertEqual(repeated.scheduledCount, 60)
        let repeatedPending = await center.pendingNotificationRequests()
        XCTAssertEqual(Set(repeatedPending.filter { $0.identifier.hasPrefix("com.courseflow.lesson.") }.map(\.identifier)), initialIDs)

        var revisedOccurrences = occurrences
        let revisedStart = occurrences[0].start.addingTimeInterval(15 * 60)
        revisedOccurrences[0].segments = [TeachingSegment(start: revisedStart, end: revisedStart.addingTimeInterval(45 * 60))]
        revisedOccurrences[0].courseName = "改名后的测试课程"
        revisedOccurrences[0].location = "更新后的测试教室"
        let revised = await NotificationService.shared.refresh(occurrences: revisedOccurrences, defaultLeadMinutes: 10,
                                                                calendarCoveredIDs: [], allowDuplicates: false)
        XCTAssertTrue(revised.errors.isEmpty, revised.summary)
        XCTAssertEqual(revised.scheduledCount, 60)
        let revisedPending = await center.pendingNotificationRequests()
        let revisedRequest = try XCTUnwrap(revisedPending.first {
            $0.identifier == "com.courseflow.lesson.\(occurrences[0].id).10"
        })
        let revisedTrigger = try XCTUnwrap(revisedRequest.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(try XCTUnwrap(revisedTrigger.nextTriggerDate()).timeIntervalSince1970,
                       revisedStart.addingTimeInterval(-600).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(revisedRequest.content.title, revisedOccurrences[0].courseName)
        XCTAssertTrue(revisedRequest.content.body.contains(revisedOccurrences[0].location))
        XCTAssertEqual(Set(revisedPending.filter { $0.identifier.hasPrefix("com.courseflow.lesson.") }.map(\.identifier)), initialIDs,
                       "同一课次改时和改地点必须替换旧请求，不得新增另一条")

        let cleared = await NotificationService.shared.refresh(occurrences: [], defaultLeadMinutes: 10,
                                                                calendarCoveredIDs: [], allowDuplicates: false)
        XCTAssertEqual(cleared.scheduledCount, 0)
        let finalPending = await center.pendingNotificationRequests()
        XCTAssertFalse(finalPending.contains { $0.identifier.hasPrefix("com.courseflow.lesson.") })
        XCTAssertTrue(finalPending.contains { $0.identifier == otherID }, "不得清空其他功能的通知")
    }

    func testCalendarRejectsAnotherDeviceOwnerWithoutRequestingPermission() async throws {
        try requireSimulator()
        var semester = makeSemester()
        semester.calendarOwnerDeviceID = "another-test-device-\(UUID().uuidString)"
        let report = await CalendarSyncService.shared.sync(semester: semester, occurrences: makeOccurrences(count: 1, semester: semester))
        XCTAssertEqual(report.savedCount, 0)
        XCTAssertFalse(report.errors.isEmpty)
        XCTAssertTrue(report.coveredIDs.isEmpty)
    }

    private func requireSimulator() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("系统集成测试仅允许运行在隔离模拟器上，禁止操作真机资料。")
        #endif
    }

    private func makeSemester() -> Semester {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let date = Date().addingTimeInterval(21 * 86400)
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day)!
        return Semester(name: "TEST ONLY \(UUID().uuidString)", firstMonday: monday,
                        timeZoneID: "Etc/GMT", calendarOwnerDeviceID: CalendarSyncService.shared.deviceIdentifier)
    }

    private func makeOccurrences(count: Int, semester: Semester) -> [Occurrence] {
        (0..<count).map { index in
            let start = semester.firstMonday.addingTimeInterval(Double(index + 8) * 3600)
            return Occurrence(id: "integration.\(semester.id.uuidString).\(index)", semesterID: semester.id,
                              courseID: UUID(), ruleID: UUID(), originalDate: start,
                              courseName: "集成测试课程 \(index + 1)", colorIndex: index % 8,
                              location: "模拟器测试教室", teacher: "测试教师", week: 1,
                              segments: [TeachingSegment(start: start, end: start.addingTimeInterval(45 * 60))])
        }
    }

    private func calendarEvents(_ semester: Semester) throws -> [EKEvent] {
        let store = verificationStore
        store.reset()
        let name = "课序 · \(semester.name)"
        let calendars = store.calendars(for: .event).filter { $0.title == name }
        XCTAssertEqual(calendars.count, 1, "测试学期只能有一个专属日历")
        let query = store.predicateForEvents(withStart: semester.firstMonday.addingTimeInterval(-86400),
                                            end: semester.firstMonday.addingTimeInterval(30 * 86400), calendars: calendars)
        return store.events(matching: query).filter { event in
            event.url?.scheme == "courseflow" && event.url?.host == "calendar" &&
            event.url?.pathComponents.dropFirst().first == semester.id.uuidString
        }
    }
}
