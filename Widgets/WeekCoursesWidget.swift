import SwiftUI
import WidgetKit
import CourseKit

struct WeekCoursesWidget: Widget {
    let kind = "CourseFlow.Week"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WeekCourseProvider()) { entry in
            WeekCoursesView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground(color: Palette.accent) }
                .widgetURL(URL(string: "courseflow://today"))
        }
        .configurationDisplayName("本周课表")
        .description("整周的课程一屏看完，今天会高亮显示。")
        .supportedFamilies([.systemLarge, .systemExtraLarge])
    }
}

/// Shares the course timeline; only the gallery preview differs, using the full example timetable.
private struct WeekCourseProvider: TimelineProvider {
    private let base = CourseProvider()
    func placeholder(in context: Context) -> CourseEntry { .weekPreview }
    func getSnapshot(in context: Context, completion: @escaping (CourseEntry) -> Void) {
        if context.isPreview { completion(.weekPreview) } else { base.getSnapshot(in: context, completion: completion) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CourseEntry>) -> Void) {
        base.getTimeline(in: context, completion: completion)
    }
}

private struct WeekCoursesView: View {
    let entry: CourseEntry

    var body: some View {
        if let semester = entry.snapshot.semester {
            let week = ScheduleEngine.weekNumber(on: entry.date, semester: semester)
            if week > semester.weekCount {
                message("\(semester.name)已结束", detail: "打开课序设置新学期。")
            } else {
                WeekGridContent(entry: entry, semester: semester, week: max(1, week), notStarted: week < 1)
            }
        } else {
            message("本周课表", detail: "打开课序，导入你的第一张课表。")
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(.headline, design: .rounded))
            Spacer(minLength: 0)
            Label(detail, systemImage: "leaf").font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WeekGridContent: View {
    let entry: CourseEntry
    let semester: Semester
    let week: Int
    let notStarted: Bool
    /// This week's lessons, filtered once from the whole semester.
    private let lessons: [Occurrence]
    private let labelWidth: CGFloat = 26

    init(entry: CourseEntry, semester: Semester, week: Int, notStarted: Bool) {
        self.entry = entry; self.semester = semester; self.week = week; self.notStarted = notStarted
        let start = ScheduleEngine.date(week: week, weekday: 1, semester: semester)
        let end = semester.calendar.date(byAdding: .day, value: 7, to: start) ?? start
        lessons = entry.snapshot.occurrences.filter { $0.start >= start && $0.start < end }
    }

    private var calendar: Calendar { semester.calendar }
    private func date(_ weekday: Int) -> Date { ScheduleEngine.date(week: week, weekday: weekday, semester: semester) }
    /// Weekends appear only when they have lessons, keeping weekday columns readable.
    private var weekdays: [Int] {
        let busy = Set(lessons.map { (calendar.component(.weekday, from: $0.start) + 5) % 7 + 1 })
        return (1...7).filter { $0 <= 5 || busy.contains($0) }
    }
    private func minute(_ value: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: value)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    private func span(_ lesson: Occurrence) -> Range<Int> {
        let start = minute(lesson.start)
        let end = calendar.isDate(lesson.start, inSameDayAs: lesson.end) ? minute(lesson.end) : 1440
        return start..<max(end, start + 1)
    }
    /// The widget has no bell schedule, so the periods come from this week's lesson segments;
    /// breaks then collapse the same way as in the app's week grid.
    private var scale: TimelineScale {
        var periods: [Int: Period] = [:]
        for lesson in lessons {
            for segment in lesson.segments {
                if let number = segment.periodNumber, periods[number] == nil {
                    periods[number] = Period(number: number, startMinute: minute(segment.start), endMinute: minute(segment.end))
                }
            }
        }
        return TimelineScale(periods: Array(periods.values), lessons: lessons.map(span), metrics: .init(periodHeight: 10, gapHeight: 0.6, longBreakHeight: 3, longBreakMinutes: 30))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            dayHeader
            if lessons.isEmpty {
                Spacer(minLength: 0)
                Label(notStarted ? "学期还没开始" : "本周没有课程", systemImage: "cup.and.saucer").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                grid
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(week) 周课表，共 \(lessons.count) 节课")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("第 \(week) 周").font(.system(.headline, design: .rounded)).foregroundStyle(Palette.accent)
            Text("\(day(date(1)))–\(day(date(7)))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(notStarted ? "即将开学" : "\(lessons.count) 节课").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private var dayHeader: some View {
        // No spacing: columns must line up with the grid's equal-width columns below.
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: 1)
            ForEach(weekdays, id: \.self) { weekday in
                let today = calendar.isDate(entry.date, inSameDayAs: date(weekday))
                VStack(spacing: 1) {
                    Text(["一", "二", "三", "四", "五", "六", "日"][weekday - 1]).font(.system(size: 10, weight: .medium))
                    Text("\(calendar.component(.day, from: date(weekday)))").font(.system(size: 11, weight: today ? .bold : .regular, design: .rounded))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 3)
                .foregroundStyle(today ? Color.white : .secondary)
                .background(today ? AnyShapeStyle(Palette.accentSolid.gradient) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 1)
            }
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            let scale = scale
            let columns = CGFloat(weekdays.count)
            let column = (geometry.size.width - labelWidth) / columns
            let factor = geometry.size.height / CGFloat(max(1, scale.height))
            ZStack(alignment: .topLeading) {
                ForEach(Array(scale.segments.enumerated()), id: \.offset) { _, segment in
                    let y = CGFloat(segment.y) * factor
                    switch segment.kind {
                    case .period(let number):
                        Text("\(number)").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                            .frame(width: labelWidth - 4, height: CGFloat(segment.height) * factor)
                            .offset(y: y)
                    case .hour:
                        Text(Period.clock(segment.startMinute)).font(.system(size: 8)).foregroundStyle(.tertiary).offset(y: y - 1)
                    case .longBreak:
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(width: geometry.size.width - labelWidth, height: 0.5)
                            .offset(x: labelWidth, y: y + CGFloat(segment.height) * factor / 2)
                    case .gap, .open:
                        EmptyView()
                    }
                }
                ForEach(Array(weekdays.enumerated()), id: \.element) { index, weekday in
                    let dayLessons = lessons.filter { calendar.isDate($0.start, inSameDayAs: date(weekday)) }
                    let placements = OccurrenceLayout.lanes(for: dayLessons)
                    ForEach(dayLessons) { lesson in
                        let placement = placements[lesson.id] ?? LanePlacement(lane: 0, laneCount: 1)
                        let width = column / CGFloat(max(1, placement.laneCount))
                        let range = span(lesson)
                        let top = CGFloat(scale.y(at: range.lowerBound)) * factor
                        let height = max(14, CGFloat(scale.y(at: range.upperBound)) * factor - top - 2)
                        block(lesson, height: height)
                            .frame(width: max(8, width - 2), height: height, alignment: .topLeading)
                            .offset(x: labelWidth + CGFloat(index) * column + CGFloat(placement.lane) * width + 1, y: top + 1)
                    }
                }
            }
        }
    }

    private func block(_ lesson: Occurrence, height: CGFloat) -> some View {
        let live = lesson.start <= entry.date && entry.date < lesson.end
        let color = Palette.color(lesson.colorIndex)
        return VStack(alignment: .leading, spacing: 1) {
            Text(lesson.courseName).font(.system(size: 10, weight: .semibold)).lineLimit(height > 64 ? 3 : (height > 30 ? 2 : 1))
            if height > 36 && !lesson.location.isEmpty { Text(lesson.location).font(.system(size: 8)).lineLimit(1).opacity(0.85) }
        }
        .foregroundStyle(live ? Color.white : color)
        .padding(.leading, live ? 3 : 5).padding(.trailing, 2).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if live { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.solid(lesson.colorIndex)) }
            else {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.fill(lesson.colorIndex))
                    .overlay(alignment: .leading) { Capsule().fill(color).frame(width: 2).padding(.vertical, 3).padding(.leading, 1.5) }
            }
        }
        .opacity(lesson.end <= entry.date ? 0.5 : 1)
    }

    private func day(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.defaultDigits).day())
    }
}

extension CourseEntry {
    /// Shown at 07:00 today so the gallery preview has today's lessons still ahead.
    static var weekPreview: CourseEntry {
        let sample = SampleData.make(now: .now)
        let semester = sample.semesters.first
        let occurrences = semester.map { ScheduleEngine.occurrences(snapshot: sample, semesterID: $0.id) } ?? []
        let date = semester.flatMap { $0.calendar.date(bySettingHour: 7, minute: 0, second: 0, of: .now) } ?? .now
        return CourseEntry(date: date, snapshot: WidgetSnapshot(semester: semester, occurrences: occurrences))
    }
}
