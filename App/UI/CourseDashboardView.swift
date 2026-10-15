import SwiftUI
import UIKit
import CourseKit

/// A full-screen, large-type view of the lesson in progress or the next one, readable at a glance
/// while cycling or looking for the classroom. It follows the clock like the home card, and keeps
/// the screen awake while it is open.
struct CourseDashboardView: View {
    let occurrences: [Occurrence]
    let semester: Semester
    var pendingMakeup = false
    let onClose: () -> Void
    let onDetail: (Occurrence) -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 44
    @ScaledMetric(relativeTo: .largeTitle) private var locationSize: CGFloat = 54
    @ScaledMetric(relativeTo: .largeTitle) private var timeSize: CGFloat = 42
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 64

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = PreviewClock.now(context.date)
            let status = ScheduleEngine.status(at: now, occurrences: occurrences, semester: semester)
            let event = status.current ?? status.next
            let color = event.map { Palette.color($0.colorIndex) } ?? Palette.accent
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header(status, event: event, color: color)
                    if let event { lesson(event, status: status, color: color, now: now) }
                    else { empty(status) }
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background {
                ZStack {
                    Color(.systemBackground)
                    LinearGradient(colors: [color.opacity(0.24), color.opacity(0.04)], startPoint: .top, endPoint: .bottom)
                }.ignoresSafeArea()
            }
        }
        .accessibilityIdentifier("course-dashboard")
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func header(_ status: CurrentStatus, event: Occurrence?, color: Color) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill").font(.system(size: 10)).symbolEffect(.pulse, options: .repeating, isActive: status.kind == .inClass)
                Text(pendingMakeup ? "调休课程待定" : CurrentCourseCard.title(status.kind))
            }
            .font(.title3.weight(.bold)).foregroundStyle(pendingMakeup ? Color.orange : color)
            .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            if let event {
                Button { onDetail(event) } label: { Label("详情", systemImage: "info.circle").font(.headline).padding(.horizontal, 4).frame(minHeight: 36) }
                    .buttonStyle(.glass).accessibilityIdentifier("dashboard-detail")
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.title3.weight(.bold)).frame(width: 36, height: 36) }
                .buttonStyle(.glass).accessibilityLabel("关闭").accessibilityIdentifier("dashboard-close")
        }
    }

    @ViewBuilder private func lesson(_ event: Occurrence, status: CurrentStatus, color: Color, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.courseName)
                .font(.system(size: nameSize, weight: .heavy, design: .rounded))
                .lineLimit(3).minimumScaleFactor(0.5)
            if !event.teacher.isEmpty { Label(event.teacher, systemImage: "person.fill").font(.title2.weight(.medium)).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)

        block("地点", systemImage: "mappin.and.ellipse") {
            Text(event.location.isEmpty ? "地点待补充" : event.location)
                .font(.system(size: locationSize, weight: .bold, design: .rounded))
                .foregroundStyle(event.location.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                .lineLimit(3).minimumScaleFactor(0.45)
        }

        block("时间", systemImage: "clock") {
            let day = Display.relativeDay(event.start, now: now, in: semester)
            if day != "今天" { Text("\(day) · 第 \(event.week) 周").font(.title2.weight(.semibold)) }
            Text("\(Display.time(event.start, zone: semester.timeZoneID))–\(Display.time(event.end, zone: semester.timeZoneID))")
                .font(.system(size: timeSize, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
        }

        if let target = CurrentCourseCard.countdownTarget(status), target > now, status.current != nil || target.timeIntervalSince(now) < 4 * 3600 {
            block(status.kind == .inClass ? "本节剩余" : (status.kind == .onBreak ? "距继续上课" : "距开始上课"), systemImage: "timer") {
                CurrentCourseCard.countdown(to: target, from: now)
                    .font(.system(size: countdownSize, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
            }
        }

        if let progress = status.current?.progress(at: now) {
            VStack(alignment: .leading, spacing: 8) {
                ClassProgressBar(progress: progress, color: color)
                if progress.parts.count > 1 {
                    let done = progress.parts.filter { $0.fraction >= 1 }.count
                    Text(status.kind == .onBreak ? "已上 \(done)/\(progress.parts.count) 节" : "第 \(progress.position)/\(progress.parts.count) 节")
                        .font(.title3.weight(.semibold)).foregroundStyle(color).monospacedDigit()
                }
            }
        }

        if pendingMakeup { Label("原课表待核对，确认学校安排后更新课程与提醒。", systemImage: "exclamationmark.circle").font(.title3).foregroundStyle(.orange) }
        if !status.conflicts.isEmpty { Label("此时还有重叠课程，请检查安排", systemImage: "exclamationmark.triangle").font(.title3).foregroundStyle(.orange) }

        if let next = status.next, status.current != nil {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("接下来").font(.headline).foregroundStyle(.secondary)
                Text(next.courseName).font(.title.weight(.bold)).lineLimit(2)
                if !next.location.isEmpty { Label(next.location, systemImage: "mappin").font(.title2.weight(.semibold)).foregroundStyle(Palette.color(next.colorIndex)) }
                Text(Display.relativeStart(next.start, now: now, in: semester)).font(.title3.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func empty(_ status: CurrentStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status.kind == .afterSemester ? "这一学期，辛苦了。" : "现在没有课")
                .font(.system(size: nameSize, weight: .heavy, design: .rounded)).minimumScaleFactor(0.5)
            Text(status.kind == .afterSemester ? "可以在设置中添加新学期。" : "有课时，这里会显示当前和下一节课。").font(.title3).foregroundStyle(.secondary)
        }
    }

    private func block<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.headline).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
