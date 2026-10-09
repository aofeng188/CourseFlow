import Foundation
import UserNotifications
import CourseKit

struct NotificationReport: Sendable {
    var scheduledCount: Int = 0
    var coverageEnd: Date?
    var authorizationDescription: String = "尚未开启"
    var errors: [String] = []
    var timeZone: TimeZone = .current
    var summary: String {
        if let error = errors.first { return "\(authorizationDescription) · \(error)" }
        guard scheduledCount > 0 else { return "\(authorizationDescription) · 暂无待提醒课程" }
        return "已安排 \(scheduledCount) 条提醒" + (coverageEnd.map { "，覆盖至 " + Display.format($0, style: .dateTime.month().day().hour().minute(), zone: timeZone.identifier) } ?? "")
    }
}

/// Each reminder represents one real lesson, so cancelled weeks cannot keep repeating.
actor NotificationService {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()
    private let prefix = "com.courseflow.lesson."
    private var isRefreshing = false
    private var waitingRefreshes: [CheckedContinuation<Void, Never>] = []

    func requestAuthorization() async -> Bool {
        do { return try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { return false }
    }

    /// `timeZone` is the school's zone, so reminder text matches the times shown in the app.
    func refresh(occurrences: [Occurrence], defaultLeadMinutes: Int,
                 calendarCoveredIDs: Set<String>, allowDuplicates: Bool, timeZone: TimeZone = .current) async -> NotificationReport {
        // UNUserNotificationCenter calls suspend the actor. Serialize reconciliation so
        // an older add cannot land after a newer refresh removed that reminder.
        await acquireRefresh()
        defer { releaseRefresh() }
        guard !Task.isCancelled else {
            return NotificationReport(authorizationDescription: "已取消本轮核对")
        }
        let settings = await center.notificationSettings()
        let description: String
        switch settings.authorizationStatus {
        case .authorized: description = "已开启"
        case .provisional: description = "静默送达"
        case .ephemeral: description = "临时授权"
        case .denied: description = "系统通知已关闭"
        case .notDetermined: description = "尚未开启"
        @unknown default: description = "请检查系统通知设置"
        }
        let existing = await center.pendingNotificationRequests()
        let owned = existing.filter { $0.identifier.hasPrefix(prefix) }
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier))
            return NotificationReport(authorizationDescription: description)
        }

        let now = Date()
        var seen = Set<String>()
        let candidates = occurrences.compactMap { occurrence -> (Occurrence, Date, Int)? in
            guard !occurrence.segments.isEmpty, occurrence.start < occurrence.end,
                  allowDuplicates || !calendarCoveredIDs.contains(occurrence.id), seen.insert(occurrence.id).inserted else { return nil }
            let lead = occurrence.reminderMinutes ?? defaultLeadMinutes
            guard lead >= 0 else { return nil }
            let fireDate = occurrence.start.addingTimeInterval(-Double(lead) * 60)
            guard fireDate > now else { return nil }
            return (occurrence, fireDate, lead)
        }.sorted { $0.1 < $1.1 }
        // Also leave room for any non-lesson requests belonging to the app.
        let budget = max(0, min(60, 64 - (existing.count - owned.count)))
        let planned = Array(candidates.prefix(budget))
        let desiredIDs = Set(planned.map { identifier(for: $0.0.id, lead: $0.2) })
        center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier).filter { !desiredIDs.contains($0) })
        var errors: [String] = []

        for (occurrence, fireDate, lead) in planned {
            if Task.isCancelled {
                errors.append("提醒安排被中断，下次打开课序时会继续核对。")
                break
            }
            let content = UNMutableNotificationContent()
            content.title = occurrence.courseName
            content.body = notificationBody(for: occurrence, timeZone: timeZone)
            content.sound = .default
            content.threadIdentifier = "courseflow.classes"
            content.userInfo = ["occurrenceID": occurrence.id, "courseID": occurrence.courseID.uuidString,
                                "semesterID": occurrence.semesterID.uuidString]
            // Absolute dates prevent device travel from moving a school's class time.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            components.timeZone = .gmt
            let request = UNNotificationRequest(identifier: identifier(for: occurrence.id, lead: lead), content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            do { try await center.add(request) }
            catch { errors.append("\(occurrence.courseName)：\(error.localizedDescription)") }
        }
        let verified = await center.pendingNotificationRequests()
        let requestsByID = Dictionary(uniqueKeysWithValues: verified.map { ($0.identifier, $0) })
        // Replacing a request may fail while an older request with the same stable ID
        // remains queued. Verify its date and visible content, not just its identifier.
        let verifiedIDs = Set(planned.compactMap { occurrence, fireDate, lead -> String? in
            let id = identifier(for: occurrence.id, lead: lead)
            guard let request = requestsByID[id],
                  let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  !trigger.repeats, let actualFireDate = trigger.nextTriggerDate(),
                  abs(actualFireDate.timeIntervalSince(fireDate)) < 1,
                  request.content.title == occurrence.courseName,
                  request.content.body == notificationBody(for: occurrence, timeZone: timeZone),
                  request.content.sound != nil else { return nil }
            return id
        })
        let mismatchedIDs = desiredIDs.subtracting(verifiedIDs).filter { requestsByID[$0] != nil }
        center.removePendingNotificationRequests(withIdentifiers: Array(mismatchedIDs))
        let accepted = planned.filter { verifiedIDs.contains(identifier(for: $0.0.id, lead: $0.2)) }
        if accepted.count != planned.count {
            errors.append("有 \(planned.count - accepted.count) 条提醒未进入系统队列，请稍后重新安排。")
        }
        // Only claim a continuous coverage window up to the first missing lesson.
        var coverageEnd: Date?
        for item in planned {
            guard verifiedIDs.contains(identifier(for: item.0.id, lead: item.2)) else { break }
            coverageEnd = item.0.start
        }
        return NotificationReport(scheduledCount: accepted.count, coverageEnd: coverageEnd,
                                  authorizationDescription: description, errors: errors, timeZone: timeZone)
    }

    private func identifier(for occurrenceID: String, lead: Int) -> String {
        prefix + occurrenceID + "." + String(lead)
    }

    private func notificationBody(for occurrence: Occurrence, timeZone: TimeZone) -> String {
        let time = Display.time(occurrence.start, zone: timeZone.identifier)
        return "\(time) 上课 · \(occurrence.location.isEmpty ? "地点待补充" : occurrence.location)"
    }

    private func acquireRefresh() async {
        if !isRefreshing { isRefreshing = true; return }
        await withCheckedContinuation { waitingRefreshes.append($0) }
    }

    private func releaseRefresh() {
        if waitingRefreshes.isEmpty { isRefreshing = false }
        else { waitingRefreshes.removeFirst().resume() }
    }
}
