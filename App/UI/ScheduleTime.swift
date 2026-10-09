import SwiftUI
import CourseKit

/// Deterministic UI time is available only with an isolated, in-memory testing launch.
enum PreviewClock {
    static var fixedDate: Date? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting"), let index = arguments.firstIndex(of: "--preview-date"), index + 1 < arguments.count else { return nil }
        return ISO8601DateFormatter().date(from: arguments[index + 1])
    }
    static func now(_ date: Date) -> Date { fixedDate ?? date }
}

enum ScheduleTime {
    static func status(_ event: Occurrence, now: Date?) -> String? {
        guard let now, event.start <= now, now < event.end else { return nil }
        return event.segments.contains { $0.start <= now && now < $0.end } ? "正在上课" : "课间休息"
    }
    static func insertionIndex(_ events: [Occurrence], now: Date) -> Int {
        events.firstIndex { $0.end > now } ?? events.count
    }
    static func symbol(now: Date, semester: Semester) -> String {
        let hour = semester.calendar.component(.hour, from: now)
        return (6..<18).contains(hour) ? "sun.max" : "moon.stars"
    }
}

/// "现在 10:20" with a rule, for the agenda list and for times outside the week grid.
struct NowMarker: View {
    let now: Date
    let semester: Semester
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("现在 \(Display.time(now, zone: semester.timeZoneID))").font(.caption.weight(.semibold)).monospacedDigit().fixedSize()
                    .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 3).background(Palette.now, in: .capsule)
                Capsule().fill(Palette.now.opacity(0.6)).frame(height: 1.5)
            }
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary).padding(.leading, 2) }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("现在，\(Display.time(now, zone: semester.timeZoneID))，\(note ?? "")")
        .accessibilityIdentifier("now-marker")
    }
}

/// The current time across the week grid: faint in other days, solid in today's column.
/// The matching period number on the time axis turns the same color, so no label is drawn over it.
struct GridNowLine: View {
    let now: Date
    let semester: Semester
    let axis: CGFloat
    let column: CGFloat
    let todayIndex: Int
    let width: CGFloat
    var body: some View {
        let left = axis + CGFloat(todayIndex) * column
        ZStack(alignment: .topLeading) {
            Path { p in p.move(to: CGPoint(x: axis, y: 0)); p.addLine(to: CGPoint(x: width, y: 0)) }
                .stroke(Palette.now.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            Capsule().fill(Palette.now).frame(width: column, height: 2).offset(x: left, y: -1)
            Circle().fill(Palette.now).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 1.5))
                .offset(x: left - 4.5, y: -4.5)
        }.frame(width: width, height: 1, alignment: .topLeading).allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel("现在，\(Display.time(now, zone: semester.timeZoneID))")
            .accessibilityIdentifier("grid-now-line")
    }
}

struct AgendaView: View {
    let semester: Semester
    let week: Int
    let occurrences: [Occurrence]
    let now: Date
    var holidayDays: [OfficialHolidayDay] = []
    var pendingMakeupKeys: Set<String> = []
    let onCourse: (Occurrence) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            let containsToday = (1...7).contains { semester.calendar.isDate(ScheduleEngine.date(week: week, weekday: $0, semester: semester), inSameDayAs: now) }
            if occurrences.isEmpty && !containsToday && !(1...7).contains(where: { day in holidayDays.contains { $0.dateKey == HolidayCalendar.key(ScheduleEngine.date(week: week, weekday: day, semester: semester), calendar: semester.calendar) } }) { ContentUnavailableView("本周没有课程", systemImage: "cup.and.saucer", description: Text("可以切换教学周，或添加新的上课安排。")) }
            ForEach(1...7, id: \.self) { day in
                let date = ScheduleEngine.date(week: week, weekday: day, semester: semester)
                let events = occurrences.filter { semester.calendar.isDate($0.start, inSameDayAs: date) }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
                let today = semester.calendar.isDate(date, inSameDayAs: now)
                let key = HolidayCalendar.key(date, calendar: semester.calendar)
                let holiday = holidayDays.first { $0.dateKey == key }
                let pending = pendingMakeupKeys.contains(key)
                if !events.isEmpty || today || holiday != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(Display.weekdays[day - 1]).font(.subheadline.weight(.semibold)).foregroundStyle(today ? Palette.accent : .primary)
                            Text(Display.day(date, in: semester)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            if today { Text("今天").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 2).background(Palette.accentSolid, in: .capsule) }
                            if let holiday { Text(holiday.kind == .makeup ? "调休" : holiday.name).font(.caption2.weight(.medium)).foregroundStyle(holiday.kind == .makeup ? Color.secondary : Palette.now).padding(.horizontal, 7).padding(.vertical, 2).background((holiday.kind == .makeup ? Color.secondary : Palette.now).opacity(0.12), in: .capsule) }
                            Spacer(minLength: 0)
                            if !events.isEmpty { Text("\(events.count) 次课").font(.caption).foregroundStyle(.tertiary) }
                        }.padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            if pending { Label("调休课程待定 · 原课表待核对", systemImage: "calendar.badge.questionmark").font(.caption.weight(.semibold)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10) }
                            let insertion = ScheduleTime.insertionIndex(events, now: now)
                            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                                if today && index == insertion { NowMarker(now: now, semester: semester) }
                                let status = ScheduleTime.status(event, now: today ? now : nil)
                                Button { onCourse(event) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        CourseRow(occurrence: event, timeZoneID: semester.timeZoneID)
                                        if status != nil || pending {
                                            HStack {
                                                if let status { Text(status).foregroundStyle(Palette.color(event.colorIndex)) }
                                                if pending { Text("待核对").foregroundStyle(.orange) }
                                            }.font(.caption.weight(.semibold)).padding(.bottom, 6)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .background(status != nil ? Palette.fill(event.colorIndex) : .clear, in: .rect(cornerRadius: Theme.innerRadius, style: .continuous))
                                        .opacity(today && event.end <= now ? 0.55 : 1)
                                }.buttonStyle(.plain)
                                if index < events.count - 1 { Divider().padding(.leading, 70) }
                            }
                            if today && insertion == events.count { NowMarker(now: now, semester: semester) }
                            if events.isEmpty { Text(pending ? "有课待定，确认后显示学校课程" : (today ? "今天没有课程" : "当天没有课程")).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12) }
                        }.padding(.horizontal, 12).padding(.vertical, 6)
                            .cardBackground()
                    }
                }
            }
        }
    }
}
