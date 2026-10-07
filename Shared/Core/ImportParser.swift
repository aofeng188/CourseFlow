import Foundation

public enum ImportColumn: String, Codable, CaseIterable, Sendable, Identifiable {
    case ignore, name, weekday, weeks, periods, start, end, location, teacher
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ignore: "忽略"; case .name: "课程名称"; case .weekday: "星期"
        case .weeks: "周次"; case .periods: "节次"; case .start: "开始时间"
        case .end: "结束时间"; case .location: "地点"; case .teacher: "教师"
        }
    }
}

/// Zero-based coordinates; spans retain the structure of merged spreadsheet / OCR cells.
public struct ImportTableCell: Codable, Hashable, Sendable {
    public var text: String
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var columnSpan: Int
    public init(text: String, row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1) {
        self.text = text; self.row = row; self.column = column
        self.rowSpan = max(1, rowSpan); self.columnSpan = max(1, columnSpan)
    }
}

public enum ImportParser {
    /// A quoted CSV parser, including multiline cells and doubled quotes. TSV uses the same rules.
    public static func delimitedRows(_ text: String, delimiter: Character? = nil) -> [[String]] {
        let text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        let delimiter = delimiter ?? detectDelimiter(text)
        var rows = [[String]](), row = [String](), value = "", quoted = false
        var iterator = text.makeIterator(), next = iterator.next()
        while let char = next {
            next = iterator.next()
            if char == "\"" {
                if quoted, next == "\"" { value.append("\""); next = iterator.next() }
                else { quoted.toggle() }
            } else if char == delimiter, !quoted { row.append(value); value = "" }
            else if (char == "\n" || char == "\r" || char == "\r\n"), !quoted {
                if char == "\r", next == "\n" { next = iterator.next() }
                row.append(value)
                if row.contains(where: { !trim($0).isEmpty }) { rows.append(row) }
                row = []; value = ""
            } else { value.append(char) }
        }
        row.append(value)
        if row.contains(where: { !trim($0).isEmpty }) { rows.append(row) }
        return rows
    }

    public static func guessedMapping(_ headers: [String]) -> [ImportColumn] {
        headers.map { value in
            let value = trim(value).lowercased()
            if ["课程", "课程名称", "课程名", "科目", "name", "course", "course name"].contains(value) { return .name }
            if ["星期", "星期几", "上课星期", "weekday", "day"].contains(value) { return .weekday }
            if ["周次", "上课周次", "教学周", "weeks", "week"].contains(value) { return .weeks }
            if ["节次", "上课节次", "节数", "periods", "period"].contains(value) { return .periods }
            if value.contains("开始") || value == "start" { return .start }
            if value.contains("结束") || value == "end" { return .end }
            if ["地点", "上课地点", "教室", "location", "room"].contains(value) { return .location }
            if ["教师", "授课教师", "任课教师", "老师", "teacher"].contains(value) { return .teacher }
            return .ignore
        }
    }

    public static func table(_ rows: [[String]], kind: ImportKind = .timetable, mapping: [ImportColumn]? = nil, headerRow: Int = 0, sourceName: String = "表格", sourcePage: Int? = nil, maxWeeks: Int = 20) -> ImportDraft {
        let raw = rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        if kind == .bellSchedule { return text(raw, kind: kind, sourceName: sourceName, sourcePage: sourcePage, maxWeeks: maxWeeks) }
        guard rows.indices.contains(headerRow) else { return ImportDraft(sourceName: sourceName, sourceText: raw, warnings: ["表格没有可读取的数据"]) }
        let fields = mapping ?? guessedMapping(rows[headerRow])
        guard fields.contains(.name) else {
            let cells = rows.enumerated().flatMap { row, values in values.enumerated().map { ImportTableCell(text: $0.element, row: row, column: $0.offset) } }
            return grid(cells, sourceName: sourceName, sourcePage: sourcePage, maxWeeks: maxWeeks)
        }
        let lessons = rows.dropFirst(headerRow + 1).compactMap { row -> DraftLesson? in
            func value(_ column: ImportColumn) -> String {
                guard let index = fields.firstIndex(of: column), row.indices.contains(index) else { return "" }
                return trim(row[index])
            }
            if row.allSatisfy({ trim($0).isEmpty }) { return nil }
            var result = DraftLesson(name: value(.name), weekday: weekday(value(.weekday)), weeks: parseWeeks(value(.weeks), maxWeeks: maxWeeks), periods: numbers(value(.periods), maximum: 40), startMinute: spreadsheetMinute(value(.start)), endMinute: spreadsheetMinute(value(.end)), location: value(.location), teacher: value(.teacher), sourceText: row.joined(separator: " | "), sourcePage: sourcePage)
            if !value(.weeks).isEmpty && result.weeks.isEmpty { result.warnings.append("周次无法解析：\(value(.weeks))") }
            if !value(.periods).isEmpty && result.periods.isEmpty { result.warnings.append("节次无法解析：\(value(.periods))") }
            return result
        }
        return ImportDraft(sourceName: sourceName, sourceText: raw, lessons: lessons)
    }

    public static func grid(_ cells: [ImportTableCell], sourceName: String = "课表网格", sourcePage: Int? = nil, maxWeeks: Int = 20) -> ImportDraft {
        let raw = cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }.map { "[\($0.row + 1),\($0.column + 1)] \($0.text)" }.joined(separator: "\n")
        let headers = cells.filter { weekday($0.text) != nil && Int(trim($0.text)) == nil && trim($0.text).count < 14 }
        guard let headerRow = headers.map(\.row).min() else {
            var draft = text(cells.map(\.text).joined(separator: "\n\n"), sourceName: sourceName, sourcePage: sourcePage, maxWeeks: maxWeeks)
            draft.warnings.append("未识别到星期表头，请逐条补全星期与节次，或使用表格列映射。")
            return draft
        }
        var days: [Int: Int] = [:]
        for header in headers where header.row == headerRow {
            for column in header.column..<(header.column + header.columnSpan) { days[column] = weekday(header.text) }
        }
        let firstDayColumn = days.keys.min() ?? 1
        var rowPeriods: [Int: [Int]] = [:]
        for cell in cells where cell.column < firstDayColumn && cell.row > headerRow {
            let value = trim(cell.text)
            let parsed = numbers(value, maximum: 40)
            if !parsed.isEmpty && (value.contains("节") || value.range(of: #"^\d{1,2}(\s*[-–~、,]\s*\d{1,2})*$"#, options: .regularExpression) != nil) {
                for row in cell.row..<(cell.row + cell.rowSpan) { rowPeriods[row] = parsed }
            }
        }
        var lessons: [DraftLesson] = []
        for cell in cells where cell.row > headerRow && days[cell.column] != nil && !trim(cell.text).isEmpty {
            let periods = Array(Set((cell.row..<(cell.row + cell.rowSpan)).flatMap { rowPeriods[$0] ?? [] })).sorted()
            for block in courseBlocks(cell.text) {
                var lesson = lesson(block, sourcePage: sourcePage, maxWeeks: maxWeeks)
                lesson.weekday = days[cell.column]
                if lesson.periods.isEmpty { lesson.periods = periods }
                lessons.append(lesson)
            }
        }
        return ImportDraft(sourceName: sourceName, sourceText: raw, lessons: lessons, warnings: lessons.isEmpty ? ["网格中没有可识别的课程，请核对所选区域。"] : [])
    }

    /// Vision tables may be lists or weekly grids; preserve the distinction.
    public static func documentTable(_ cells: [ImportTableCell], kind: ImportKind = .timetable, sourceName: String = "表格识别", sourcePage: Int? = nil, maxWeeks: Int = 20) -> ImportDraft {
        let height = min(2000, (cells.map(\.row).max() ?? -1) + 1)
        let width = min(150, (cells.map(\.column).max() ?? -1) + 1)
        guard height > 0 && width > 0 else { return ImportDraft(kind: kind, sourceName: sourceName) }
        var rows = Array(repeating: Array(repeating: "", count: width), count: height)
        for cell in cells where rows.indices.contains(cell.row) && rows[cell.row].indices.contains(cell.column) { rows[cell.row][cell.column] = cell.text }
        if kind == .bellSchedule { return table(rows, kind: kind, sourceName: sourceName, sourcePage: sourcePage, maxWeeks: maxWeeks) }
        if let header = rows.prefix(20).firstIndex(where: { guessedMapping($0).contains(.name) }) {
            return table(rows, headerRow: header, sourceName: sourceName, sourcePage: sourcePage, maxWeeks: maxWeeks)
        }
        return grid(cells, sourceName: sourceName, sourcePage: sourcePage, maxWeeks: maxWeeks)
    }

    public static func text(_ text: String, kind: ImportKind = .timetable, sourceName: String = "粘贴文字", sourcePage: Int? = nil, maxWeeks: Int = 20) -> ImportDraft {
        if kind == .bellSchedule {
            let periods = periods(from: text)
            return ImportDraft(kind: kind, sourceName: sourceName, sourceText: text, periods: periods, warnings: periods.isEmpty ? ["没有找到节次与起止时间，请手动添加，或尝试更清晰的作息表。"] : [])
        }
        if text.contains("\t") {
            let rows = delimitedRows(text)
            if let headers = rows.first, guessedMapping(headers).contains(.name) {
                return table(rows, sourceName: sourceName, sourcePage: sourcePage, maxWeeks: maxWeeks)
            }
        }
        let blocks = courseBlocks(text)
        let lessons = blocks.filter { !trim($0).isEmpty }.map { lesson($0, sourcePage: sourcePage, maxWeeks: maxWeeks) }
        return ImportDraft(sourceName: sourceName, sourceText: text, lessons: lessons)
    }

    public static func periods(from text: String) -> [Period] {
        let pattern = #"(?:第\s*)?([0-9一二三四五六七八九十十一十二十三十四十五十六]{1,3})\s*(?:节|[\t ,、:：])[^\n\r]*?(\d{1,2})\s*[:：]\s*(\d{2})\s*(?:[-–—~～至]|\t|\s)+\s*(\d{1,2})\s*[:：]\s*(\d{2})"#
        return matches(pattern, in: text).compactMap { groups in
            guard groups.count == 6, let number = integer(groups[1]), let sh = Int(groups[2]), let sm = Int(groups[3]), let eh = Int(groups[4]), let em = Int(groups[5]), (1...40).contains(number), (0...23).contains(sh), (0...59).contains(sm), (0...23).contains(eh), (0...59).contains(em) else { return nil }
            return Period(number: number, startMinute: sh * 60 + sm, endMinute: eh * 60 + em)
        }.sorted { $0.number < $1.number }
    }

    public static func minute(_ text: String) -> Int? {
        guard let match = matches(#"(?:^|\s)(\d{1,2})\s*[:：]\s*(\d{2})(?:$|\s)"#, in: trim(text)).first,
              let hour = Int(match[1]), let minutes = Int(match[2]), (0...23).contains(hour), (0...59).contains(minutes) else { return nil }
        return hour * 60 + minutes
    }

    public static func weekday(_ text: String) -> Int? {
        let text = trim(text).lowercased()
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        for (offset, name) in names.enumerated() {
            if [name, "星期" + name, "周" + name, "礼拜" + name].contains(text) { return offset + 1 }
        }
        if ["天", "星期天", "周天", "礼拜天", "sunday", "sun"].contains(text) { return 7 }
        for prefix in ["星期", "周", "礼拜"] where text.hasPrefix(prefix) {
            if let number = Int(text.dropFirst(prefix.count)), (1...7).contains(number) { return number }
        }
        let english = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for (index, day) in english.enumerated() where text == day || text == String(day.prefix(3)) { return index + 1 }
        if let number = Int(text), (1...7).contains(number) { return number }
        return nil
    }

    public static func numbers(_ text: String, maximum: Int = 40) -> [Int] {
        var value = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        for token in ["第", "节", "[", "]", "(", ")"] { value = value.replacingOccurrences(of: token, with: "") }
        for separator in ["，", "、", "､", ";", "；", "/"] { value = value.replacingOccurrences(of: separator, with: ",") }
        for separator in ["–", "—", "~", "～", "至", "到"] { value = value.replacingOccurrences(of: separator, with: "-") }
        guard !value.isEmpty else { return [] }
        var result = Set<Int>()
        for token in value.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count), let lower = integer(String(bounds[0])), (1...maximum).contains(lower) else { return [] }
            guard let upper = bounds.count == 2 ? integer(String(bounds[1])) : lower, upper >= lower, upper <= maximum else { return [] }
            result.formUnion(lower...upper)
        }
        return result.sorted()
    }

    public static func parseWeeks(_ value: String, maxWeeks: Int) -> [Int] {
        if trim(value).isEmpty { return [] }
        return (try? WeekSelection.parse(value, maxWeek: maxWeeks)) ?? []
    }

    private static func lesson(_ raw: String, sourcePage: Int?, maxWeeks: Int) -> DraftLesson {
        let normalized = raw.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        var result = DraftLesson(sourceText: raw, sourcePage: sourcePage)
        if let value = matches(#"(?:星期|周|礼拜)[一二三四五六日天1-7]"#, in: normalized).first?.first { result.weekday = weekday(value) }
        // Whitespace may separate a clock from a week range; only explicit range/list
        // separators can join numbers, and clock minutes cannot begin a sequence.
        let sequence = #"\d+(?:\s*[-–—~～至到]\s*\d+)?(?:\s*[,，、]\s*\d+(?:\s*[-–—~～至到]\s*\d+)?)*"#
        let sequenceStart = #"(?<![\d:：,，、\-–—~～至到])(?:第\s*)?("# + sequence + #")"#
        if let value = matches(sequenceStart + #"\s*节"#, in: normalized).first { result.periods = numbers(value[1]) }
        if let value = matches(sequenceStart + #"\s*周\s*(?:[\(（]?([单双])[周\)）]?)?"#, in: normalized).first {
            result.weeks = parseWeeks(value[1] + (value.count > 2 ? value[2] : ""), maxWeeks: maxWeeks)
        }
        if let value = matches(#"(\d{1,2}[:：]\d{2})\s*[-–—~～至]\s*(\d{1,2}[:：]\d{2})"#, in: normalized).first { result.startMinute = minute(value[1]); result.endMinute = minute(value[2]) }
        result.teacher = capture(#"(?:教师|老师|授课教师)\s*[:：]\s*([^\n;；|]+?)(?=\s+(?:地点|教室|周次|星期|节次)\s*[:：]|$|\n|;|；|\|)"#, normalized)
        result.location = capture(#"(?:地点|教室|上课地点)\s*[:：]\s*([^\n;；|]+?)(?=\s+(?:教师|老师|周次|星期|节次)\s*[:：]|$|\n|;|；|\|)"#, normalized)
        let lines = normalized.components(separatedBy: .newlines).map(trim).filter { !$0.isEmpty }
        if let first = lines.first {
            result.name = first.replacingOccurrences(of: #"^(?:课程名称|课程|科目)\s*[:：]\s*"#, with: "", options: .regularExpression)
            if let range = result.name.range(of: #"\s+(?:星期|周[一二三四五六日天]|第?\d+\s*[-–—~～至]?\s*\d*\s*[节周]|\d{1,2}[:：]\d{2}|教师[:：]|地点[:：]|教室[:：])"#, options: .regularExpression) { result.name = String(result.name[..<range.lowerBound]) }
            result.name = trim(result.name)
        }
        if result.location.isEmpty {
            result.location = lines.dropFirst().first { $0.range(of: #"(?:楼|教室|实验室|体育馆|操场|[A-Za-z][\- ]?\d{2,4})"#, options: .regularExpression) != nil && !$0.contains("周") && !$0.contains("节") } ?? ""
        }
        return result
    }

    private static func courseBlocks(_ text: String) -> [String] {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blankBlocks = text.components(separatedBy: "\n\n").map(trim).filter { !$0.isEmpty }
        return blankBlocks.flatMap { block -> [String] in
            let lines = block.components(separatedBy: "\n")
            let independent = lines.filter { $0.range(of: #"(?:星期|周)[一二三四五六日天].*(?:节|\d{1,2}[:：]\d{2})"#, options: .regularExpression) != nil }
            return independent.count > 1 && independent.count == lines.filter({ !trim($0).isEmpty }).count ? lines : [block]
        }
    }

    private static func integer(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
        if let value = digits[text] { return value }
        if text.hasPrefix("十"), let value = digits[String(text.dropFirst())] { return 10 + value }
        if let index = text.firstIndex(of: "十") {
            let prefix = String(text[..<index]), suffix = String(text[text.index(after: index)...])
            if let tens = digits[prefix], suffix.isEmpty || digits[suffix] != nil { return tens * 10 + (digits[suffix] ?? 0) }
        }
        return nil
    }
    private static func spreadsheetMinute(_ value: String) -> Int? {
        if let clock = minute(value) { return clock }
        if let fractionalDay = Double(trim(value)), (0..<1).contains(fractionalDay) { return Int((fractionalDay * 1440).rounded()) }
        return nil
    }
    private static func detectDelimiter(_ text: String) -> Character {
        var quoted = false, counts: [Character: Int] = ["\t": 0, ",": 0, ";": 0]
        for character in text.prefix(4000) {
            if character == "\"" { quoted.toggle() }
            if !quoted {
                if character.isNewline { break }
                if counts[character] != nil { counts[character, default: 0] += 1 }
            }
        }
        var chosen: Character = ",", maximum = 0
        for candidate: Character in [",", "\t", ";"] where counts[candidate, default: 0] > maximum {
            chosen = candidate; maximum = counts[candidate, default: 0]
        }
        return chosen
    }
    private static func capture(_ pattern: String, _ text: String) -> String { matches(pattern, in: text).first.map { $0.count > 1 ? trim($0[1]) : "" } ?? "" }
    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
        }
    }
}
