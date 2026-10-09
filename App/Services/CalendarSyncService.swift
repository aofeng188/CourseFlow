import Foundation
import EventKit
import CryptoKit
import Security
import CourseKit

struct CalendarSyncPreview {
    var hasFullAccess = false
    var calendarName: String?
    var createCount = 0
    var updateCount = 0
    var removeCount = 0
    var unchangedCount = 0
    var conflicts: [String] = []
    var errors: [String] = []
    var totalCount: Int { createCount + updateCount + unchangedCount }
}

struct CalendarSyncReport: CustomStringConvertible {
    var savedCount = 0
    var removedCount = 0
    var skippedCount = 0
    var managedCount = 0
    var coveredIDs: Set<String> = []
    var conflicts: [String] = []
    var errors: [String] = []
    var summary: String {
        if let error = errors.first { return "同步未完成：\(error)" }
        let base = removedCount > 0 ? "已移除 \(removedCount) 次课程，保留 \(managedCount) 次" : "日历中已核对 \(managedCount) 次课程"
        return conflicts.isEmpty ? base : base + "，\(conflicts.count) 项日历改动已保留"
    }
    var description: String { summary }
}

/// EventKit lookups scale with every exported lesson, so all of them run on this
/// actor instead of the main thread. EKEvent objects never leave the actor.
actor CalendarSyncService {
    static let shared = CalendarSyncService()
    nonisolated let deviceIdentifier: String
    private let eventStore = EKEventStore()
    private let verificationStore = EKEventStore()
    private var ledger: CalendarLedger
    private let ledgerURL: URL
    private var isSyncing = false

    nonisolated var hasFullAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func hasExport(for semester: Semester) -> Bool {
        ledger.calendarIDs[semester.id.uuidString] != nil || (hasFullAccess && ownedCalendar(for: semester) != nil)
    }

    nonisolated func isOwnedByAnotherDevice(_ semester: Semester) -> Bool {
        if let owner = semester.calendarOwnerDeviceID { return owner != deviceIdentifier }
        return false
    }

    private init() {
        deviceIdentifier = CalendarDeviceIdentity.load()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CourseFlow", isDirectory: true)
        ledgerURL = directory.appendingPathComponent("calendar-ledger.json")
        if let data = try? Data(contentsOf: ledgerURL), let stored = try? JSONDecoder().decode(CalendarLedger.self, from: data) {
            ledger = stored
        } else { ledger = CalendarLedger() }
    }

    func requestAccess() async throws -> Bool {
        if hasFullAccess { return true }
        return try await eventStore.requestFullAccessToEvents()
    }

    func hasManagedEvents(for semester: Semester) -> Bool { !verify(semester: semester).managed.isEmpty }

    /// Calendar presence is not reminder coverage. Respect the current lesson time
    /// and alarm, including edits made outside the app, before suppressing an app alert.
    func coveredIDs(for semester: Semester, occurrences: [Occurrence]? = nil, defaultLeadMinutes: Int = 10) -> Set<String> {
        verify(semester: semester, occurrences: occurrences, defaultLeadMinutes: defaultLeadMinutes).covered
    }

    /// One pass over the ledger: each record is looked up in EventKit only once.
    private func verify(semester: Semester, occurrences: [Occurrence]? = nil, defaultLeadMinutes: Int = 10) -> (managed: Set<String>, covered: Set<String>) {
        guard hasFullAccess else { return ([], []) }
        verificationStore.reset()
        let planned = occurrences.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        var managed = Set<String>(), covered = Set<String>()
        for record in ledger.records.values where record.semesterID == semester.id.uuidString {
            guard let event = findEvent(record, in: verificationStore),
                  occurrenceID(of: event, semester: semester) == record.occurrenceID else { continue }
            managed.insert(record.occurrenceID)
            if isCovered(record, event: event, planned: planned, defaultLeadMinutes: defaultLeadMinutes) { covered.insert(record.occurrenceID) }
        }
        return (managed, covered)
    }

    private func isCovered(_ record: CalendarRecord, event: EKEvent, planned: [String: Occurrence]?, defaultLeadMinutes: Int) -> Bool {
        guard !event.isAllDay else { return false }
        let start: Date
        let end: Date
        let offset: TimeInterval
        if let planned {
            guard let occurrence = planned[record.occurrenceID] else { return false }
            let lead = occurrence.reminderMinutes ?? defaultLeadMinutes
            guard lead >= 0 else { return false }
            start = occurrence.start; end = occurrence.end; offset = -Double(lead) * 60
        } else {
            guard let storedStart = record.plannedStart, let storedEnd = record.plannedEnd,
                  let storedOffset = record.plannedAlarmOffset else { return false }
            start = storedStart; end = storedEnd; offset = storedOffset
        }
        guard let actualStart = event.startDate, let actualEnd = event.endDate,
              abs(actualStart.timeIntervalSince(start)) < 1, abs(actualEnd.timeIntervalSince(end)) < 1 else { return false }
        let expectedFire = start.addingTimeInterval(offset)
        return (event.alarms ?? []).contains { alarm in
            if let absolute = alarm.absoluteDate { return abs(absolute.timeIntervalSince(expectedFire)) < 1 }
            return abs(alarm.relativeOffset - offset) < 1
        }
    }

    func preview(semester: Semester, occurrences: [Occurrence], defaultLeadMinutes: Int = 10) -> CalendarSyncPreview {
        guard hasFullAccess else {
            return CalendarSyncPreview(createCount: validOccurrences(occurrences, semester: semester).count)
        }
        guard !isSyncing else { return CalendarSyncPreview(hasFullAccess: true, errors: ["正在同步，请稍候。"] ) }
        eventStore.reset()
        let calendar = ownedCalendar(for: semester)
        if calendar == nil {
            let candidates = markedCalendars(for: semester)
            if candidates.count > 1 { return CalendarSyncPreview(hasFullAccess: true, errors: [CalendarSyncError.ambiguousCalendars.localizedDescription]) }
            if !candidates.isEmpty { return CalendarSyncPreview(hasFullAccess: true, errors: [CalendarSyncError.unrecognizedCalendar.localizedDescription]) }
        }
        let plan = makePlan(semester: semester, occurrences: occurrences, defaultLeadMinutes: defaultLeadMinutes, calendar: calendar)
        return CalendarSyncPreview(hasFullAccess: true, calendarName: calendar?.title,
                                   createCount: plan.create.count, updateCount: plan.update.count,
                                   removeCount: plan.remove.count, unchangedCount: plan.unchanged.count,
                                   conflicts: plan.conflicts)
    }

    func sync(semester: Semester, occurrences: [Occurrence], defaultLeadMinutes: Int = 10) async -> CalendarSyncReport {
        guard !isOwnedByAnotherDevice(semester) else {
            return CalendarSyncReport(errors: ["这个学期由另一台设备管理日历。请在设置中明确接管后再同步，避免多台设备重复写入。"])
        }
        guard !isSyncing else { return CalendarSyncReport(errors: ["正在同步，请稍候。"] ) }
        isSyncing = true
        defer { isSyncing = false }
        do {
            guard try await requestAccess() else { return CalendarSyncReport(errors: ["需要完整日历访问权限，才能更新与撤销已添加的课程。"] ) }
            eventStore.reset()
            let calendar = try obtainCalendar(for: semester)
            let plan = makePlan(semester: semester, occurrences: occurrences, defaultLeadMinutes: defaultLeadMinutes, calendar: calendar)
            var report = CalendarSyncReport(skippedCount: plan.conflicts.count, conflicts: plan.conflicts)
            var saved: [(Occurrence, EKEvent)] = []
            do {
                for occurrence in plan.create {
                    let event = EKEvent(eventStore: eventStore)
                    configure(event, from: occurrence, semester: semester, calendar: calendar, defaultLeadMinutes: defaultLeadMinutes)
                    try eventStore.save(event, span: .thisEvent, commit: false)
                    saved.append((occurrence, event))
                }
                for (occurrence, event) in plan.update {
                    configure(event, from: occurrence, semester: semester, calendar: calendar, defaultLeadMinutes: defaultLeadMinutes)
                    try eventStore.save(event, span: .thisEvent, commit: false)
                    saved.append((occurrence, event))
                }
                for (_, event) in plan.remove { try eventStore.remove(event, span: .thisEvent, commit: false) }
                if !saved.isEmpty || !plan.remove.isEmpty { try eventStore.commit() }
            } catch {
                eventStore.reset()
                report.coveredIDs = coveredIDs(for: semester, occurrences: occurrences, defaultLeadMinutes: defaultLeadMinutes)
                report.errors.append("日历写入未完成：\(error.localizedDescription)。可以安全重试。")
                return report
            }
            for (id, _) in plan.remove { ledger.records.removeValue(forKey: id) }
            report.removedCount = plan.remove.count
            for (occurrence, event) in saved + plan.unchanged {
                // A successful save is verified through the event store before claiming coverage.
                guard let committed = eventStore.calendarItem(withIdentifier: event.calendarItemIdentifier) as? EKEvent,
                      occurrenceID(of: committed, semester: semester) == occurrence.id else {
                    report.errors.append("\(occurrence.courseName) 已提交，但暂时未能核验；再次同步时会按标识检查。")
                    continue
                }
                ledger.records[occurrence.id] = record(for: committed, occurrence: occurrence, semester: semester, defaultLeadMinutes: defaultLeadMinutes)
            }
            report.savedCount = saved.count
            do { try persistLedger() }
            catch { report.errors.append("日历已写入，本机同步记录保存失败：\(error.localizedDescription)") }
            (report.managedCount, report.coveredIDs) = verificationCounts(semester: semester, occurrences: occurrences, defaultLeadMinutes: defaultLeadMinutes)
            return report
        } catch {
            eventStore.reset()
            return CalendarSyncReport(coveredIDs: coveredIDs(for: semester), errors: [error.localizedDescription])
        }
    }

    private func verificationCounts(semester: Semester, occurrences: [Occurrence]? = nil, defaultLeadMinutes: Int = 10) -> (Int, Set<String>) {
        let result = verify(semester: semester, occurrences: occurrences, defaultLeadMinutes: defaultLeadMinutes)
        return (result.managed.count, result.covered)
    }

    /// Removes only unchanged events that still carry this app's ownership marker.
    func remove(semester: Semester) async -> CalendarSyncReport {
        guard !isOwnedByAnotherDevice(semester) else {
            return CalendarSyncReport(errors: ["这个学期由另一台设备管理日历，请在该设备移除，或先明确接管。"])
        }
        guard !isSyncing else { return CalendarSyncReport(errors: ["正在同步，请稍候。"] ) }
        isSyncing = true
        defer { isSyncing = false }
        do {
            guard try await requestAccess() else { return CalendarSyncReport(errors: ["日历访问未开启。"] ) }
            eventStore.reset()
            let calendar = ownedCalendar(for: semester)
            let plan = makePlan(semester: semester, occurrences: [], defaultLeadMinutes: 10, calendar: calendar)
            var report = CalendarSyncReport(skippedCount: plan.conflicts.count, conflicts: plan.conflicts)
            do {
                for (_, event) in plan.remove { try eventStore.remove(event, span: .thisEvent, commit: false) }
                if !plan.remove.isEmpty { try eventStore.commit() }
            } catch {
                eventStore.reset()
                return CalendarSyncReport(coveredIDs: coveredIDs(for: semester), conflicts: plan.conflicts,
                                          errors: ["移除未完成：\(error.localizedDescription)"])
            }
            for (id, _) in plan.remove { ledger.records.removeValue(forKey: id) }
            // Missing events no longer provide reminders and can be forgotten on explicit removal.
            for record in ledger.records.values where record.semesterID == semester.id.uuidString {
                if findEvent(record) == nil { ledger.records.removeValue(forKey: record.occurrenceID) }
            }
            report.removedCount = plan.remove.count
            do { try persistLedger() }
            catch { report.errors.append("课程已移除，同步记录保存失败：\(error.localizedDescription)") }
            (report.managedCount, report.coveredIDs) = verificationCounts(semester: semester)
            return report
        } catch { return CalendarSyncReport(coveredIDs: coveredIDs(for: semester), errors: [error.localizedDescription]) }
    }

    private func validOccurrences(_ occurrences: [Occurrence], semester: Semester) -> [Occurrence] {
        var seen = Set<String>()
        return occurrences.filter {
            $0.semesterID == semester.id && !$0.segments.isEmpty && $0.start < $0.end && seen.insert($0.id).inserted
        }.sorted { $0.start < $1.start }
    }

    private func makePlan(semester: Semester, occurrences: [Occurrence], defaultLeadMinutes: Int, calendar: EKCalendar?) -> SyncPlan {
        var plan = SyncPlan()
        let desired = validOccurrences(occurrences, semester: semester)
        let desiredIDs = Set(desired.map(\.id))
        var existing = [String: [EKEvent]]()
        let semesterRecords = ledger.records.values.filter { $0.semesterID == semester.id.uuidString }
        if let calendar {
            let termEnd = semester.calendar.date(byAdding: .weekOfYear, value: semester.weekCount, to: semester.firstMonday) ?? semester.firstMonday
            let start = min(semester.firstMonday, desired.map(\.start).min() ?? semester.firstMonday).addingTimeInterval(-86400)
            let end = max(termEnd, desired.map(\.end).max() ?? termEnd).addingTimeInterval(86400)
            let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: [calendar])
            for event in eventStore.events(matching: predicate) {
                if let id = occurrenceID(of: event, semester: semester) { existing[id, default: []].append(event) }
            }
        }
        // Identifier lookup also finds an event the user moved outside the semester or calendar.
        for record in semesterRecords {
            if let event = findEvent(record), occurrenceID(of: event, semester: semester) == record.occurrenceID {
                if !(existing[record.occurrenceID] ?? []).contains(where: { $0.calendarItemIdentifier == event.calendarItemIdentifier }) {
                    existing[record.occurrenceID, default: []].append(event)
                }
            }
        }
        for occurrence in desired {
            let events = existing[occurrence.id] ?? []
            if events.count > 1 {
                plan.conflicts.append("\(occurrence.courseName)：日历中有多个同标识事件，请在日历中整理后再同步。")
                continue
            }
            guard let event = events.first else {
                if ledger.records[occurrence.id] != nil {
                    plan.conflicts.append("\(occurrence.courseName)：已导出的事件被删除或不再归课序管理，已保留您的操作。")
                } else { plan.create.append(occurrence) }
                continue
            }
            guard let calendar else {
                plan.conflicts.append("\(occurrence.courseName)：原课表日历不可用。")
                continue
            }
            let proposed = EKEvent(eventStore: eventStore)
            configure(proposed, from: occurrence, semester: semester, calendar: calendar, defaultLeadMinutes: defaultLeadMinutes)
            let currentSignature = signature(of: event)
            if currentSignature == signature(of: proposed) {
                plan.unchanged.append((occurrence, event))
            } else if let record = ledger.records[occurrence.id], record.signature == currentSignature {
                plan.update.append((occurrence, event))
            } else {
                plan.conflicts.append("\(occurrence.courseName)：您在系统日历中改过此事件，本次不会覆盖。")
            }
        }
        for (id, events) in existing where !desiredIDs.contains(id) {
            guard events.count == 1, let event = events.first else {
                plan.conflicts.append("有重复的已导出课程，未自动删除。")
                continue
            }
            if let previous = ledger.records[id], previous.signature == signature(of: event) {
                plan.remove.append((id, event))
            } else {
                plan.conflicts.append("\(event.title ?? "课程")：日历事件有手动改动或缺少原始记录，未自动移除。")
            }
        }
        return plan
    }

    private func ownedCalendar(for semester: Semester) -> EKCalendar? {
        if let id = ledger.calendarIDs[semester.id.uuidString], let calendar = eventStore.calendar(withIdentifier: id) { return calendar }
        let matches = markedCalendars(for: semester)
        guard matches.count == 1, let candidate = matches.first,
              candidate.title.hasPrefix("课序 · ") || candidate.title.hasPrefix("课流 · ") else { return nil }
        return candidate
    }

    private func markedCalendars(for semester: Semester) -> [EKCalendar] {
        // Device takeover and account resyncs can lose local IDs. Recover only a
        // uniquely marked calendar; merely sharing a title never establishes ownership.
        let end = semester.calendar.date(byAdding: .weekOfYear, value: semester.weekCount, to: semester.firstMonday)
            ?? semester.firstMonday.addingTimeInterval(180 * 86400)
        let start = semester.calendar.date(byAdding: .year, value: -1, to: semester.firstMonday) ?? semester.firstMonday
        let extendedEnd = semester.calendar.date(byAdding: .year, value: 1, to: end) ?? end
        return eventStore.calendars(for: .event).filter { calendar in
            guard calendar.allowsContentModifications else { return false }
            let query = eventStore.predicateForEvents(withStart: start, end: extendedEnd, calendars: [calendar])
            return eventStore.events(matching: query).contains { occurrenceID(of: $0, semester: semester) != nil }
        }
    }

    private func obtainCalendar(for semester: Semester) throws -> EKCalendar {
        if let calendar = ownedCalendar(for: semester) {
            guard calendar.allowsContentModifications else { throw CalendarSyncError.readOnlyCalendar }
            if ledger.calendarIDs[semester.id.uuidString] != calendar.calendarIdentifier {
                ledger.calendarIDs[semester.id.uuidString] = calendar.calendarIdentifier
                try persistLedger()
            }
            return calendar
        }
        let marked = markedCalendars(for: semester)
        guard marked.count < 2 else { throw CalendarSyncError.ambiguousCalendars }
        guard marked.isEmpty else { throw CalendarSyncError.unrecognizedCalendar }
        // Never silently replace a vanished calendar: that could duplicate a remotely synced one.
        if ledger.calendarIDs[semester.id.uuidString] != nil, ledger.records.values.contains(where: { $0.semesterID == semester.id.uuidString }) {
            throw CalendarSyncError.missingCalendar
        }
        guard let source = eventStore.defaultCalendarForNewEvents?.source ?? eventStore.sources.first(where: { $0.sourceType == .local }) else {
            throw CalendarSyncError.noCalendarAccount
        }
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "课序 · \(semester.name)"
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        ledger.calendarIDs[semester.id.uuidString] = calendar.calendarIdentifier
        try persistLedger()
        return calendar
    }

    private func configure(_ event: EKEvent, from occurrence: Occurrence, semester: Semester,
                           calendar: EKCalendar, defaultLeadMinutes: Int) {
        event.calendar = calendar
        event.title = occurrence.courseName
        event.location = occurrence.location
        event.startDate = occurrence.start
        event.endDate = occurrence.end
        event.timeZone = TimeZone(identifier: semester.timeZoneID)
        event.isAllDay = false
        event.url = markerURL(semester: semester, occurrenceID: occurrence.id)
        var notes = ["由课序管理 · 第 \(occurrence.week) 周"]
        if !occurrence.teacher.isEmpty { notes.append("教师：\(occurrence.teacher)") }
        if occurrence.isException { notes.append("这是一节调整后的课程。") }
        notes.append("在课序中修改后，可重新同步更新此课程。")
        event.notes = notes.joined(separator: "\n")
        let lead = occurrence.reminderMinutes ?? defaultLeadMinutes
        event.alarms = lead >= 0 ? [EKAlarm(relativeOffset: -Double(lead) * 60)] : []
    }

    private func markerURL(semester: Semester, occurrenceID: String) -> URL? {
        let encoded = Data(occurrenceID.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "courseflow://calendar/\(semester.id.uuidString)/\(encoded)")
    }

    private func occurrenceID(of event: EKEvent, semester: Semester) -> String? {
        guard let url = event.url, url.scheme == "courseflow", url.host == "calendar",
              url.pathComponents.count == 3, url.pathComponents[1] == semester.id.uuidString else { return nil }
        var encoded = url.pathComponents[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func findEvent(_ record: CalendarRecord, in store: EKEventStore? = nil) -> EKEvent? {
        let source = store ?? eventStore
        return (source.calendarItem(withIdentifier: record.calendarItemIdentifier) as? EKEvent)
        ?? source.event(withIdentifier: record.eventIdentifier)
    }

    private func record(for event: EKEvent, occurrence: Occurrence, semester: Semester, defaultLeadMinutes: Int) -> CalendarRecord {
        let lead = occurrence.reminderMinutes ?? defaultLeadMinutes
        return CalendarRecord(occurrenceID: occurrence.id, semesterID: semester.id.uuidString,
                       eventIdentifier: event.eventIdentifier ?? "", calendarItemIdentifier: event.calendarItemIdentifier,
                       signature: signature(of: event), plannedStart: occurrence.start, plannedEnd: occurrence.end,
                       plannedAlarmOffset: lead >= 0 ? -Double(lead) * 60 : nil)
    }

    private func signature(of event: EKEvent) -> String {
        let value = EventSignature(title: event.title ?? "", location: event.location ?? "", notes: event.notes ?? "",
                                   start: event.startDate?.timeIntervalSince1970 ?? 0, end: event.endDate?.timeIntervalSince1970 ?? 0,
                                   timeZone: event.timeZone?.identifier ?? "", allDay: event.isAllDay,
                                   calendarID: event.calendar?.calendarIdentifier ?? "", url: event.url?.absoluteString ?? "",
                                   alarms: (event.alarms ?? []).map { $0.absoluteDate?.timeIntervalSince1970 ?? $0.relativeOffset }.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func persistLedger() throws {
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: ledgerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = ledgerURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

private struct SyncPlan {
    var create: [Occurrence] = []
    var update: [(Occurrence, EKEvent)] = []
    var remove: [(String, EKEvent)] = []
    var unchanged: [(Occurrence, EKEvent)] = []
    var conflicts: [String] = []
}

private struct CalendarLedger: Codable {
    var calendarIDs: [String: String] = [:]
    var records: [String: CalendarRecord] = [:]
}

private struct CalendarRecord: Codable {
    var occurrenceID: String
    var semesterID: String
    var eventIdentifier: String
    var calendarItemIdentifier: String
    var signature: String
    var plannedStart: Date?
    var plannedEnd: Date?
    var plannedAlarmOffset: TimeInterval?
}

private struct EventSignature: Codable {
    var title: String
    var location: String
    var notes: String
    var start: TimeInterval
    var end: TimeInterval
    var timeZone: String
    var allDay: Bool
    var calendarID: String
    var url: String
    var alarms: [Double]
}

private enum CalendarSyncError: LocalizedError {
    case readOnlyCalendar, missingCalendar, noCalendarAccount, ambiguousCalendars, unrecognizedCalendar
    var errorDescription: String? {
        switch self {
        case .readOnlyCalendar: "课表日历目前不可编辑，请检查日历账户。"
        case .missingCalendar: "原课表日历暂时不可用。请先检查系统日历账户，避免重复创建。"
        case .noCalendarAccount: "未找到可写入的日历账户，请先在系统日历中添加账户。"
        case .ambiguousCalendars: "多个日历中存在此学期的课序事件，未新建或覆盖。请先在系统日历中整理这些课程，再重试。"
        case .unrecognizedCalendar: "找到了本学期的课程，但所在日历已不再标识为专属课表日历。未向其他日历写入，请先检查原日历。"
        }
    }
}

private enum CalendarDeviceIdentity {
    static func load() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.courseflow.calendar-owner",
                                    kSecAttrAccount as String: "local-device",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let id = String(data: data, encoding: .utf8) { return id }
        let id = UserDefaults.standard.string(forKey: "courseflow.calendarDeviceID") ?? UUID().uuidString
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "com.courseflow.calendar-owner",
                                  kSecAttrAccount as String: "local-device",
                                  kSecValueData as String: Data(id.utf8),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  kSecAttrSynchronizable as String: false]
        SecItemAdd(item as CFDictionary, nil)
        UserDefaults.standard.set(id, forKey: "courseflow.calendarDeviceID")
        return id
    }
}
