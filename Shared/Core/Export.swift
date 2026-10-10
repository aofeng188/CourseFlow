import Foundation

public enum BackupError: LocalizedError, Equatable {
    case unsupportedVersion(Int), invalid([String]), tooLarge
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let value): "此备份使用第 \(value) 版格式，当前 App 无法读取，请更新 App 后重试"
        case .invalid(let issues): "备份数据未通过验证：\n" + issues.joined(separator: "\n")
        case .tooLarge: "备份文件超过 20 MB，请检查是否选择了正确的文件"
        }
    }
}

public enum BackupCodec {
    public static let currentVersion = 2
    private struct Envelope: Codable {
        var format: String
        var version: Int
        var snapshot: ScheduleSnapshot
    }
    public static func encode(_ snapshot: ScheduleSnapshot) throws -> Data {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Foundation's reference-date numeric encoding retains full Date precision.
        var portable = snapshot
        for index in portable.semesters.indices { portable.semesters[index].calendarOwnerDeviceID = nil }
        return try encoder.encode(Envelope(format: "CourseKitBackup", version: currentVersion, snapshot: portable))
    }

    public static func decode(_ data: Data) throws -> ScheduleSnapshot {
        guard data.count <= 20 * 1024 * 1024 else { throw BackupError.tooLarge }
        struct Header: Decodable { var format: String; var version: Int }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.format == "CourseKitBackup" else { throw BackupError.invalid(["文件不是课程表备份"]) }
        guard (1...currentVersion).contains(header.version) else { throw BackupError.unsupportedVersion(header.version) }
        let envelope = try decoder.decode(Envelope.self, from: data)
        try validate(envelope.snapshot)
        return envelope.snapshot
    }

    public static func validate(_ snapshot: ScheduleSnapshot) throws {
        var issues: [String] = []
        func checkUnique<T: Identifiable>(_ values: [T], _ label: String) where T.ID: Hashable {
            if Set(values.map(\.id)).count != values.count { issues.append("\(label)包含重复标识") }
        }
        checkUnique(snapshot.semesters, "学期"); checkUnique(snapshot.bellSchedules, "作息表")
        checkUnique(snapshot.courses, "课程"); checkUnique(snapshot.rules, "上课安排")
        checkUnique(snapshot.exceptions, "例外安排"); checkUnique(snapshot.dayOverrides, "调休安排"); checkUnique(snapshot.holidayDecisions, "节假日决定")
        guard issues.isEmpty else { throw BackupError.invalid(issues) }
        let semesters = Dictionary(uniqueKeysWithValues: snapshot.semesters.map { ($0.id, $0) })
        let courses = Dictionary(uniqueKeysWithValues: snapshot.courses.map { ($0.id, $0) })
        let rules = Dictionary(uniqueKeysWithValues: snapshot.rules.map { ($0.id, $0) })
        for semester in snapshot.semesters {
            if semester.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("学期名称为空") }
            if !(1...60).contains(semester.weekCount) { issues.append("\(semester.name)：学期周数须为 1 至 60") }
            if TimeZone(identifier: semester.timeZoneID) == nil { issues.append("\(semester.name)：学校时区无效") }
            if !validDate(semester.firstMonday) || semester.calendar.component(.weekday, from: semester.firstMonday) != 2 { issues.append("\(semester.name)：第一周起始日期必须是周一") }
        }
        // Reject invalid temporal roots before using their calendars to validate children.
        guard issues.isEmpty else { throw BackupError.invalid(issues) }
        var bellDates: Set<String> = []
        for bell in snapshot.bellSchedules {
            guard let semester = semesters[bell.semesterID] else { issues.append("作息表关联的学期不存在"); continue }
            if !validDate(bell.effectiveFrom) { issues.append("作息表生效日期无效") }
            if bell.isConfirmed || !bell.periods.isEmpty { issues += DraftValidator.issues(for: bell).map { "\(bell.name)：\($0)" } }
            let key = "\(semester.id)-\(semester.calendar.startOfDay(for: bell.effectiveFrom).timeIntervalSinceReferenceDate)"
            if !bellDates.insert(key).inserted { issues.append("同一学期不能有相同生效日期的两份作息表") }
        }
        for course in snapshot.courses {
            if semesters[course.semesterID] == nil { issues.append("课程“\(course.name)”关联的学期不存在") }
            if course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("课程名称为空") }
            if course.colorIndex < 0 { issues.append("\(course.name)：课程颜色编号无效") }
            if let lead = course.reminderMinutes, !(-1...10080).contains(lead) { issues.append("\(course.name)：提醒提前量无效") }
            if let avatar = course.avatar, (avatar.text?.count ?? 0) > CourseAvatarStyle.maxTextLength || (avatar.image?.count ?? 0) > CourseAvatarStyle.maxImageBytes { issues.append("\(course.name)：课程头像的文字过长或图片过大") }
        }
        for rule in snapshot.rules {
            guard let course = courses[rule.courseID], let semester = semesters[course.semesterID] else { issues.append("上课安排关联的课程不存在"); continue }
            let draft = DraftLesson(name: course.name, weekday: rule.weekday, weeks: rule.weeks, periods: rule.periodNumbers, startMinute: rule.startMinute, endMinute: rule.endMinute, location: rule.location, teacher: rule.teacher)
            issues += DraftValidator.issues(for: draft, semester: semester, bellSchedules: snapshot.bellSchedules).map { "\(course.name)：\($0)" }
            if Set(rule.weeks).count != rule.weeks.count || Set(rule.periodNumbers).count != rule.periodNumbers.count { issues.append("\(course.name)：周数或节次存在重复") }
        }
        var overrideDates: Set<String> = []
        for change in snapshot.dayOverrides {
            guard let semester = semesters[change.semesterID] else { issues.append("调休安排关联的学期不存在"); continue }
            guard validDate(change.date), validDate(change.followsDate) else { issues.append("调休日期无效"); continue }
            let week = ScheduleEngine.weekNumber(on: change.followsDate, semester: semester)
            if !(1...max(1, semester.weekCount)).contains(week) { issues.append("调休参照日期必须属于当前学期") }
            let key = "\(semester.id)-\(semester.calendar.startOfDay(for: change.date).timeIntervalSinceReferenceDate)"
            if !overrideDates.insert(key).inserted { issues.append("同一天存在重复的调休安排") }
            issues += DraftValidator.issues(for: change, snapshot: snapshot)
        }
        var decisionDates: Set<String> = []
        for decision in snapshot.holidayDecisions {
            guard let semester = semesters[decision.semesterID] else { issues.append("节假日决定关联的学期不存在"); continue }
            guard validDate(decision.date) else { issues.append("节假日决定日期无效"); continue }
            let week = ScheduleEngine.weekNumber(on: decision.date, semester: semester)
            if !(1...semester.weekCount).contains(week) { issues.append("节假日决定必须属于当前学期") }
            let key = "\(semester.id)-\(semester.calendar.startOfDay(for: decision.date).timeIntervalSinceReferenceDate)"
            if !decisionDates.insert(key).inserted { issues.append("同一天存在重复的节假日决定") }
        }
        var exceptionDates: Set<String> = []
        for change in snapshot.exceptions {
            guard let rule = rules[change.ruleID], let course = courses[rule.courseID], let semester = semesters[course.semesterID] else { issues.append("例外安排关联的课程或上课安排不存在"); continue }
            guard validDate(change.originalDate), change.replacementDate.map(validDate) ?? true else { issues.append("例外安排日期无效"); continue }
            if change.startMinute != nil || change.endMinute != nil {
                if !DraftValidator.validTimeRange(start: change.startMinute, end: change.endMinute) { issues.append("\(course.name)：例外安排的起止时间无效") }
            }
            if change.kind != .added {
                let key = "\(rule.id)-\(semester.calendar.startOfDay(for: change.originalDate).timeIntervalSinceReferenceDate)"
                if !exceptionDates.insert(key).inserted { issues.append("同一次上课存在重复的调停课安排") }
            }
            if change.kind != .cancelled && change.startMinute == nil && rule.startMinute == nil {
                let destination = change.replacementDate ?? change.originalDate
                guard let bell = ScheduleEngine.bellSchedule(on: destination, semester: semester, schedules: snapshot.bellSchedules), rule.periodNumbers.allSatisfy({ number in bell.periods.contains { $0.number == number } }) else {
                    issues.append("\(course.name)：例外安排日期缺少有效作息表"); continue
                }
            }
        }
        if !issues.isEmpty { throw BackupError.invalid(Array(Set(issues)).sorted()) }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && (-62_135_596_800...253_402_214_400).contains(date.timeIntervalSince1970)
    }
}

public enum ICSExporter {
    public static func export(occurrences: [Occurrence], semester: Semester, generatedAt: Date = .now, defaultLeadMinutes: Int = 10) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//CourseKit//University Timetable//ZH", "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:\(escape(semester.name))", "X-WR-TIMEZONE:\(escape(semester.timeZoneID))"]
        var exported: Set<String> = []
        for item in occurrences.filter({ $0.semesterID == semester.id && !$0.segments.isEmpty }).sorted(by: { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }) {
            guard exported.insert(item.id).inserted else { continue }
            var detail = "\(semester.name) · 第 \(item.week) 周"
            if !item.teacher.isEmpty { detail += "\n教师：\(item.teacher)" }
            if item.segments.count > 1 {
                let times = item.segments.map { segment in
                    let start = semester.calendar.dateComponents([.hour, .minute], from: segment.start)
                    let end = semester.calendar.dateComponents([.hour, .minute], from: segment.end)
                    return "\(segment.periodNumber.map { "第 \($0) 节 " } ?? "")\(Period.clock((start.hour ?? 0) * 60 + (start.minute ?? 0)))-\(Period.clock((end.hour ?? 0) * 60 + (end.minute ?? 0)))"
                }.joined(separator: "\n")
                detail += "\n\(times)"
            }
            lines += ["BEGIN:VEVENT", "UID:\(escape(item.id))@coursekit.local", "DTSTAMP:\(stamp(generatedAt))", "DTSTART:\(stamp(item.start))", "DTEND:\(stamp(item.end))", "SUMMARY:\(escape(item.courseName))", "LOCATION:\(escape(item.location))", "DESCRIPTION:\(escape(detail))", "TRANSP:OPAQUE"]
            let lead = item.reminderMinutes ?? defaultLeadMinutes
            if lead >= 0 { lines += ["BEGIN:VALARM", "TRIGGER:-PT\(lead)M", "ACTION:DISPLAY", "DESCRIPTION:\(escape(item.courseName))", "END:VALARM"] }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
    }
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
    private static func fold(_ line: String) -> String {
        var result = "", bytes = 0
        for scalar in line.unicodeScalars {
            let value = String(scalar), count = value.utf8.count
            if bytes + count > 75 { result += "\r\n "; bytes = 1 }
            result += value; bytes += count
        }
        return result
    }
}
