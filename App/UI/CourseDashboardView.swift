import SwiftUI
import UIKit
import CourseKit

/// A full-screen, large-type view of the lesson in progress or the next one, readable at a glance
/// while cycling or looking for the classroom: where to go, how long is left and, once turned on,
/// how fast you are going. It follows the clock like the home card, and keeps the screen awake
/// while it is open.
struct CourseDashboardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    let occurrences: [Occurrence]
    let semester: Semester
    var pendingMakeup = false
    let onClose: () -> Void
    let onDetail: (Occurrence) -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 34
    @ScaledMetric(relativeTo: .largeTitle) private var locationSize: CGFloat = 46
    @ScaledMetric(relativeTo: .largeTitle) private var timeSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 60
    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 60

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = PreviewClock.now(context.date)
            let status = ScheduleEngine.status(at: now, occurrences: occurrences, semester: semester)
            let event = status.current ?? status.next
            let color = event.map { Palette.color($0.colorIndex) } ?? Palette.accent
            ScrollView {
                VStack(spacing: 14) {
                    header(status, event: event, color: color)
                    if let event {
                        lessonCard(event, color: color)
                        timeCard(event, status: status, color: color, now: now)
                        notices(status)
                        if let next = status.next, status.current != nil { nextCard(next, now: now) }
                    } else { emptyCard(status, now: now) }
                    SpeedometerCard(color: color)
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background {
                // A wash of the course color behind the top of the screen, fading into the grouped background.
                ZStack {
                    Color(.systemGroupedBackground)
                    LinearGradient(colors: [color.opacity(0.3), color.opacity(0)], startPoint: .top, endPoint: .center)
                }.ignoresSafeArea()
            }
        }
        .accessibilityIdentifier("course-dashboard")
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func header(_ status: CurrentStatus, event: Occurrence?, color: Color) -> some View {
        let tint = pendingMakeup ? Color.orange : color
        return HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "circle.fill").font(.system(size: 9)).symbolEffect(.pulse, options: .repeating, isActive: status.kind == .inClass)
                Text(pendingMakeup ? "调休课程待定" : CurrentCourseCard.title(status.kind))
            }
            .font(.headline).foregroundStyle(tint)
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(tint.opacity(0.14), in: .capsule)
            Spacer(minLength: 0)
            if let event {
                Button { onDetail(event) } label: { Label("详情", systemImage: "info.circle").font(.headline).padding(.horizontal, 4).frame(minHeight: 36) }
                    .buttonStyle(.glass).accessibilityIdentifier("dashboard-detail")
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.title3.weight(.bold)).frame(width: 36, height: 36) }
                .buttonStyle(.glass).accessibilityLabel("关闭").accessibilityIdentifier("dashboard-close")
        }
    }

    /// What and where: the course with its avatar, then the room in the largest type on screen.
    private func lessonCard(_ event: Occurrence, color: Color) -> some View {
        DashboardPanel(tint: color) {
            HStack(spacing: 14) {
                // At accessibility sizes the name needs the whole width.
                if !typeSize.isAccessibilitySize {
                    CourseAvatar(name: event.courseName, colorIndex: event.colorIndex, style: store.snapshot.courses.first(where: { $0.id == event.courseID })?.avatar, size: min(avatarSize, 84))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.courseName)
                        .font(.system(size: nameSize, weight: .heavy, design: .rounded))
                        .lineLimit(3).minimumScaleFactor(0.5)
                    if !event.teacher.isEmpty { Label(event.teacher, systemImage: "person.fill").font(.title3.weight(.medium)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .accessibilityElement(children: .combine)
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 4) {
                Label("上课地点", systemImage: "mappin.and.ellipse").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(event.location.isEmpty ? "地点待补充" : event.location)
                    .font(.system(size: locationSize, weight: .bold, design: .rounded))
                    .foregroundStyle(event.location.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                    .lineLimit(3).minimumScaleFactor(0.45)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// When: a live countdown with the lesson's progress, or the start time when it is still far off.
    private func timeCard(_ event: Occurrence, status: CurrentStatus, color: Color, now: Date) -> some View {
        let zone = semester.timeZoneID
        let range = "\(Display.time(event.start, zone: zone))–\(Display.time(event.end, zone: zone))"
        let day = Display.relativeDay(event.start, now: now, in: semester)
        let progress = status.current?.progress(at: now)
        // Like the home card: a countdown during the lesson, or within four hours of it.
        let target = CurrentCourseCard.countdownTarget(status).flatMap { $0 > now && (status.current != nil || $0.timeIntervalSince(now) < 4 * 3600) ? $0 : nil }
        let title = target == nil ? "上课时间" : (status.kind == .inClass ? "本节剩余" : (status.kind == .onBreak ? "距继续上课" : "距开始上课"))
        return DashboardPanel {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(title, systemImage: target == nil ? "clock" : "timer").font(.headline).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let progress, progress.parts.count > 1 {
                        let done = progress.parts.filter { $0.fraction >= 1 }.count
                        Text(status.kind == .onBreak ? "已上 \(done)/\(progress.parts.count) 节" : "第 \(progress.position)/\(progress.parts.count) 节")
                            .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(color.opacity(0.14), in: .capsule)
                    }
                }
                if let target {
                    CurrentCourseCard.countdown(to: target, from: now)
                        .font(.system(size: countdownSize, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
                } else {
                    Text(range).font(.system(size: timeSize, weight: .bold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
            }
            .accessibilityElement(children: .combine)
            if let progress {
                VStack(spacing: 8) {
                    ClassProgressBar(progress: progress, color: color, height: 10)
                    HStack {
                        Text(Display.time(event.start, zone: zone))
                        Spacer(minLength: 8)
                        Text("\(Display.time(event.end, zone: zone)) 下课")
                    }
                    .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if target != nil {
                Text(day == "今天" ? "\(range) 上课" : "\(day) \(range) · 第 \(event.week) 周").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            } else if day != "今天" {
                Text("\(day) · 第 \(event.week) 周").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func notices(_ status: CurrentStatus) -> some View {
        if pendingMakeup { notice("原课表待核对，确认学校安排后更新课程与提醒。", systemImage: "exclamationmark.circle") }
        if !status.conflicts.isEmpty { notice("此时还有重叠课程，请检查安排", systemImage: "exclamationmark.triangle") }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.headline).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func nextCard(_ next: Occurrence, now: Date) -> some View {
        let tint = Palette.color(next.colorIndex)
        return DashboardPanel {
            Label("接下来", systemImage: "arrow.turn.down.right").font(.headline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(next.courseName).font(.title2.weight(.bold)).lineLimit(2)
                if !next.location.isEmpty { Label(next.location, systemImage: "mappin").font(.title3.weight(.semibold)).foregroundStyle(tint) }
                Text(Display.relativeStart(next.start, now: now, in: semester)).font(.headline).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.leading, 16)
            .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 5) }
            .accessibilityElement(children: .combine)
        }
    }

    private func emptyCard(_ status: CurrentStatus, now: Date) -> some View {
        DashboardPanel {
            Image(systemName: ScheduleTime.symbol(now: now, semester: semester)).font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 64, height: 64).background(Palette.accent.opacity(0.12), in: .circle)
                .accessibilityHidden(true)
            Text(status.kind == .afterSemester ? "这一学期，辛苦了。" : "现在没有课")
                .font(.system(size: nameSize, weight: .heavy, design: .rounded)).minimumScaleFactor(0.5)
            Text(status.kind == .afterSemester ? "可以在设置中添加新学期。" : "有课时，这里会显示当前和下一节课。").font(.title3).foregroundStyle(.secondary)
        }
    }
}

/// A dashboard card: the grouped background with an optional wash of the course color and a hairline edge.
struct DashboardPanel<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Color(.secondarySystemGroupedBackground))
                    .overlay { if let tint { shape.fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)) } }
                    .overlay { shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
            }
    }
}
