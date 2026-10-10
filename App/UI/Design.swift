import SwiftUI
import CourseKit

/// Shared shape and spacing values, so cards, blocks and tiles stay consistent across screens.
enum Theme {
    static let cardRadius: CGFloat = 22
    static let innerRadius: CGFloat = 14
    static let blockRadius: CGFloat = 9
    static let cardPadding: CGFloat = 18
}

extension View {
    /// The standard grouped card: system secondary background with continuous corners.
    func cardBackground(radius: CGFloat = Theme.cardRadius) -> some View {
        background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: radius, style: .continuous))
    }
}

enum Display {
    static let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static func format(_ date: Date, style: Date.FormatStyle, zone: String) -> String { var style = style; style.timeZone = TimeZone(identifier: zone) ?? .gmt; style.locale = Locale(identifier: "zh_CN"); return date.formatted(style) }
    static func time(_ date: Date, zone: String = "Asia/Shanghai") -> String {
        format(date, style: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits), zone: zone)
    }
    static func minutes(_ date: Date, in semester: Semester) -> Int { let v = semester.calendar.dateComponents([.hour, .minute], from: date); return (v.hour ?? 0) * 60 + (v.minute ?? 0) }
    static func day(_ date: Date, in semester: Semester) -> String { format(date, style: .dateTime.month(.twoDigits).day(.twoDigits), zone: semester.timeZoneID) }
    static func weekday(_ date: Date, in semester: Semester) -> String { weekdays[(semester.calendar.component(.weekday, from: date) + 5) % 7] }
    /// "今天", "明天", "后天", otherwise "10/21 周三" — in the school's calendar.
    static func relativeDay(_ date: Date, now: Date, in semester: Semester) -> String {
        let calendar = semester.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case -1: return "昨天"
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default: return "\(day(date, in: semester)) \(weekday(date, in: semester))"
        }
    }
    /// "今天 16:00" style start time.
    static func relativeStart(_ date: Date, now: Date, in semester: Semester) -> String {
        "\(relativeDay(date, now: now, in: semester)) \(time(date, zone: semester.timeZoneID))"
    }
}

/// The app icon, for in-app branding.
struct BrandMark: View {
    var size: CGFloat = 56
    var body: some View {
        Image("BrandMark").resizable().interpolation(.high).frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// A course's color as a rounded tile like a contact avatar: its first character by default,
/// or the custom text, icon or photo chosen for the course.
struct CourseAvatar: View {
    let name: String
    let colorIndex: Int
    var style: CourseAvatarStyle? = nil
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let data = style?.image, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let symbol = style?.symbol, UIImage(systemName: symbol) != nil {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold))
            } else {
                let text = style?.text.flatMap { $0.isEmpty ? nil : $0 } ?? name.first.map(String.init) ?? "课"
                Text(text).font(.system(size: size * (text.count > 1 ? 0.34 : 0.44), weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(Palette.solid(colorIndex).gradient)
        .clipShape(.rect(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }
}

extension CourseAvatar {
    init(course: Course, size: CGFloat = 40) { self.init(name: course.name, colorIndex: course.colorIndex, style: course.avatar, size: size) }
}

struct CourseDot: View {
    var colorIndex: Int
    var height: CGFloat = 36
    var body: some View { Capsule().fill(Palette.color(colorIndex)).frame(width: 4, height: height).accessibilityHidden(true) }
}

/// A small capsule label for a lesson state, with an optional live pulse.
struct StatusPill: View {
    let text: String
    let color: Color
    var live = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill").font(.system(size: 6)).symbolEffect(.pulse, options: .repeating, isActive: live)
            Text(text)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.13), in: .capsule)
    }
}

/// How far a lesson has run: one bar per teaching segment, with a gap where each break falls,
/// so a back-to-back lesson shows its whole length instead of only the current period.
struct ClassProgressBar: View {
    var progress: LessonProgress
    var color: Color
    var body: some View {
        WeightedRow(weights: progress.parts.map(\.weight)) {
            ForEach(Array(progress.parts.enumerated()), id: \.offset) { _, part in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(color.opacity(0.15))
                        if part.fraction > 0 { Capsule().fill(color.gradient).frame(width: max(6, geometry.size.width * part.fraction)) }
                    }
                }
                .frame(height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("课程进度")
        .accessibilityValue((progress.parts.count > 1 ? "第 \(progress.position) 节，共 \(progress.parts.count) 节，" : "") + "\(Int((progress.overall * 100).rounded()))%")
    }
}

/// An iOS Settings–style colored icon tile.
struct SettingsIcon: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 29
    let systemImage: String
    let color: Color
    var body: some View {
        let side = min(self.side, 40)
        Image(systemName: systemImage)
            .font(.system(size: side * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: .rect(cornerRadius: side * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A settings row label: icon tile, title, optional value and disclosure chevron.
struct SettingsLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var value: String? = nil
    var showsChevron = false
    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemImage: systemImage, color: color)
            Text(title).foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            // Concrete label colors: inside a Button, hierarchical styles would take on the tint.
            if let value { Text(value).foregroundStyle(Color(.secondaryLabel)).lineLimit(1) }
            if showsChevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel)).accessibilityHidden(true) }
        }
        .contentShape(Rectangle())
    }
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
            if occurrence.isException {
                Text("已调整").font(.caption2.weight(.semibold)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.accent.opacity(0.12), in: .capsule)
            }
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
                        Text("\(week)").font(.subheadline.weight(.medium)).monospacedDigit().frame(maxWidth: .infinity).frame(height: 36)
                            .foregroundStyle(selected.contains(week) ? Color.white : Color.primary)
                            .background(selected.contains(week) ? AnyShapeStyle(Palette.accentSolid.gradient) : AnyShapeStyle(Color.secondary.opacity(0.09)), in: .rect(cornerRadius: 10, style: .continuous))
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
