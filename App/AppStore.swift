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
    private var previous: ScheduleSnapshot?
    private var previousLabel = ""
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    var canUndo: Bool { previous != nil }
    var semester: Semester? { snapshot.semesters.first { $0.id == selectedSemesterID } ?? snapshot.semesters.sorted { $0.firstMonday > $1.firstMonday }.first }
    var courses: [Course] { snapshot.courses.filter { $0.semesterID == semester?.id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var bells: [BellSchedule] { snapshot.bellSchedules.filter { $0.semesterID == semester?.id }.sorted { $0.effectiveFrom < $1.effectiveFrom } }
    init(persistence: Persistence, systemIntegrationsEnabled: Bool = true) throws {
        self.persistence = persistence
        self.systemIntegrationsEnabled = systemIntegrationsEnabled
        preferences = UserDefaults.standard.data(forKey: "preferences").flatMap { try? JSONDecoder().decode(AppPreferences.self, from: $0) } ?? AppPreferences()
        selectedSemesterID = UserDefaults.standard.string(forKey: "selectedSemesterID").flatMap(UUID.init(uuidString:))
        snapshot = try persistence.read()
        refresh()
    }
    func reload() {
        do { let value = try persistence.read(); if value != snapshot { snapshot = value; previous = nil }; refresh() }
        catch { errorMessage = "无法读取课表：\(error.localizedDescription)" }
    }
    func waitForRefresh() async { await refreshTask?.value }
    @discardableResult func apply(_ label: String, _ edit: (inout ScheduleSnapshot) -> Void) -> Bool {
        do {
            let latest = try persistence.read()
            if latest != snapshot { snapshot = latest; previous = nil; refresh() }
        }
        catch { errorMessage = "未保存更改：无法读取最新资料"; return false }
        var changed = snapshot; edit(&changed)
        guard changed != snapshot else { return true }
        do {
            try BackupCodec.validate(changed)
            try persistence.write(changed)
            previous = snapshot; previousLabel = label; snapshot = (try? persistence.read()) ?? changed; refresh(); return true
        } catch { errorMessage = "未保存更改：\(error.localizedDescription)"; return false }
    }
    func undo() {
        guard let value = previous else { return }
        do {
            let latest = try persistence.read()
            guard latest == snapshot else {
                snapshot = latest; previous = nil; refresh()
                errorMessage = "资料已有新的同步更改，已保留最新内容。请重新编辑需要调整的课程。"
                return
            }
            try persistence.write(value); snapshot = value; previous = nil; notice = "已撤销\(previousLabel)"; refresh()
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
                covered = calendarService.coveredIDs(for: selected, occurrences: events, defaultLeadMinutes: prefs.reminderMinutes)
                if selected.calendarOwnerDeviceID == calendarService.deviceIdentifier, calendarService.hasExport(for: selected), calendarService.hasFullAccess {
                    let report = await calendarService.sync(semester: selected, occurrences: events, defaultLeadMinutes: prefs.reminderMinutes)
                    calendarSummary = report.summary
                    covered = calendarService.coveredIDs(for: selected, occurrences: events, defaultLeadMinutes: prefs.reminderMinutes)
                }
            }
            guard !Task.isCancelled else { return }
            let report = await NotificationService.shared.refresh(occurrences: prefs.notificationsEnabled ? events : [], defaultLeadMinutes: prefs.reminderMinutes, calendarCoveredIDs: covered, allowDuplicates: prefs.duplicateReminders)
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
        try persistence.write(value); previous = snapshot; previousLabel = "恢复备份"; snapshot = (try? persistence.read()) ?? value; selectedSemesterID = value.semesters.first?.id; refresh()
    }
}
