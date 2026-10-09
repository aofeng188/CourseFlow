import SwiftUI
import CourseKit

enum Display {
    static let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static func format(_ date: Date, style: Date.FormatStyle, zone: String) -> String { var style = style; style.timeZone = TimeZone(identifier: zone) ?? .gmt; style.locale = Locale(identifier: "zh_CN"); return date.formatted(style) }
    static func time(_ date: Date, zone: String = "Asia/Shanghai") -> String {
        format(date, style: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits), zone: zone)
    }
    static func minutes(_ date: Date, in semester: Semester) -> Int { let v = semester.calendar.dateComponents([.hour, .minute], from: date); return (v.hour ?? 0) * 60 + (v.minute ?? 0) }
    static func day(_ date: Date, in semester: Semester) -> String { format(date, style: .dateTime.month(.twoDigits).day(.twoDigits), zone: semester.timeZoneID) }
}

struct CourseDot: View {
    var colorIndex: Int
    var body: some View { RoundedRectangle(cornerRadius: 3).fill(Palette.color(colorIndex)).frame(width: 5, height: 38).accessibilityHidden(true) }
}

struct CourseRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let occurrence: Occurrence
    var timeZoneID = "Asia/Shanghai"
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(Display.time(occurrence.start, zone: timeZoneID)).font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text(Display.time(occurrence.end, zone: timeZoneID)).font(.caption).foregroundStyle(.secondary)
            }.monospacedDigit().frame(width: typeSize.isAccessibilitySize ? nil : 48, alignment: .leading)
            if !typeSize.isAccessibilitySize { CourseDot(colorIndex: occurrence.colorIndex) }
            VStack(alignment: .leading, spacing: 5) {
                Text(occurrence.courseName).font(.headline).foregroundStyle(.primary)
                Label(occurrence.location.isEmpty ? "地点待补充" : occurrence.location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 2) }
            if occurrence.isException { Text("已调整").font(.caption2).foregroundStyle(Palette.accent) }
            if !typeSize.isAccessibilitySize { Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
        }.padding(.vertical, 7).contentShape(Rectangle())
    }
}

struct WeekSelectionGrid: View {
    @Binding var selected: [Int]
    var count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("全选") { selected = Array(1...max(1, count)) }
                Button("单周") { selected = (1...max(1, count)).filter { $0 % 2 == 1 } }
                Button("双周") { selected = (1...max(1, count)).filter { $0 % 2 == 0 } }
                Spacer()
                Button("清空") { selected = [] }
            }.font(.subheadline).buttonStyle(.borderless)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 39), spacing: 8)], spacing: 8) {
                ForEach(1...max(1, count), id: \.self) { week in
                    Button {
                        if selected.contains(week) { selected.removeAll { $0 == week } } else { selected.append(week); selected.sort() }
                    } label: {
                        Text("\(week)").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(height: 36)
                            .foregroundStyle(selected.contains(week) ? Color(.systemBackground) : Color.primary)
                            .background(selected.contains(week) ? Palette.accent : Color.secondary.opacity(0.09), in: .rect(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel("第 \(week) 周").accessibilityAddTraits(selected.contains(week) ? .isSelected : [])
                }
            }
            Text(WeekSelection.summary(selected)).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}

struct MinutePicker: View {
    let title: String
    @Binding var minute: Int
    private var wallClockCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }
    private var date: Binding<Date> {
        // Minutes represent a school's wall clock, not an instant in the phone's time zone.
        Binding(get: { Date(timeIntervalSince1970: 946_684_800 + Double(minute * 60)) }, set: {
            minute = wallClockCalendar.component(.hour, from: $0) * 60 + wallClockCalendar.component(.minute, from: $0)
        })
    }
    var body: some View {
        DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.calendar, wallClockCalendar)
            .environment(\.timeZone, .gmt)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable { var id = UUID(); var url: URL }
