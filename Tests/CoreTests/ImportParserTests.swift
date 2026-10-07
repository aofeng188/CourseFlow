import Foundation
import Testing
@testable import CourseKit

@Suite("课表与作息导入")
struct ImportParserTests {
    @Test func quotedCSVPreservesCommasMultilineAndEscapedQuotes() {
        let rows = ImportParser.delimitedRows("\u{FEFF}课程,地点,教师\r\n\"设计,实验\",\"A301\n东楼\",\"李\"\"明\"\r\n")
        #expect(rows == [["课程", "地点", "教师"], ["设计,实验", "A301\n东楼", "李\"明"]])
        #expect(ImportParser.delimitedRows("课程;星期;周次\n高等数学;一;1-8周") == [["课程", "星期", "周次"], ["高等数学", "一", "1-8周"]])
    }
    @Test func mappedTablePreservesUnknownsRatherThanInventingTimes() {
        let rows = [["科目", "星期", "周次", "节次", "教室", "教师"], ["高等数学", "星期一", "1-8周", "1-2", "A301", "张老师"], ["大学物理", "", "", "3-4", "", ""]]
        let draft = ImportParser.table(rows, maxWeeks: 20)
        #expect(draft.lessons.count == 2)
        #expect(draft.lessons[0].weekday == 1)
        #expect(draft.lessons[0].weeks == Array(1...8))
        #expect(draft.lessons[0].periods == [1, 2])
        #expect(draft.lessons[0].location == "A301")
        #expect(draft.lessons[0].startMinute == nil)
        #expect(draft.lessons[1].weekday == nil)
        #expect(draft.lessons[1].weeks.isEmpty)
    }
    @Test func mergedCellSpansSeveralTeachingPeriods() {
        let cells = [ImportTableCell(text: "节次", row: 0, column: 0), ImportTableCell(text: "星期一", row: 0, column: 1), ImportTableCell(text: "星期二", row: 0, column: 2), ImportTableCell(text: "第1节", row: 1, column: 0), ImportTableCell(text: "第2节", row: 2, column: 0), ImportTableCell(text: "高等数学\n1-8周\n主楼 A301", row: 1, column: 1, rowSpan: 2)]
        let draft = ImportParser.grid(cells, sourcePage: 3)
        #expect(draft.lessons.count == 1)
        #expect(draft.lessons[0].name == "高等数学")
        #expect(draft.lessons[0].periods == [1, 2])
        #expect(draft.lessons[0].weekday == 1)
        #expect(draft.lessons[0].weeks == Array(1...8))
        #expect(draft.lessons[0].sourcePage == 3)
    }
    @Test func detectsBellScheduleWithoutTurningBreaksIntoLessons() {
        let draft = ImportParser.text("学校作息\n第1节 08:00–08:45\n课间休息10分钟\n第2节 08:55—09:40\n第三节 10:00 至 10:45", kind: .bellSchedule)
        #expect(draft.periods.map(\.number) == [1, 2, 3])
        #expect(draft.periods[0].startMinute == 480)
        #expect(draft.periods[1].endMinute == 580)
        #expect(draft.lessons.isEmpty)
    }
    @Test func oddWeeksAndInvalidWeeksRequireFaithfulParsing() {
        #expect(ImportParser.parseWeeks("1-8周(单)", maxWeeks: 20) == [1, 3, 5, 7])
        #expect(ImportParser.parseWeeks("1-88周", maxWeeks: 20).isEmpty)
        #expect(ImportParser.parseWeeks("", maxWeeks: 20).isEmpty)
    }
    @Test func explicitClockTimesArePreservedAndValidated() {
        #expect(ImportParser.minute("08:05") == 485)
        #expect(ImportParser.minute("24:20") == nil)
        #expect(ImportParser.minute("12:90") == nil)
        let rows = [["课程名称", "星期", "周次", "开始", "结束"], ["实验", "三", "2,4,6", "14:00", "16:00"]]
        let draft = ImportParser.table(rows)
        #expect(draft.lessons[0].periods.isEmpty)
        #expect(draft.lessons[0].startMinute == 840)
        #expect(draft.lessons[0].endMinute == 960)
    }
    @Test func independentPastedCoursesAndTeacherLocation() {
        let draft = ImportParser.text("高等数学 周一 第1-2节 1-8周 地点:A301 教师:张老师\n大学英语 周二 第3-4节 1-16周 地点:B201")
        #expect(draft.lessons.count == 2)
        #expect(draft.lessons[0].name == "高等数学")
        #expect(draft.lessons[0].teacher == "张老师")
        #expect(draft.lessons[0].location == "A301")
        #expect(draft.lessons[1].weekday == 2)
    }
    @Test func pastedWeekRangeDoesNotConsumePrecedingClockMinutes() {
        let draft = ImportParser.text("导入界面验收课 周日 21:00-21:45 1-8周 地点:测试楼Z909 教师:测试老师")
        #expect(draft.lessons.count == 1)
        #expect(draft.lessons[0].weekday == 7)
        #expect(draft.lessons[0].startMinute == 1260)
        #expect(draft.lessons[0].endMinute == 1305)
        #expect(draft.lessons[0].weeks == Array(1...8))
        let spaced = ImportParser.text("实验 周一 第 1 - 2 节 1 - 8 周(单)")
        #expect(spaced.lessons[0].periods == [1, 2])
        #expect(spaced.lessons[0].weeks == [1, 3, 5, 7])
        let missing = ImportParser.text("实验 周日 08:00-08:05周")
        #expect(missing.lessons[0].weeks.isEmpty)
    }
    @Test func visionListTableUsesHeaderMapping() {
        let rows = [["课程名称", "星期", "周次", "节次"], ["大学物理", "周3", "1-8周", "3-4"]]
        let cells = rows.enumerated().flatMap { row, values in values.enumerated().map { ImportTableCell(text: $0.element, row: row, column: $0.offset) } }
        let draft = ImportParser.documentTable(cells, sourcePage: 2)
        #expect(draft.lessons.count == 1)
        #expect(draft.lessons[0].name == "大学物理")
        #expect(draft.lessons[0].weekday == 3)
        #expect(draft.lessons[0].periods == [3, 4])
    }
    @Test func periodParsingNeverSilentlyTruncatesInvalidRanges() {
        #expect(ImportParser.numbers("第1-2、4节") == [1, 2, 4])
        #expect(ImportParser.numbers("十一至十二节") == [11, 12])
        #expect(ImportParser.numbers("1-100").isEmpty)
        #expect(ImportParser.numbers("1,99").isEmpty)
        #expect(ImportParser.numbers("未知1").isEmpty)
    }
    @Test func spreadsheetFractionalClockValuesAreRecognized() {
        let draft = ImportParser.table([["课程", "星期", "周次", "开始", "结束"], ["实验", "一", "1-8", "0.3333333333333333", "0.375"]])
        #expect(draft.lessons.first?.startMinute == 480)
        #expect(draft.lessons.first?.endMinute == 540)
    }
}
