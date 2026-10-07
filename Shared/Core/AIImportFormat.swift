import Foundation
import CoreFoundation

/// A versioned data exchange format. Pasted content is decoded as JSON and never executed.
public enum AIImportFormat {
    public static let maximumBytes = 1_048_576

    public struct FormatError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    public static let exampleTimetable = #"""
    {
      "format": "courseflow.ai",
      "version": 1,
      "kind": "timetable",
      "sourceName": "我的课表",
      "lessons": [
        {"name": "示例课程（请替换）", "weekday": 1, "weeks": "1-8周", "periods": "1-2", "start": null, "end": null, "location": "示例教室（请替换）", "teacher": null, "source": "图片1，星期一，第1-2节；原文：示例课程", "warnings": []}
      ],
      "periods": [],
      "warnings": []
    }
    """#

    public static func prompt(kind: ImportKind, maxWeeks: Int) -> String {
        let purpose = kind == .timetable ? "大学课程表" : "学校作息表（每节课的起止时间）"
        let example = kind == .timetable ? exampleTimetable : #"""
        {"format":"courseflow.ai","version":1,"kind":"bellSchedule","sourceName":"我的学校作息","lessons":[],"periods":[{"number":1,"start":"08:00","end":"08:45"}],"warnings":[]}
        """#
        let modeRules = kind == .timetable ? """
        本次只输出课程：kind 必须是 "timetable"，lessons 包含所有上课安排，顶层 periods 必须为 []。
        同一课程在不同星期、不同周次、不同地点或教师有多个安排时，拆为多条 lessons；同一格有多门课程也分别输出。不要把同格的多门课程拼成一个课程名。
        每条 lesson 的字段：name（课程名，字符串或 null）、weekday（周一=1 至周日=7 的整数或 null）、weeks（如 "1-8周"、"1-16单周，排除7周"、"1-8,10-16周"，或 null）、periods（如 "1-2"、"1,3-4"，或 null）、start / end（"HH:mm" 或 null）、location / teacher（字符串或 null）、source（图片编号、行列位置及对应原文）、warnings（字符串数组）。
        图片有明确节次时保留节次，start 和 end 填 null，由 App 中用户确认的学校作息表提供各节时间，保留真实课间。不要将连堂课虚构成连续授课。只有没有节次且原图明确给出时钟时间时，才填写 start / end 并令 periods 为 null。
        不确定的课程信息保留该条记录，将不确定字段填 null，并在该条 warnings 写明待核对内容。不要自行默认星期、1-16周、整个学期或学校上课时间。仅有“单周 / 双周”但缺少范围时，weeks 填 null 并提示缺少周次范围。
        """ : """
        本次只输出作息：kind 必须是 "bellSchedule"，lessons 必须为 []，顶层 periods 包含每个明确的授课节次。
        每条 period 只能包含 number（第几节，1 至 40 的整数）、start（开始时间 "HH:mm"）、end（结束时间 "HH:mm"）。午休、课间和非授课活动不要当作节次。
        不要估计缺失时间、套用常见学校作息或平均分配连堂时间。不确定的节次必须在 warnings 中列出原因，并将该条缺失的 start / end 填 null；App 会要求补正这些缺失时间后再解析。不要为了生成有效结果而漏掉无法确认的节次。
        夏季、冬季或不同校区作息分别处理；如果图片有多个方案且无法确定目标，请先让我选择，不要混合为同一套作息。
        """
        return """
        请仔细阅读我随本提示词发送的图片，提取\(purpose)，生成可粘贴到「课序」App 的 JSON 数据。

        先核对表头、星期列、节次行、合并单元格的跨度、图例、页脚说明和周次条件，再逐格读取。跨行或跨列不一定代表多个独立课程，应按实际表头对应关系判断；必须识别同格不同课程与单双周交替安排。多张图片按内容汇总，重叠截图的同一记录只保留一次，来源矛盾写入 warnings，不要擅自选择。课程名称保留原文，不要翻译或扩写。

        \(modeRules)
        当前 App 学期设置为 \(maxWeeks) 周，这仅用于核对，不能用来补全图片未提供的周次。若图片明确写了超出该范围的周数，保留图片中的原值，在 warnings 提示我核对学期设置，不要截断周数。
        时间采用 24 小时制、冒号分隔；仅结束时刻可用 "24:00"。跨午夜的课程保留原图起止时间并在 warnings 提示需要在 App 中拆分核对，不要自行改变星期或周次。

        输出要求：只输出一个完整 JSON 对象，不输出 JavaScript / Python / Swift 代码，不输出注释、解释或省略号；最多 500 条课程或 40 个节次。根对象字段只能是 format、version、kind、sourceName、lessons、periods、warnings；format 必须为 "courseflow.ai"，version 必须为数字 1。未知值使用 JSON 的 null，warnings 没有问题时使用 []。sourceName 使用实际资料名称；若没写名称可填 "AI 图片识别"。资料模糊时明确说明并保留待核对信息，不要编造课程。

        下方仅演示 JSON 结构，所有示例课程、星期、周次、地点和时间都不能抄入识别结果。请用我发的图片内容替换：
        \(example)
        """
    }

    public static func parse(_ text: String, kind: ImportKind, maxWeeks: Int) throws -> ImportDraft {
        guard text.utf8.count <= maximumBytes else { throw FormatError("内容超过 1 MB，请让 AI 分批输出后分别导入。") }
        guard (1...60).contains(maxWeeks) else { throw FormatError("请先将学期总周数设置为 1 至 60 周，再解析 AI 结果。") }
        let json = try extractJSON(text)
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: []) }
        catch { throw FormatError("JSON 不完整或格式有误。请复制 AI 输出的完整 JSON（从 { 到 }），不要包含省略号、注释或可执行代码；也可让 AI 按提示词重新输出。") }
        guard let object = value as? [String: Any] else { throw FormatError("应粘贴一个完整 JSON 对象，不能只粘贴课程数组或其他代码。") }
        guard object["format"] as? String == "courseflow.ai" else { throw FormatError("导入格式不匹配：format 必须为 courseflow.ai。请复制本页提示词让 AI 重新生成。") }
        guard integer(object["version"]) == 1 else { throw FormatError("不支持此版本：version 必须为数字 1。请按本页提示词重新生成。") }
        guard let resultKind = object["kind"] as? String, resultKind == kind.rawValue else {
            throw FormatError("导入用途不匹配：当前选择的是\(kind == .timetable ? "课程表（timetable）" : "学校作息（bellSchedule）")。请切换用途，或让 AI 按对应提示词重新输出。")
        }
        guard let lessons = object["lessons"] as? [Any], let periods = object["periods"] as? [Any] else {
            throw FormatError("根对象必须包含 lessons 和 periods 两个数组；本次不用的数组请写 []。")
        }
        guard lessons.count <= 500 && periods.count <= 40 else { throw FormatError("一次最多导入 500 条课程或 40 个节次，请分批输出。") }
        guard kind == .timetable ? periods.isEmpty : lessons.isEmpty else {
            throw FormatError("一份数据不能混合课程与作息。课程表的顶层 periods 必须为 []；作息表的 lessons 必须为 []，请分别导入。")
        }
        guard kind == .timetable ? !lessons.isEmpty : !periods.isEmpty else { throw FormatError("这份数据没有\(kind == .timetable ? "课程" : "作息节次")，请核对图片内容和 AI 输出。") }
        var warnings = try stringArray(object["warnings"], field: "顶层 warnings")
        let unknown = Set(object.keys).subtracting(["format", "version", "kind", "sourceName", "lessons", "periods", "warnings"]).sorted()
        if !unknown.isEmpty { warnings.append("以下额外字段未应用，请对照原文核对：\(unknown.joined(separator: "、"))") }
        let name: String
        if isUnknown(object["sourceName"]) { name = "AI 图片识别" }
        else if let source = object["sourceName"] as? String { name = trim(source).isEmpty ? "AI 图片识别" : trim(source) }
        else { throw FormatError("sourceName 必须是资料名称字符串或 null。") }
        if kind == .timetable {
            let rows = try lessons.enumerated().map { index, value -> DraftLesson in
                guard let row = value as? [String: Any] else { throw FormatError("第 \(index + 1) 条课程必须是 JSON 对象，请让 AI 修正 lessons 数组。") }
                return parseLesson(row, maxWeeks: maxWeeks)
            }
            warnings.append("AI 结果已保存为待核对草稿；请对照图片确认课程、周次、地点及学校作息后保存。")
            return ImportDraft(kind: kind, sourceName: name, sourceText: text, lessons: rows, warnings: warnings)
        }
        var parsed: [Period] = []
        for (index, value) in periods.enumerated() {
            guard let row = value as? [String: Any], let number = integer(row["number"]), (1...40).contains(number),
                  let start = clock(row["start"], allowMidnight: false), let end = clock(row["end"], allowMidnight: true), start < end else {
                throw FormatError("第 \(index + 1) 条作息的节次或起止时间不完整/无效。编号须为 1 至 40，时间为 HH:mm，结束须晚于开始；请修正后再解析，跨午夜请拆分核对。")
            }
            guard !parsed.contains(where: { $0.number == number }) else { throw FormatError("作息中的第 \(number) 节重复，请核对是否混入了多套作息，再分别导入。") }
            let extra = Set(row.keys).subtracting(["number", "start", "end"]).sorted()
            if !extra.isEmpty { warnings.append("第 \(number) 节的额外字段未应用：\(extra.joined(separator: "、"))；请对照原文核对。") }
            parsed.append(Period(number: number, startMinute: start, endMinute: end))
        }
        let chronological = parsed.sorted { $0.startMinute < $1.startMinute }
        if zip(chronological, chronological.dropFirst()).contains(where: { $0.endMinute > $1.startMinute }) { warnings.append("作息中存在重叠时间，请在核对页修正后再确认。") }
        return ImportDraft(kind: kind, sourceName: name, sourceText: text, periods: parsed.sorted { $0.number < $1.number }, warnings: warnings)
    }

    private static func parseLesson(_ row: [String: Any], maxWeeks: Int) -> DraftLesson {
        var warnings: [String] = []
        if let parsed = try? stringArray(row["warnings"], field: "warnings") { warnings = parsed }
        else { warnings.append("warnings 应为文字数组，请对照本条原始 JSON 核对。") }
        func string(_ key: String, title: String) -> String {
            guard !isUnknown(row[key]) else { return "" }
            guard let value = row[key] as? String else { warnings.append("\(title)格式有误，请填写文字并对照原文核对。"); return "" }
            return trim(value)
        }
        let name = string("name", title: "课程名称")
        let location = string("location", title: "地点")
        let teacher = string("teacher", title: "教师")
        let source = string("source", title: "来源")
        let raw = (try? JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let sourceText = source.isEmpty ? raw : source + "\n\n原始 JSON：\n" + raw
        if name.isEmpty { warnings.append("课程名称缺失，请对照图片补全。") }
        let weekday = integer(row["weekday"]).flatMap { (1...7).contains($0) ? $0 : nil }
        if weekday == nil { warnings.append("星期缺失或无效，请选择星期一至星期日。") }
        let weeks = selection(row["weeks"], maximum: maxWeeks, title: "周次", warnings: &warnings) { try WeekSelection.parse($0, maxWeek: maxWeeks) }
        let periods = selection(row["periods"], maximum: 40, title: "节次", warnings: &warnings) { ImportParser.numbers($0, maximum: 40) }
        var start = clock(row["start"], allowMidnight: false)
        var end = clock(row["end"], allowMidnight: true)
        if !isUnknown(row["start"]) && start == nil { warnings.append("开始时间无效，请使用 HH:mm 并对照原文核对。") }
        if !isUnknown(row["end"]) && end == nil { warnings.append("结束时间无效，请使用 HH:mm（最晚 24:00）。") }
        // A stated period selection must never turn into one continuous clock range,
        // even if its value is malformed and needs manual correction.
        let hasPeriodInput = !isUnknown(row["periods"]) && !((row["periods"] as? String).map { trim($0).isEmpty } ?? (row["periods"] as? [Any]).map { $0.isEmpty } ?? false)
        if hasPeriodInput {
            if start != nil || end != nil { warnings.append("已优先保留节次，起止时间请以用户确认的学校作息为准；AI 提供的时钟时间保留在原文中。") }
            start = nil; end = nil
        } else if let from = start, let until = end, from >= until {
            warnings.append("结束不晚于开始，可能是跨午夜课程。请对照原文拆分为不同日期的安排；未自动改动星期或周次。")
            start = nil; end = nil
        }
        if periods.isEmpty && (start == nil || end == nil) { warnings.append("上课节次或起止时间不完整，请补全后确认。") }
        if weeks.isEmpty { warnings.append("周次尚未确认，请根据原图或学校信息补全；未默认整个学期。") }
        let extra = Set(row.keys).subtracting(["name", "weekday", "weeks", "periods", "start", "end", "location", "teacher", "source", "warnings"]).sorted()
        if !extra.isEmpty { warnings.append("本条额外字段未应用：\(extra.joined(separator: "、"))；请对照原文核对。") }
        return DraftLesson(name: name, weekday: weekday, weeks: weeks, periods: periods, startMinute: start, endMinute: end, location: location, teacher: teacher, sourceText: sourceText, warnings: warnings)
    }

    private static func selection(_ value: Any?, maximum: Int, title: String, warnings: inout [String], parse: (String) throws -> [Int]) -> [Int] {
        if isUnknown(value) { return [] }
        if let string = value as? String {
            if trim(string).isEmpty { return [] }
            let compact = (string.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? string).replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            // Limit numeric tokens before delegating to the general week parser,
            // whose range expansion expects ordinary human-sized numbers.
            if compact.range(of: #"[0-9零〇一二两三四五六七八九十]{4,}"#, options: .regularExpression) != nil {
                warnings.append("\(title)数字过长，请对照原文修正；未截断或猜测。"); return []
            }
            if compact.contains(where: { $0.isNumber && !"0123456789零〇一二两三四五六七八九十".contains($0) }) {
                warnings.append("\(title)包含无法识别的数字格式，请使用阿拉伯数字并对照原文核对。"); return []
            }
            // A parity-only expression does not disclose the actual teaching-week range.
            if title == "周次", string.range(of: #"[0-9０-９一二三四五六七八九十]"#, options: .regularExpression) == nil {
                warnings.append("周次缺少明确的数字范围，请根据原文补全；未默认整个学期。"); return []
            }
            if let result = try? parse(string), !result.isEmpty { return result }
        } else if let values = value as? [Any], !values.isEmpty {
            let numbers = values.compactMap(integer)
            if numbers.count == values.count && numbers.allSatisfy({ (1...maximum).contains($0) }) { return Set(numbers).sorted() }
        } else if let values = value as? [Any], values.isEmpty { return [] }
        warnings.append("\(title)无法完整解析或超出 1 至 \(maximum) 的范围，请对照原始 JSON 修正；未截断或猜测。")
        return []
    }

    private static func extractJSON(_ text: String) throws -> String {
        let clean = trim(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        guard !clean.isEmpty else { throw FormatError("请先粘贴 AI 生成的完整 JSON。") }
        if clean.hasPrefix("{") { return clean }
        let expression = try! NSRegularExpression(pattern: #"(?m)^[\t ]*```([^\r\n`]*)[\t ]*$"#)
        let fences = expression.matches(in: clean, range: NSRange(clean.startIndex..., in: clean))
        guard fences.count == 2, let opening = Range(fences[0].range, in: clean), let closing = Range(fences[1].range, in: clean),
              let languageRange = Range(fences[0].range(at: 1), in: clean), let endLanguage = Range(fences[1].range(at: 1), in: clean),
              ["", "json"].contains(trim(String(clean[languageRange])).lowercased()), trim(String(clean[endLanguage])).isEmpty else {
            throw FormatError("请粘贴纯 JSON，或仅包含一个 JSON 代码块的回复。多个代码块、可执行代码或缺失的结束标记无法确定要导入哪一份，请重新复制完整结果。")
        }
        return trim(String(clean[opening.upperBound..<closing.lowerBound]))
    }

    private static func stringArray(_ value: Any?, field: String) throws -> [String] {
        if isUnknown(value) { return [] }
        guard let strings = value as? [String] else { throw FormatError("\(field) 必须为文字数组，例如 [] 或 [\"请核对周次\"]。") }
        return strings.map(trim).filter { !$0.isEmpty }
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double >= Double(Int.min), double < Double(Int.max) else { return nil }
        return Int(double)
    }
    private static func clock(_ value: Any?, allowMidnight: Bool) -> Int? {
        guard let string = value as? String else { return nil }
        let text = trim(string)
        if allowMidnight && text == "24:00" { return 1440 }
        guard text.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return ImportParser.minute(text)
    }
    private static func isUnknown(_ value: Any?) -> Bool { value == nil || value is NSNull }
    private static func trim(_ string: String) -> String { string.trimmingCharacters(in: .whitespacesAndNewlines) }
}
