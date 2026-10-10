import ActivityKit
import Foundation
import UIKit
import CourseKit

@MainActor
final class ActivityService {
    static let shared = ActivityService()
    private(set) var lastMessage: String?
    private var foregroundBoundaryTask: Task<Void, Never>?
    private var isRefreshing = false
    private var waitingRefreshes: [CheckedContinuation<Void, Never>] = []

    /// Maintains at most one current or scheduled lesson. No background timer is used.
    func refresh(occurrences: [Occurrence], enabled: Bool) async {
        await acquireRefresh()
        defer { releaseRefresh() }
        guard !Task.isCancelled else { return }
        lastMessage = nil
        foregroundBoundaryTask?.cancel()
        foregroundBoundaryTask = nil
        let now = Date()
        let status = ScheduleEngine.status(at: now, occurrences: occurrences, semester: nil)
        let target = enabled ? (status.current ?? status.next) : nil

        await CourseActivityTransport.endUnwanted(occurrenceID: target?.id, scheduledStart: target?.start)
        guard !Task.isCancelled else { return }
        guard let target else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastMessage = "请在系统设置中允许实况活动。"
            return
        }
        let phaseDate = max(now, target.start)
        let segment = target.segments.first { $0.start <= phaseDate && phaseDate < $0.end }
        let phaseStart = segment?.start ?? target.segments.last(where: { $0.end <= phaseDate })?.end ?? target.start
        let phaseEnd = segment?.end ?? target.segments.first(where: { $0.start > phaseDate })?.start ?? target.end
        let state = CourseActivityAttributes.ContentState(courseName: target.courseName, location: target.location,
                                                          start: target.start, end: target.end, colorIndex: target.colorIndex,
                                                          phase: segment == nil ? .onBreak : .inClass, phaseStart: phaseStart, phaseEnd: phaseEnd,
                                                          segments: target.segments.map { .init(start: $0.start, end: $0.end) })
        // If the app is suspended at a phase boundary, the system marks this content stale.
        // The widget then shows the lesson's fixed schedule instead of a false live phase.
        let content = ActivityContent(state: state, staleDate: phaseEnd)
        scheduleForegroundBoundary(at: phaseEnd, occurrences: occurrences, enabled: enabled)
        if await CourseActivityTransport.updateExisting(occurrenceID: target.id, scheduledStart: target.start, content: content) { return }
        guard !Task.isCancelled else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard target.end.timeIntervalSince(max(now, target.start)) < 8 * 60 * 60 else {
            lastMessage = "本次课程超过实况活动的持续时长，可在课表和小组件中查看。"
            return
        }
        let attributes = CourseActivityAttributes(occurrenceID: target.id, courseID: target.courseID.uuidString,
                                                  scheduledStart: target.start)
        do {
            if target.start > now {
                let alert = AlertConfiguration(title: "开始上课", body: "\(target.courseName) · \(target.location)", sound: .default)
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil, style: .standard,
                                         alertConfiguration: alert, start: target.start)
            } else {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil, style: .standard)
            }
        } catch {
            lastMessage = "实况活动暂时无法开启：\(error.localizedDescription)"
        }
    }

    private func scheduleForegroundBoundary(at date: Date, occurrences: [Occurrence], enabled: Bool) {
        guard UIApplication.shared.applicationState == .active else { return }
        foregroundBoundaryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.2, date.timeIntervalSinceNow + 0.15))) }
            catch { return }
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            self?.foregroundBoundaryTask = nil
            await self?.refresh(occurrences: occurrences, enabled: enabled)
        }
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

/// ActivityKit's Activity reference is not Sendable. Fetch and use it entirely
/// off the main actor instead of sending a UI-isolated reference across executors.
private enum CourseActivityTransport {
    @concurrent static func endUnwanted(occurrenceID: String?, scheduledStart: Date?) async {
        var keptOne = false
        for activity in Activity<CourseActivityAttributes>.activities {
            let matches = occurrenceID != nil && activity.attributes.occurrenceID == occurrenceID &&
                activity.attributes.scheduledStart == scheduledStart && [.active, .pending, .stale].contains(activity.activityState)
            if matches && !keptOne { keptOne = true }
            else { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    @concurrent static func updateExisting(occurrenceID: String, scheduledStart: Date,
                                          content: ActivityContent<CourseActivityAttributes.ContentState>) async -> Bool {
        guard let activity = Activity<CourseActivityAttributes>.activities.first(where: {
            $0.attributes.occurrenceID == occurrenceID && $0.attributes.scheduledStart == scheduledStart &&
                [.active, .pending, .stale].contains($0.activityState)
        }) else { return false }
        await activity.update(content)
        return true
    }
}
