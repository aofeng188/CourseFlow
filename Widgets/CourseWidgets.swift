import SwiftUI
import WidgetKit
import ActivityKit
import CourseKit

@main
struct CourseWidgets: WidgetBundle {
    var body: some Widget {
        NextCourseWidget()
        TodayCoursesWidget()
        CourseLiveActivityWidget()
    }
}

private struct CourseEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var status: CurrentStatus {
        ScheduleEngine.status(at: date, occurrences: snapshot.occurrences, semester: snapshot.semester)
    }
    var lesson: Occurrence? { status.current ?? status.next }
    var calendar: Calendar { snapshot.semester?.calendar ?? .current }
    var today: [Occurrence] {
        snapshot.occurrences.filter { calendar.isDate($0.start, inSameDayAs: date) }.sorted { $0.start < $1.start }
    }
    var timeZone: TimeZone { calendar.timeZone }
    func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: timeZone).hour(.twoDigits(amPM: .omitted)).minute())
    }
    var statusTitle: String {
        switch status.kind {
        case .inClass: "正在上课"
        case .onBreak: "课间休息"
        case .upcoming: "下一节课"
        case .finishedToday: "今天的课已结束"
        case .beforeSemester: "新学期即将开始"
        case .afterSemester: "本学期已结束"
        case .empty: "你的课表，随时可见"
        }
    }
    var deadline: Date? {
        switch status.kind {
        case .inClass: status.segment?.end
        case .onBreak: status.nextSegment?.start
        default: status.next?.start
        }
    }
}

private struct CourseProvider: TimelineProvider {
    func placeholder(in context: Context) -> CourseEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (CourseEntry) -> Void) {
        completion(context.isPreview ? .preview : CourseEntry(date: .now, snapshot: CourseAppGroup.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
        let snapshot = CourseAppGroup.readSnapshot()
        let now = Date()
        let horizon = now.addingTimeInterval(48 * 60 * 60)
        var changes = Set<Date>([now])
        for occurrence in snapshot.occurrences {
            for segment in occurrence.segments {
                for date in [segment.start, segment.end] where date > now && date < horizon { changes.insert(date) }
            }
        }
        let calendar = snapshot.semester?.calendar ?? .current
        for offset in 1...2 {
            if let midnight = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) {
                changes.insert(midnight)
            }
        }
        // System date text animates countdowns; timeline reloads only change course content.
        let entries = changes.sorted().map { CourseEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(horizon)))
    }
}

private struct NextCourseWidget: Widget {
    let kind = "CourseFlow.NextCourse"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CourseProvider()) { entry in
            NextCourseView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: entry.lesson.map { "courseflow://course/\($0.courseID.uuidString)" } ?? "courseflow://today"))
        }
        .configurationDisplayName("下一节课")
        .description("课程、教室和倒计时，一眼就知道。")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

private struct NextCourseView: View {
    let entry: CourseEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            if let lesson = entry.lesson {
                Text("\(entry.clock(lesson.start)) \(lesson.courseName) · \(lesson.location)")
            } else { Label("今日无课", systemImage: "leaf") }
        case .accessoryCircular:
            if let lesson = entry.lesson {
                VStack(spacing: 2) {
                    Image(systemName: entry.status.kind == .inClass ? "book.fill" : "clock")
                        .font(.caption)
                    Text(entry.clock(lesson.start)).font(.system(.caption, design: .rounded, weight: .semibold))
                    Text(lesson.courseName).font(.system(size: 9)).lineLimit(1)
                }
            } else { Image(systemName: "leaf").font(.title2) }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.statusTitle).font(.caption).foregroundStyle(.secondary)
                Text(entry.lesson?.courseName ?? "打开课序导入课表").font(.headline).lineLimit(1)
                if let lesson = entry.lesson {
                    Text("\(entry.clock(lesson.start)) · \(lesson.location.isEmpty ? "地点待补充" : lesson.location)")
                        .font(.caption).lineLimit(1)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: entry.status.kind == .inClass ? "book.fill" : "calendar")
                        .foregroundStyle(WidgetPalette.color(entry.lesson?.colorIndex ?? 0))
                    Text(entry.statusTitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(entry.lesson?.courseName ?? "从一张课表开始")
                    .font(.system(.title3, design: .rounded, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                if let lesson = entry.lesson {
                    Label(lesson.location.isEmpty ? "地点待补充" : lesson.location, systemImage: "mappin")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let deadline = entry.deadline, deadline > entry.date,
                       deadline.timeIntervalSince(entry.date) < 24 * 60 * 60 {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(timerInterval: entry.date...deadline, countsDown: true)
                                .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                            Text(entry.status.kind == .inClass ? "后下课" : "后上课")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(lesson.start.formatted(Date.FormatStyle(timeZone: entry.timeZone).weekday(.abbreviated).hour().minute()))
                            .font(.caption.weight(.medium))
                    }
                } else {
                    Text("导入图片或表格，把新学期装进口袋。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TodayCoursesWidget: Widget {
    let kind = "CourseFlow.Today"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CourseProvider()) { entry in
            TodayCoursesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "courseflow://today"))
        }
        .configurationDisplayName("今日课表")
        .description("把今天的课程和教室放在桌面。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct TodayCoursesView: View {
    let entry: CourseEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 16 : 9) {
            HStack {
                Text("今天").font(.system(.headline, design: .rounded))
                Text(entry.date.formatted(Date.FormatStyle(timeZone: entry.timeZone).month().day().weekday(.abbreviated)))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(entry.today.count) 节课").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if entry.today.isEmpty {
                Spacer(minLength: 0)
                Label(entry.snapshot.semester == nil ? "打开课序，导入你的第一张课表" : "今天没有课程，好好安排自己的时间", systemImage: "leaf")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                let rows = visibleRows
                ForEach(rows) { lesson in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WidgetPalette.color(lesson.colorIndex))
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lesson.courseName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(lesson.location.isEmpty ? "地点待补充" : lesson.location)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 5)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(entry.clock(lesson.start)).font(.system(.subheadline, design: .rounded, weight: .medium)).monospacedDigit()
                            Text(entry.clock(lesson.end)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .opacity(lesson.end <= entry.date ? 0.5 : 1)
                }
                Spacer(minLength: 0)
            }
        }
    }
    private var visibleRows: [Occurrence] {
        let limit = family == .systemLarge ? 6 : 2
        let upcoming = entry.today.filter { $0.end > entry.date }
        return Array((upcoming.isEmpty ? Array(entry.today.suffix(limit)) : upcoming).prefix(limit))
    }
}

private struct CourseLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CourseActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.isStale ? "calendar" : (context.state.phase == .onBreak ? "cup.and.saucer.fill" : "book.closed.fill"))
                    .font(.title2).foregroundStyle(WidgetPalette.color(context.state.colorIndex))
                VStack(alignment: .leading, spacing: 5) {
                    Text(context.state.courseName).font(.headline).lineLimit(1)
                    Label(context.state.location.isEmpty ? "地点待补充" : context.state.location, systemImage: "mappin")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if context.isStale {
                        Text(Date.now >= context.state.end ? "课程已结束" : "课程安排").font(.subheadline.weight(.medium))
                        Text(context.state.start, style: .time).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(timerInterval: context.state.phaseStart...context.state.phaseEnd, countsDown: true)
                            .font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit()
                        Text(context.state.phase == .onBreak ? "后继续上课" : "后本节下课").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .activityBackgroundTint(.clear)
            .widgetURL(URL(string: "courseflow://course/\(context.attributes.courseID)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.isStale ? "课序" : (context.state.phase == .onBreak ? "课间休息" : "正在上课"), systemImage: "book.closed.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.color(context.state.colorIndex))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.isStale { Text(Date.now >= context.state.end ? "已结束" : "课程安排").font(.caption) }
                    else {
                        Text(timerInterval: context.state.phaseStart...context.state.phaseEnd, countsDown: true)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.courseName).font(.headline).lineLimit(1)
                        Label(context.state.location.isEmpty ? "地点待补充" : context.state.location, systemImage: "mappin")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == .onBreak && !context.isStale ? "cup.and.saucer.fill" : "book.closed.fill")
                    .foregroundStyle(WidgetPalette.color(context.state.colorIndex))
            } compactTrailing: {
                if context.isStale { Image(systemName: Date.now >= context.state.end ? "checkmark" : "calendar") }
                else {
                    Text(timerInterval: context.state.phaseStart...context.state.phaseEnd, countsDown: true)
                        .monospacedDigit().frame(maxWidth: 52)
                }
            } minimal: {
                Image(systemName: context.isStale ? "calendar" : (context.state.phase == .onBreak ? "cup.and.saucer.fill" : "book.closed.fill"))
                    .foregroundStyle(WidgetPalette.color(context.state.colorIndex))
            }
            .widgetURL(URL(string: "courseflow://course/\(context.attributes.courseID)"))
        }
    }
}

private enum WidgetPalette {
    static func color(_ index: Int) -> Color {
        let colors: [Color] = [.teal, .blue, .purple, .orange, .pink, .indigo, .green, .cyan]
        return colors[((index % colors.count) + colors.count) % colors.count]
    }
}

private extension CourseEntry {
    static var preview: CourseEntry {
        let now = Date()
        let semester = Semester(name: "秋季学期", firstMonday: now.addingTimeInterval(-14 * 86400))
        let lesson = Occurrence(id: "preview", semesterID: semester.id, courseID: UUID(), ruleID: UUID(),
                                originalDate: now, courseName: "高等数学", colorIndex: 0,
                                location: "博学楼 A302", teacher: "张老师", week: 3,
                                segments: [TeachingSegment(start: now.addingTimeInterval(20 * 60), end: now.addingTimeInterval(110 * 60))])
        return CourseEntry(date: now, snapshot: WidgetSnapshot(semester: semester, occurrences: [lesson]))
    }
}
