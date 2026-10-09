import Foundation
import Observation
import CourseKit

struct AppPreferences: Codable, Equatable {
    var notificationsEnabled = false
    var reminderMinutes = 10
    var duplicateReminders = false
    var activitiesEnabled = false
    var hideEmptyWeekends = false
}

@MainActor @Observable final class AppStore {
    /// The app's live store, for App Intents that run without a SwiftUI environment.
    static var current: AppStore?
    let holidays = HolidayService()
    let persistence: Persistence
    private let systemIntegrationsEnabled: Bool
    private(set) var snapshot = ScheduleSnapshot()
    private(set) var occurrences: [Occurrence] = []
    private(set) var revision = 0
    var selectedSemesterID: UUID? { didSet { UserDefaults.standard.set(selectedSemesterID?.uuidString, forKey: "selectedSemesterID"); refresh() } }
    var preferences: AppPreferences { didSet { if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "preferences") }; refresh() } }
    var errorMessage: String?
    var notice: String?
    var notificationSummary = "尚未开启上课提醒"
    var calendarSummary = "尚未添加到日历"
    var selectedCourseID: UUID?
    /// Most recent last. Any change that arrives from outside (sync, another window) clears it,
    /// so an undo can never overwrite newer data.
    private var undoStack: [(snapshot: ScheduleSnapshot, label: String)] = []
    private let undoLimit = 20
    private var reportedUnreadableCount = 0
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    var canUndo: Bool { !undoStack.isEmpty }
    var undoLabel: String? { undoStack.last?.label }
    var semester: Semester? { snapshot.semesters.first { $0.id == selectedSemesterID } ?? snapshot.semesters.sorted { $0.firstMonday > $1.firstMonday }.first }
    var courses: [Course] { snapshot.courses.filter { $0.semesterID == semester?.id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var bells: [BellSchedule] { snapshot.bellSchedules.filter { $0.semesterID == semester?.id }.sorted { $0.effectiveFrom < $1.effectiveFrom } }
    init(persistence: Persistence, systemIntegrationsEnabled: Bool = true) throws {
        self.persistence = persistence
        self.systemIntegrationsEnabled = systemIntegrationsEnabled
        preferences = UserDefaults.standard.data(forKey: "preferences").flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0) } ?? AppPreferences()
        selectedSemesterID = UserDefaults.standard.string(forKey: "selectedSemesterID").flatMap(UUID.init(uuidString:))
        snapshot = try persistence.read()
        reportUnreadableRecords()
        refresh()
    }
    /// Reloads stored data. System content (reminders, widgets, calendar) is rebuilt only when
    /// the data changed, unless `forceRefresh` asks for it, e.g. when returning to the foreground.
    func reload(forceRefresh: Bool = false) {
        do {
            let value = try persistence.read()
            reportUnreadableRecords()
            if value != snapshot { snapshot = value; undoStack.removeAll(); refresh() }
            else if forceRefresh { refresh() }
        }
        catch { errorMessage = "无法读取课表：\(error.localizedDescription)" }
    }
    private func reportUnreadableRecords() {
        let count = persistence.unreadableRecordCount
        defer { reportedUnreadableCount = count }
        guard count > reportedUnreadableCount else { return }
        errorMessage = "有 \(count) 条课表记录无法读取，已暂时跳过，原数据会继续保留。它们可能来自更新版本的课序，请更新 App 后再查看。"
    }
    func waitForRefresh() async { await refreshTask?.value }
    @discardableResult func apply(_ label: String, _ edit: (inout ScheduleSnapshot) -> Void) -> Bool {
        do {
            let latest = try persistence.read()
            if latest != snapshot { snapshot = latest; undoStack.removeAll(); refresh() }
        }
        catch { errorMessage = "未保存更改：无法读取最新资料"; return false }
        var changed = snapshot; edit(&changed)
        guard changed != snapshot else { return true }
        do {
            try BackupCodec.validate(changed)
            try persistence.write(changed)
            pushUndo(snapshot, label: label); snapshot = (try? persistence.read()) ?? changed; refresh(); return true
        } catch { errorMessage = "未保存更改：\(error.localizedDescription)"; return false }
    }
    private func pushUndo(_ value: ScheduleSnapshot, label: String) {
        undoStack.append((value, label))
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
    }
    func undo() {
        guard let entry = undoStack.last else { return }
        do {
            let latest = try persistence.read()
            guard latest == snapshot else {
                snapshot = latest; undoStack.removeAll(); refresh()
                errorMessage = "资料已有新的同步更改，已保留最新内容。请重新编辑需要调整的课程。"
                return
            }
            try persistence.write(entry.snapshot); snapshot = entry.snapshot; undoStack.removeLast(); notice = "已撤销\(entry.label)"; refresh()
        }
        catch { errorMessage = error.localizedDescription }
    }
    func refresh() {
        refreshTask?.cancel(); generation += 1
        let version = generation, data = snapshot, selected = semester, prefs = preferences
        revision += 1
        refreshTask = Task {
            let events = await Task.detached(priority: .userInitiated) { selected.map { ScheduleEngine.occurrences(snapshot: data, semesterID: $0.id) } ?? [] }.value
            guard !Task.isCancelled, version == generation else { return }
            occurrences = events
            guard systemIntegrationsEnabled else { return }
            if !BuildFeatures.isTrial {
                do { try WidgetBridge.write(WidgetSnapshot(semester: selected, occurrences: events)) }
                catch { /* The local app remains usable when App Group signing has not been configured. */ }
            }
            var covered = Set<String>()
            if let selected {
                let calendarService = CalendarSyncService.shared
                let lead = prefs.reminderMinutes
                if selected.calendarOwnerDeviceID == calendarService.deviceIdentifier, calendarService.hasFullAccess, await calendarService.hasExport(for: selected) {
                    // A successful sync already verified coverage against the calendar it just wrote.
                    let report = await calendarService.sync(semester: selected, occurrences: events, defaultLeadMinutes: lead)
                    calendarSummary = report.summary
                    covered = report.errors.isEmpty ? report.coveredIDs : await calendarService.coveredIDs(for: selected, occurrences: events, defaultLeadMinutes: lead)
                } else {
                    covered = await calendarService.coveredIDs(for: selected, occurrences: events, defaultLeadMinutes: lead)
                }
            }
            guard !Task.isCancelled else { return }
            let schoolTimeZone = selected.flatMap { TimeZone(identifier: $0.timeZoneID) } ?? .current
            let report = await NotificationService.shared.refresh(occurrences: prefs.notificationsEnabled ? events : [], defaultLeadMinutes: prefs.reminderMinutes, calendarCoveredIDs: covered, allowDuplicates: prefs.duplicateReminders, timeZone: schoolTimeZone)
            notificationSummary = prefs.notificationsEnabled ? report.summary : "尚未开启上课提醒"
            if !BuildFeatures.isTrial { await ActivityService.shared.refresh(occurrences: events, enabled: prefs.activitiesEnabled) }
        }
    }
    func loadExample(now: Date = .now) {
        let example = SampleData.make(now: now)
        let success = apply("载入示例") { data in
            data.semesters += example.semesters; data.bellSchedules += example.bellSchedules; data.courses += example.courses; data.rules += example.rules
        }
        if success { selectedSemesterID = example.semesters.first?.id }
    }
    func saveSemester(_ value: Semester) {
        if apply("修改学期", { data in data.semesters.removeAll { $0.id == value.id }; data.semesters.append(value) }) { selectedSemesterID = value.id }
    }
    func saveCourse(_ course: Course, rules: [MeetingRule]) {
        apply("编辑课程") { data in
            let removedIDs = Set(data.rules.filter { $0.courseID == course.id }.map(\.id)).subtracting(rules.map(\.id))
            data.courses.removeAll { $0.id == course.id }; data.courses.append(course)
            data.rules.removeAll { $0.courseID == course.id }; data.rules += rules
            data.exceptions.removeAll { removedIDs.contains($0.ruleID) }
        }
    }
    func deleteCourse(_ id: UUID) {
        apply("删除课程") { data in
            let ruleIDs = Set(data.rules.filter { $0.courseID == id }.map(\.id))
            data.courses.removeAll { $0.id == id }; data.rules.removeAll { $0.courseID == id }; data.exceptions.removeAll { ruleIDs.contains($0.ruleID) }
        }
    }
    @discardableResult func commitImport(_ draft: ImportDraft, replaceDuplicates: Bool) -> Bool {
        guard let semester else { errorMessage = "请先设置学期"; return false }
        if draft.kind == .bellSchedule {
            let schedule = BellSchedule(semesterID: semester.id, name: draft.sourceName.isEmpty ? "导入作息" : draft.sourceName, effectiveFrom: semester.firstMonday, periods: draft.periods, isConfirmed: true)
            let success = apply("导入作息") { data in
                data.bellSchedules.removeAll { $0.semesterID == semester.id && semester.calendar.isDate($0.effectiveFrom, inSameDayAs: schedule.effectiveFrom) }
                data.bellSchedules.append(schedule)
            }
            if success { notice = "已保存学校作息" }; return success
        }
        let lessons = draft.lessons.filter(\.selected)
        guard lessons.allSatisfy({ DraftValidator.issues(for: $0, semester: semester, bellSchedules: bells).isEmpty }) else { errorMessage = "有选中的课程尚未补全，请返回导入核对继续编辑。"; return false }
        guard !lessons.isEmpty else { errorMessage = "没有已补全的课程，请先核对时间、星期和周数"; return false }
        let success = apply("导入课表") { data in
            for lesson in lessons {
                let existingCourse = data.courses.first { $0.semesterID == semester.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == lesson.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                let course = existingCourse ?? Course(semesterID: semester.id, name: lesson.name, colorIndex: data.courses.count % 8)
                if existingCourse == nil { data.courses.append(course) }
                let candidate = data.rules.first { $0.courseID == course.id && $0.weekday == lesson.weekday && $0.periodNumbers == lesson.periods && $0.startMinute == lesson.startMinute && $0.endMinute == lesson.endMinute && Set($0.weeks) == Set(lesson.weeks) }
                if candidate != nil, !replaceDuplicates { continue }
                let rule = MeetingRule(id: candidate?.id ?? UUID(), courseID: course.id, weekday: lesson.weekday ?? 1, weeks: lesson.weeks, periodNumbers: lesson.periods, startMinute: lesson.startMinute, endMinute: lesson.endMinute, location: lesson.location, teacher: lesson.teacher)
                data.rules.removeAll { $0.id == rule.id }; data.rules.append(rule)
            }
        }
        if success { notice = "已核对并保存 \(lessons.count) 条上课安排" }; return success
    }
    func restore(_ value: ScheduleSnapshot) throws {
        try BackupCodec.validate(value)
        let backup = try BackupCodec.encode(snapshot)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try backup.write(to: directory.appendingPathComponent("恢复前-\(Int(Date.now.timeIntervalSince1970)).courseflow"), options: .atomic)
        try persistence.write(value); pushUndo(snapshot, label: "恢复备份"); snapshot = (try? persistence.read()) ?? value; selectedSemesterID = value.semesters.first?.id
    }
}
