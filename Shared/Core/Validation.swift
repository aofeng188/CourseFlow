import Foundation

public enum WeekSelectionError: LocalizedError, Equatable {
    case empty, invalid(String), outOfRange(Int), noWeeks
    public var errorDescription: String? {
        switch self {
        case .empty: "请输入上课周数，例如 1-16周、1-16周(单)、1-8,10-16"
        case .invalid(let value): "无法识别周数“\(value)”，请使用范围、单双周或逗号分隔的周数"
        case .outOfRange(let max): "周数须在第 1 至第 \(max) 周之间"
        case .noWeeks: "所选规则没有包含任何上课周"
        }
    }
}

public enum WeekSelection {
    public static func parse(_ text: String, maxWeek: Int) throws -> [Int] {
        guard (1...60).contains(maxWeek) else { throw WeekSelectionError.outOfRange(maxWeek) }
        var value = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        value = value.lowercased().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard !value.isEmpty else { throw WeekSelectionError.empty }
        value = replaceChineseNumbers(in: value)
        for separator in ["，", "、", "､", ";", "；", "/"] { value = value.replacingOccurrences(of: separator, with: ",") }
        for separator in ["—", "–", "－", "~", "～", "至", "到"] { value = value.replacingOccurrences(of: separator, with: "-") }
        for word in ["排除", "不包含", "不含", "除了", "除"] { value = value.replacingOccurrences(of: word, with: "!") }
        let pieces = value.split(separator: "!", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { throw WeekSelectionError.invalid(text) }
        let base = String(pieces[0]).trimmingCharacters(in: CharacterSet(charactersIn: ","))
        var result = try parsePositive(base, maxWeek: maxWeek)
        if pieces.count == 2 {
            let excluded = String(pieces[1]).replacingOccurrences(of: "外", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ","))
            result.subtract(try parsePositive(excluded, maxWeek: maxWeek))
        }
        guard !result.isEmpty else { throw WeekSelectionError.noWeeks }
        return result.sorted()
    }

    public static func summary(_ weeks: [Int]) -> String {
        let values = Set(weeks.filter { $0 > 0 }).sorted()
        guard let first = values.first, let last = values.last else { return "未设置周数" }
        if values.count == 1 { return "第 \(first) 周" }
        if values.count >= 3 && zip(values, values.dropFirst()).allSatisfy({ $1 - $0 == 2 }) {
            return "\(first)-\(last) 周（\(first.isMultiple(of: 2) ? "双" : "单")）"
        }
        var ranges: [String] = []
        var start = first, end = first
        for value in values.dropFirst() {
            if value == end + 1 { end = value }
            else { ranges.append(start == end ? "\(start)" : "\(start)-\(end)"); start = value; end = value }
        }
        ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
        return ranges.joined(separator: ",") + " 周"
    }

    private static func parsePositive(_ input: String, maxWeek: Int) throws -> Set<Int> {
        var result: Set<Int> = []
        guard !input.isEmpty else { throw WeekSelectionError.empty }
        for rawPart in input.split(separator: ",", omittingEmptySubsequences: false) {
            var part = String(rawPart)
            guard !part.isEmpty else { throw WeekSelectionError.invalid(input) }
            for word in ["周数:", "周数", "第", "weeks", "week", "周", "(", ")", "[", "]"] { part = part.replacingOccurrences(of: word, with: "") }
            part = part.replacingOccurrences(of: "单双", with: "")
            let odd = part.contains("单"), even = part.contains("双")
            guard !(odd && even) else { throw WeekSelectionError.invalid(String(rawPart)) }
            part = part.replacingOccurrences(of: "单", with: "").replacingOccurrences(of: "双", with: "")
            let selected: [Int]
            if ["", "全部", "全", "每", "all"].contains(part) {
                guard odd || even || !part.isEmpty || String(rawPart).contains("单双") else { throw WeekSelectionError.invalid(String(rawPart)) }
                selected = Array(1...maxWeek)
            } else {
                let ends = part.split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(ends.count), let first = Int(ends[0]),
                      ends.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { throw WeekSelectionError.invalid(String(rawPart)) }
                let last = ends.count == 2 ? Int(ends[1])! : first
                guard (1...maxWeek).contains(first), (1...maxWeek).contains(last) else { throw WeekSelectionError.outOfRange(maxWeek) }
                guard first <= last else { throw WeekSelectionError.invalid(String(rawPart)) }
                selected = Array(first...last)
            }
            result.formUnion(selected.filter { (!odd || !$0.isMultiple(of: 2)) && (!even || $0.isMultiple(of: 2)) })
        }
        return result
    }

    private static func replaceChineseNumbers(in text: String) -> String {
        let regex = try! NSRegularExpression(pattern: "[零〇一二两三四五六七八九十]+")
        var result = text
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            let number: Int
            if let ten = token.firstIndex(of: "十") {
                let before = token[..<ten], after = token[token.index(after: ten)...]
                guard before.count <= 1, after.count <= 1 else { continue }
                number = (before.first.flatMap { digits[$0] } ?? 1) * 10 + (after.first.flatMap { digits[$0] } ?? 0)
            } else { number = token.reduce(0) { $0 * 10 + (digits[$1] ?? 0) } }
            result.replaceSubrange(range, with: String(number))
        }
        return result
    }
}

public enum DraftValidator {
    public static func issues(for lesson: DraftLesson, semester: Semester, bellSchedules: [BellSchedule]) -> [String] {
        var issues: [String] = []
        if lesson.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("请填写课程名称") }
        let validDay = lesson.weekday.map { (1...7).contains($0) } ?? false
        if !validDay { issues.append("请选择星期一至星期日") }
        if lesson.weeks.isEmpty { issues.append("请设置上课周数") }
        else if lesson.weeks.contains(where: { !(1...max(1, semester.weekCount)).contains($0) }) { issues.append("上课周数超出当前学期") }
        let hasExplicit = lesson.startMinute != nil || lesson.endMinute != nil
        if hasExplicit {
            if !lesson.periods.isEmpty { issues.append("请选择节次或具体起止时间，不要同时设置") }
            if !validTimeRange(start: lesson.startMinute, end: lesson.endMinute) { issues.append("请设置有效的起止时间，结束时间须晚于开始时间") }
        } else if lesson.periods.isEmpty { issues.append("请选择上课节次或填写具体起止时间") }
        else {
            if lesson.periods.contains(where: { $0 < 1 }) { issues.append("节次必须为正整数") }
            if validDay && !lesson.weeks.isEmpty {
                var missingSchedule = false, missingPeriods = false, invalidPeriods = false
                for week in lesson.weeks where (1...max(1, semester.weekCount)).contains(week) {
                    let date = ScheduleEngine.date(week: week, weekday: lesson.weekday!, semester: semester)
                    guard let bell = ScheduleEngine.bellSchedule(on: date, semester: semester, schedules: bellSchedules) else { missingSchedule = true; continue }
                    let selected = lesson.periods.compactMap { number in bell.periods.first { $0.number == number } }.sorted { $0.startMinute < $1.startMinute }
                    if selected.count != lesson.periods.count { missingPeriods = true }
                    if selected.contains(where: { !validTimeRange(start: $0.startMinute, end: $0.endMinute) }) || zip(selected, selected.dropFirst()).contains(where: { $0.endMinute > $1.startMinute }) { invalidPeriods = true }
                }
                if missingSchedule { issues.append("部分上课日期缺少已确认的学校作息表") }
                if missingPeriods { issues.append("学校作息表缺少所选节次，请补全后确认") }
                if invalidPeriods { issues.append("所选节次时间无效或相互重叠，请检查学校作息表") }
            }
        }
        return issues
    }

    public static func issues(for schedule: BellSchedule) -> [String] {
        var result: [String] = []
        if schedule.periods.isEmpty { result.append("请添加至少一个节次") }
        if Set(schedule.periods.map(\.number)).count != schedule.periods.count { result.append("节次编号不能重复") }
        if schedule.periods.contains(where: { $0.number < 1 || !validTimeRange(start: $0.startMinute, end: $0.endMinute) }) { result.append("节次编号或起止时间无效") }
        let sorted = schedule.periods.sorted { $0.startMinute < $1.startMinute }
        if zip(sorted, sorted.dropFirst()).contains(where: { $0.endMinute > $1.startMinute }) { result.append("各节次的上课时间不能重叠") }
        return result
    }

    public static func issues(for dayOverride: DayOverride, snapshot: ScheduleSnapshot) -> [String] {
        guard let semester = snapshot.semesters.first(where: { $0.id == dayOverride.semesterID }) else { return ["调休安排关联的学期不存在"] }
        guard dayOverride.date.timeIntervalSinceReferenceDate.isFinite, dayOverride.followsDate.timeIntervalSinceReferenceDate.isFinite else { return ["调休日期无效"] }
        let sourceWeek = ScheduleEngine.weekNumber(on: dayOverride.followsDate, semester: semester)
        guard (1...max(1, semester.weekCount)).contains(sourceWeek) else { return ["调休参照日期必须属于当前学期"] }
        let sourceDay = (semester.calendar.component(.weekday, from: dayOverride.followsDate) + 5) % 7 + 1
        let courses = snapshot.courses.filter { $0.semesterID == semester.id }
        let sourceRules = snapshot.rules.filter { rule in
            rule.weekday == sourceDay && rule.weeks.contains(sourceWeek) && courses.contains { $0.id == rule.courseID }
        }
        let bell = ScheduleEngine.bellSchedule(on: dayOverride.date, semester: semester, schedules: snapshot.bellSchedules)
        var result: [String] = []
        for rule in sourceRules where rule.startMinute == nil && !rule.periodNumbers.isEmpty {
            let name = courses.first { $0.id == rule.courseID }?.name ?? "课程"
            guard let bell else { result.append("调休课程“\(name)”缺少目标日期生效的已确认作息表，请先补全学校作息"); continue }
            let missing = Set(rule.periodNumbers).subtracting(bell.periods.map(\.number)).sorted()
            if !missing.isEmpty {
                result.append("调休课程“\(name)”需要第 \(missing.map(String.init).joined(separator: "、")) 节，但目标日期的学校作息缺少这些节次")
            }
            if !issues(for: bell).isEmpty { result.append("调休目标日期的学校作息时间无效，请先修正") }
        }
        return Array(Set(result)).sorted()
    }

    static func validTimeRange(start: Int?, end: Int?) -> Bool {
        guard let start, let end else { return false }
        return (0..<1440).contains(start) && (1...1440).contains(end) && start < end
    }
}
