import AppIntents
import Foundation
import CourseKit

/// Answers "what's next" from Siri, Spotlight and Shortcuts without opening the app.
struct NextCourseIntent: AppIntent {
    static let title: LocalizedStringResource = "下一节课"
    static let description = IntentDescription("查看正在上的课或下一节课的时间与地点。")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CourseIntentText.withStore { store in
            CourseIntentText.nextCourse(at: PreviewClock.now(.now), occurrences: store.occurrences, semester: store.semester)
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct TodayCoursesIntent: AppIntent {
    static let title: LocalizedStringResource = "今日课表"
    static let description = IntentDescription("列出今天的全部课程、时间与地点。")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await CourseIntentText.withStore { store in
            CourseIntentText.today(at: PreviewClock.now(.now), occurrences: store.occurrences, semester: store.semester)
        }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct CourseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextCourseIntent(), phrases: [
            "\(.applicationName)下一节课是什么",
            "\(.applicationName)下节课在哪",
            "用\(.applicationName)查看下一节课"
        ], shortTitle: "下一节课", systemImageName: "clock")
        AppShortcut(intent: TodayCoursesIntent(), phrases: [
            "\(.applicationName)今天有什么课",
            "用\(.applicationName)查看今天的课"
        ], shortTitle: "今日课表", systemImageName: "calendar")
    }
}

enum CourseIntentText {
    /// Waits for the store's first schedule computation; intents may launch the app in the background.
    @MainActor
    static func withStore(_ answer: (AppStore) -> String) async -> String {
        guard let store = AppStore.current else { return "暂时无法读取课表，请打开课序后再试。" }
        await store.waitForRefresh()
        return answer(store)
    }

    static func nextCourse(at now: Date, occurrences: [Occurrence], semester: Semester?) -> String {
        guard let semester else { return "还没有课表。打开课序设置学期并导入课程后再问我吧。" }
        let status = ScheduleEngine.status(at: now, occurrences: occurrences, semester: semester)
        let zone = semester.timeZoneID
        switch status.kind {
        case .inClass:
            guard let current = status.current else { break }
            let end = status.segment?.end ?? current.end
            return "正在上「\(current.courseName)」，本节 \(Display.time(end, zone: zone)) 下课\(place(current))。"
        case .onBreak:
            guard let current = status.current else { break }
            let resume = status.nextSegment.map { "，\(Display.time($0.start, zone: zone)) 继续上课" } ?? ""
            return "「\(current.courseName)」课间休息\(resume)\(place(current))。"
        case .empty:
            return "这个学期还没有课程。打开课序导入或添加课程。"
        case .afterSemester:
            return "\(semester.name)已经结束，辛苦了。"
        default:
            break
        }
        guard let next = status.next else { return "接下来没有课程安排。" }
        return "下一节课是「\(next.courseName)」，\(dayText(next.start, now: now, semester: semester)) \(Display.time(next.start, zone: zone)) 开始\(place(next))。"
    }

    static func today(at now: Date, occurrences: [Occurrence], semester: Semester?) -> String {
        guard let semester else { return "还没有课表。打开课序设置学期并导入课程后再问我吧。" }
        let calendar = semester.calendar
        let lessons = occurrences.filter { $0.semesterID == semester.id && calendar.isDate($0.start, inSameDayAs: now) }.sorted { $0.start < $1.start }
        guard !lessons.isEmpty else { return "今天没有课，好好安排自己的时间。" }
        let items = lessons.map { lesson in
            let location = lesson.location.isEmpty ? "" : "（\(lesson.location)）"
            return "\(Display.time(lesson.start, zone: semester.timeZoneID)) \(lesson.courseName)\(location)"
        }
        return "今天有 \(lessons.count) 节课：" + items.joined(separator: "；") + "。"
    }

    private static func place(_ occurrence: Occurrence) -> String {
        occurrence.location.isEmpty ? "" : "，地点 \(occurrence.location)"
    }

    private static func dayText(_ date: Date, now: Date, semester: Semester) -> String {
        let calendar = semester.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default:
            let weekday = (calendar.component(.weekday, from: date) + 5) % 7
            return "\(Display.day(date, in: semester)) \(Display.weekdays[weekday])"
        }
    }
}
