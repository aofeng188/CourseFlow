import Foundation
import Testing
@testable import CourseKit

@Suite("外部 AI JSON 导入")
struct AIImportFormatTests {
    private func payload(_ lessons: [[String: Any]], kind: String = "timetable", periods: [[String: Any]] = [], extra: [String: Any] = [:]) throws -> String {
        var object: [String: Any] = ["format": "courseflow.ai", "version": 1, "kind": kind, "sourceName": "AI 图片课表", "lessons": lessons, "periods": periods, "warnings": ["请核对原图"]]
        object.merge(extra) { _, new in new }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    private var lesson: [String: Any] {
        ["name": "高等数学", "weekday": 1, "weeks": "1-8周", "periods": "1-2", "start": NSNull(), "end": NSNull(), "location": "东楼 A301", "teacher": "张老师", "source": "图片1，第1列、第1-2节", "warnings": []]
    }
    private func rejects(_ text: String, kind: ImportKind = .timetable, maxWeeks: Int = 20, mentioning phrase: String = "") {
        do {
            _ = try AIImportFormat.parse(text, kind: kind, maxWeeks: maxWeeks)
            Issue.record("应拒绝这份输入")
        } catch {
            #expect(error is AIImportFormat.FormatError)
            #expect(error.localizedDescription.contains(phrase))
        }
    }

    @Test func completeRecordRetainsMetadataAndUnknownTimes() throws {
        let text = try payload([lesson])
        let draft = try AIImportFormat.parse(text, kind: .timetable, maxWeeks: 20)
        let row = try #require(draft.lessons.first)
        #expect(draft.kind == .timetable)
        #expect(draft.sourceName == "AI 图片课表")
        #expect(draft.sourceText == text)
        #expect(draft.periods.isEmpty)
        #expect(row.name == "高等数学")
        #expect(row.weekday == 1)
        #expect(row.weeks == Array(1...8))
        #expect(row.periods == [1, 2])
        #expect(row.location == "东楼 A301")
        #expect(row.teacher == "张老师")
        #expect(row.sourceText.contains("图片1，第1列、第1-2节"))
        #expect(row.sourceText.contains("\"weekday\" : 1"))
        #expect(row.startMinute == nil && row.endMinute == nil)
        #expect(draft.warnings.contains("请核对原图"))
    }

    @Test func acceptsOneJSONFenceWithSurroundingProse() throws {
        let text = "这是识别结果，请核对。\n```json\n\(try payload([lesson]))\n```\n以上是全部课程。"
        let draft = try AIImportFormat.parse(text, kind: .timetable, maxWeeks: 20)
        #expect(draft.lessons.count == 1)
        #expect(draft.sourceText == text)
        #expect(try AIImportFormat.parse("\u{FEFF}  \n\(AIImportFormat.exampleTimetable)", kind: .timetable, maxWeeks: 20).lessons.count == 1)
    }

    @Test func rejectsAmbiguousOrUnterminatedFencesAndCode() throws {
        let json = try payload([lesson])
        rejects("```json\n\(json)\n```\n```json\n\(json)\n```", mentioning: "多个代码块")
        rejects("```json\n\(json)", mentioning: "结束标记")
        rejects("```javascript\n\(json)\n```", mentioning: "可执行代码")
        rejects("const courses = \(json)", mentioning: "可执行代码")
        rejects("{\"format\":\"courseflow.ai\",...}", mentioning: "JSON 不完整")
        rejects(String(json.dropLast(3)), mentioning: "JSON 不完整")
    }

    @Test func partialAndWrongTypedLessonFieldsRemainEditable() throws {
        let raw: [String: Any] = ["name": NSNull(), "weekday": "周一", "weeks": NSNull(), "periods": NSNull(), "start": "上午八点", "end": "25:10", "location": 301, "teacher": ["李老师"], "warnings": ["图片模糊"]]
        let draft = try AIImportFormat.parse(payload([lesson, raw]), kind: .timetable, maxWeeks: 20)
        #expect(draft.lessons.count == 2)
        let row = draft.lessons[1]
        #expect(row.name.isEmpty && row.location.isEmpty && row.teacher.isEmpty)
        #expect(row.weekday == nil && row.startMinute == nil && row.endMinute == nil)
        #expect(row.weeks.isEmpty && row.periods.isEmpty)
        #expect(row.warnings.contains("图片模糊"))
        #expect(row.warnings.contains { $0.contains("开始时间无效") })
        #expect(row.sourceText.contains("上午八点"))
        #expect(row.selected)
    }

    @Test func rejectsWrongEnvelopeWithoutDroppingRecords() throws {
        rejects(try payload([lesson], extra: ["format": "other"]), mentioning: "format")
        rejects(try payload([lesson], extra: ["version": 2]), mentioning: "version")
        rejects(try payload([lesson], extra: ["version": true]), mentioning: "version")
        rejects(try payload([lesson], extra: ["version": "1"]), mentioning: "version")
        rejects(try payload([lesson], kind: "bellSchedule"), mentioning: "用途不匹配")
        rejects(try payload([lesson], periods: [["number": 1, "start": "08:00", "end": "08:45"]]), mentioning: "不能混合")
        rejects(try payload([lesson], kind: "bellSchedule", periods: [["number": 1, "start": "08:00", "end": "08:45"]]), kind: .bellSchedule, mentioning: "不能混合")
        rejects(try payload([]), mentioning: "没有课程")
        rejects(try payload([lesson], extra: ["periods": NSNull()]), mentioning: "两个数组")
        rejects(try payload([lesson], extra: ["lessons": ["课程"]]), mentioning: "第 1 条课程")
    }

    @Test func malformedWarningsAndMetadataAreNotSilentlyAccepted() throws {
        rejects(try payload([lesson], extra: ["warnings": "不确定"]), mentioning: "warnings")
        rejects(try payload([lesson], extra: ["sourceName": 1]), mentioning: "sourceName")
        var row = lesson
        row["warnings"] = "图片模糊"
        row["roomBuilding"] = "旧楼"
        let draft = try AIImportFormat.parse(payload([row], extra: ["semester": "秋季"]), kind: .timetable, maxWeeks: 20)
        #expect(draft.warnings.contains { $0.contains("semester") })
        #expect(draft.lessons[0].warnings.contains { $0.contains("warnings 应为文字数组") })
        #expect(draft.lessons[0].warnings.contains { $0.contains("roomBuilding") })
        #expect(draft.lessons[0].sourceText.contains("图片模糊"))
    }

    @Test func explicitWeekPatternsAreExpandedWithoutTruncation() throws {
        var odd = lesson, discrete = lesson, invalid = lesson, invalidExcluded = lesson, vague = lesson
        odd["weeks"] = "1-16单周，排除7周"
        discrete["weeks"] = "1-8,10-16周"
        invalid["weeks"] = "1-88周"
        invalidExcluded["weeks"] = "1-16周，排除99周"
        vague["weeks"] = "单周"
        let rows = try AIImportFormat.parse(payload([odd, discrete, invalid, invalidExcluded, vague]), kind: .timetable, maxWeeks: 20).lessons
        #expect(rows[0].weeks == [1, 3, 5, 9, 11, 13, 15])
        #expect(rows[1].weeks == Array(1...8) + Array(10...16))
        #expect(rows[2].weeks.isEmpty && rows[3].weeks.isEmpty && rows[4].weeks.isEmpty)
        #expect(rows[2].warnings.contains { $0.contains("未截断") })
        #expect(rows[4].warnings.contains { $0.contains("明确的数字范围") })
    }

    @Test func numericArraysAreAtomicAndBooleansCannotBecomeNumbers() throws {
        var good = lesson, invalid = lesson, boolean = lesson
        good["weeks"] = [8, 2, 2, 4]
        good["periods"] = [3, 4]
        invalid["weeks"] = [1, 99]
        invalid["periods"] = [1, 100]
        boolean["weeks"] = [true, 2] as [Any]
        boolean["weekday"] = true
        boolean["periods"] = [1.5, 2]
        let rows = try AIImportFormat.parse(payload([good, invalid, boolean]), kind: .timetable, maxWeeks: 20).lessons
        #expect(rows[0].weeks == [2, 4, 8] && rows[0].periods == [3, 4])
        #expect(rows[1].weeks.isEmpty && rows[1].periods.isEmpty)
        #expect(rows[2].weekday == nil && rows[2].weeks.isEmpty && rows[2].periods.isEmpty)
    }

    @Test func oversizedNumberTokensCannotOverflowTheWeekParser() throws {
        var arabic = lesson, chinese = lesson, spaced = lesson, unicode = lesson, mixed = lesson
        arabic["weeks"] = "1-9999999999999999999999999999999999周"
        chinese["weeks"] = "一-九九九九九九九九九九九九九九九九九九周"
        spaced["weeks"] = "1-999 999 999 999 999 999 999 999 999周"
        unicode["weeks"] = "1-١٦周"
        mixed["weeks"] = "1-9九9九9九9九9九9九9九9九9九9九周"
        let rows = try AIImportFormat.parse(payload([arabic, chinese, spaced, unicode, mixed]), kind: .timetable, maxWeeks: 20).lessons
        #expect(rows.allSatisfy { $0.weeks.isEmpty })
        #expect(rows[0].warnings.contains { $0.contains("数字过长") })
        #expect(rows[3].warnings.contains { $0.contains("无法识别的数字格式") })
    }

    @Test func documentationFixturesMatchTheImportContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let timetable = try String(contentsOf: root.appendingPathComponent("Fixtures/ai-timetable.json"), encoding: .utf8)
        let bell = try String(contentsOf: root.appendingPathComponent("Fixtures/ai-bell-schedule.json"), encoding: .utf8)
        let courses = try AIImportFormat.parse(timetable, kind: .timetable, maxWeeks: 20)
        let schedule = try AIImportFormat.parse(bell, kind: .bellSchedule, maxWeeks: 20)
        #expect(courses.lessons.count == 4)
        #expect(!schedule.periods.isEmpty)
    }

    @Test func periodsTakePriorityEvenWhenPeriodInputNeedsCorrection() throws {
        var valid = lesson, invalid = lesson
        valid["start"] = "08:00"; valid["end"] = "09:40"
        invalid["start"] = "08:00"; invalid["end"] = "09:40"; invalid["periods"] = "1-99"
        let rows = try AIImportFormat.parse(payload([valid, invalid]), kind: .timetable, maxWeeks: 20).lessons
        #expect(rows[0].periods == [1, 2])
        #expect(rows.allSatisfy { $0.startMinute == nil && $0.endMinute == nil })
        #expect(rows[1].periods.isEmpty)
        #expect(rows[0].warnings.contains { $0.contains("优先保留节次") })
    }

    @Test func explicitClockSupportsMidnightEndButDoesNotGuessNextDate() throws {
        var direct = lesson, midnight = lesson, crossing = lesson
        for key in ["periods", "start", "end"] { direct[key] = NSNull(); midnight[key] = NSNull(); crossing[key] = NSNull() }
        direct["start"] = "00:00"; direct["end"] = "00:45"
        midnight["start"] = "23:15"; midnight["end"] = "24:00"
        crossing["start"] = "23:15"; crossing["end"] = "00:30"
        let rows = try AIImportFormat.parse(payload([direct, midnight, crossing]), kind: .timetable, maxWeeks: 20).lessons
        #expect(rows[0].startMinute == 0 && rows[0].endMinute == 45)
        #expect(rows[1].startMinute == 1395 && rows[1].endMinute == 1440)
        #expect(rows[2].weekday == 1)
        #expect(rows[2].startMinute == nil && rows[2].endMinute == nil)
        #expect(rows[2].sourceText.contains("23:15"))
        #expect(rows[2].warnings.contains { $0.contains("跨午夜") })
    }

    @Test func bellScheduleRetainsBreaksAndSortsByPeriodNumber() throws {
        let periods: [[String: Any]] = [["number": 2, "start": "08:55", "end": "09:40"], ["number": 1, "start": "08:00", "end": "08:45"], ["number": 12, "start": "23:15", "end": "24:00"]]
        let draft = try AIImportFormat.parse(payload([], kind: "bellSchedule", periods: periods), kind: .bellSchedule, maxWeeks: 20)
        #expect(draft.lessons.isEmpty)
        #expect(draft.periods.map(\.number) == [1, 2, 12])
        #expect(draft.periods[0].endMinute == 525 && draft.periods[1].startMinute == 535)
        #expect(draft.periods[2].endMinute == 1440)
    }

    @Test func incompleteDuplicateAndInvalidBellPeriodsAreRejected() throws {
        for row: [String: Any] in [
            ["number": 1, "start": NSNull(), "end": "08:45"],
            ["number": 1, "start": "08:00", "end": "07:45"],
            ["number": true, "start": "08:00", "end": "08:45"],
            ["number": 1, "start": "8:00", "end": "08:45"]
        ] {
            rejects(try payload([], kind: "bellSchedule", periods: [row]), kind: .bellSchedule, mentioning: "第 1 条作息")
        }
        let period: [String: Any] = ["number": 1, "start": "08:00", "end": "08:45"]
        rejects(try payload([], kind: "bellSchedule", periods: [period, period]), kind: .bellSchedule, mentioning: "重复")
    }

    @Test func inputLimitsAreEnforcedBeforePartialImport() throws {
        rejects(String(repeating: "a", count: AIImportFormat.maximumBytes + 1), mentioning: "1 MB")
        rejects(try payload(Array(repeating: lesson, count: 501)), mentioning: "500")
        rejects(try payload([], kind: "bellSchedule", periods: Array(repeating: ["number": 1, "start": "08:00", "end": "08:45"], count: 41)), kind: .bellSchedule, mentioning: "40")
        rejects(try payload([lesson]), maxWeeks: 0, mentioning: "学期总周数")
        #expect(try AIImportFormat.parse(payload(Array(repeating: lesson, count: 500)), kind: .timetable, maxWeeks: 20).lessons.count == 500)
    }

    @Test func promptContainsVersionedExamplesAndNoInferenceInstructions() throws {
        let coursePrompt = AIImportFormat.prompt(kind: .timetable, maxWeeks: 18)
        #expect(coursePrompt.contains("18 周"))
        #expect(coursePrompt.contains("不能用来补全"))
        #expect(coursePrompt.contains("合并单元格"))
        #expect(coursePrompt.contains("用户确认的学校作息表"))
        #expect(coursePrompt.contains("示例课程"))
        #expect(try AIImportFormat.parse(AIImportFormat.exampleTimetable, kind: .timetable, maxWeeks: 20).lessons.count == 1)
        let bellPrompt = AIImportFormat.prompt(kind: .bellSchedule, maxWeeks: 20)
        #expect(bellPrompt.contains("kind 必须是 \"bellSchedule\""))
        #expect(bellPrompt.contains("不要估计缺失时间"))
    }
}
