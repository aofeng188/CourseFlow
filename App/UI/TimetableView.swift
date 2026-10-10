import SwiftUI
import CourseKit

struct TimetableView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onImport: () -> Void
    var onSetup: () -> Void
    var onCourse: (Occurrence) -> Void
    @State private var week = 1
    /// The current teaching week when `week` was last synced to it; nil until first shown.
    @State private var syncedCurrentWeek: Int?
    @State private var showWeeks = false
    @State private var listMode = false
    @State private var shareFile: SharedFile?
    @State private var holidaySheet: OfficialHolidayGroup?
    @Environment(\.scenePhase) private var scenePhase
    private var weekEvents: [Occurrence] {
        guard let semester = store.semester else { return [] }
        let start = ScheduleEngine.date(week: week, weekday: 1, semester: semester)
        let end = semester.calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return store.occurrences.filter { $0.start >= start && $0.start < end }
    }
    var body: some View {
        Group {
            if let semester = store.semester {
                TimelineView(.everyMinute) { context in
                    let now = PreviewClock.now(scenePhase == .active ? .now : context.date)
                    ScrollView {
                        VStack(spacing: 16) {
                            HolidayBanner(semester: semester, now: now) { holidaySheet = $0 }
                            CurrentCourseCard(occurrences: store.occurrences, semester: semester, pendingMakeup: pendingMakeup(on: now, semester: semester), onCourse: onCourse)
                            weekControls(semester)
                            if listMode || typeSize.isAccessibilitySize { agenda(semester, now: now) }
                            else { WeekGrid(semester: semester, week: week, occurrences: weekEvents, bells: store.bells, hideEmptyWeekends: store.preferences.hideEmptyWeekends, now: now, holidayDays: semester.holidayHintsEnabled == false ? [] : store.holidays.days(for: semester), pendingMakeupKeys: pendingKeys(semester), onCourse: onCourse) }
                            if semester.timeZoneID != TimeZone.current.identifier {
                                Label("按学校时间显示 · \(TimeZonePicker.title(for: semester.timeZoneID))", systemImage: "globe.asia.australia").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
                    }
                    .background(Color(.systemGroupedBackground))
                    .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                        if abs(value.translation.width) > abs(value.translation.height) * 1.8 { changeWeek(value.translation.width < 0 ? 1 : -1, semester: semester) }
                    })
                    .onChange(of: currentWeek(semester, at: now)) { followCurrentWeek() }
                    .navigationTitle(Display.format(now, style: .dateTime.month(.wide).day().weekday(.wide), zone: semester.timeZoneID))
                    .navigationSubtitle(subtitle(semester, now: now))
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(listMode ? "显示周课表" : "显示日程列表", systemImage: listMode ? "calendar" : "list.bullet") { listMode.toggle() }
                            Button("分享本周图片", systemImage: "photo") { exportWeek(semester, pdf: false) }
                            Button("分享本周 PDF", systemImage: "doc") { exportWeek(semester, pdf: true) }
                            if let label = store.undoLabel { Button("撤销“\(label)”", systemImage: "arrow.uturn.backward") { store.undo() } }
                        } label: { Image(systemName: "ellipsis").accessibilityLabel("课表显示与分享") }
                    }
                }
            } else { welcome.navigationTitle("课序") }
        }
        .navigationBarTitleDisplayMode(store.semester == nil ? .inline : .large)
        .onAppear { if syncedCurrentWeek == nil { resetWeek() } else { followCurrentWeek() }; if ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--preview-agenda") { listMode = true } }
        .onChange(of: store.semester?.id) { resetWeek() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { followCurrentWeek() } }
        .sheet(isPresented: $showWeeks) { if let semester = store.semester { weekPicker(semester) } }
        .sheet(item: $shareFile) { ShareSheet(items: [$0.url]) }
        .sheet(item: $holidaySheet) { group in if let semester = store.semester { HolidayGroupConfirmationView(semester: semester, group: group) } }
    }
    private func subtitle(_ semester: Semester, now: Date) -> String {
        let raw = ScheduleEngine.weekNumber(on: now, semester: semester)
        if raw < 1 { return "\(semester.name) · 尚未开学" }
        if raw > semester.weekCount { return "\(semester.name) · 已结束" }
        return "第 \(raw) 周 · \(semester.name)"
    }
    @ViewBuilder private func weekControls(_ semester: Semester) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 16) {
                Button("第 \(week) 周 · 选择教学周") { showWeeks = true }
                    .font(.headline).accessibilityIdentifier("week-picker")
                HStack {
                    Button("上一周") { changeWeek(-1, semester: semester) }.disabled(week == 1)
                    Spacer()
                    Button("下一周") { changeWeek(1, semester: semester) }.disabled(week == semester.weekCount)
                }.font(.body)
                if week != currentWeek(semester) {
                    Button("回到本周") { resetWeek() }.font(.body)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    Button { changeWeek(-1, semester: semester) } label: { Image(systemName: "chevron.left").fontWeight(.semibold).frame(width: 36, height: 38) }.disabled(week == 1).accessibilityLabel("上一周")
                    Button { showWeeks = true } label: {
                        HStack(spacing: 5) { Text("第 \(week) 周").font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1); Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                            .padding(.horizontal, 4).frame(height: 38)
                    }.accessibilityIdentifier("week-picker")
                    Button { changeWeek(1, semester: semester) } label: { Image(systemName: "chevron.right").fontWeight(.semibold).frame(width: 36, height: 38) }.disabled(week == semester.weekCount).accessibilityLabel("下一周")
                }.buttonStyle(.plain).glassEffect().fixedSize().layoutPriority(2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(weekRange(semester)).font(.caption.weight(.medium)).monospacedDigit()
                    Text(weekEvents.isEmpty ? "没有课" : "\(weekEvents.count) 次课").font(.caption2).foregroundStyle(.secondary)
                }.lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if week != currentWeek(semester) {
                    Button("回到本周") { resetWeek() }.font(.subheadline.weight(.medium)).buttonStyle(.glass).fixedSize().layoutPriority(1)
                }
            }
        }
    }
    private func weekRange(_ semester: Semester) -> String {
        let start = ScheduleEngine.date(week: week, weekday: 1, semester: semester)
        let end = semester.calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return "\(Display.day(start, in: semester)) – \(Display.day(end, in: semester))"
    }
    private func weekPicker(_ semester: Semester) -> some View {
        let current = currentWeek(semester)
        return NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                    ForEach(1...semester.weekCount, id: \.self) { value in
                        let selected = value == week
                        Button { week = value; showWeeks = false } label: {
                            VStack(spacing: 5) {
                                Text("第 \(value) 周").font(.headline).monospacedDigit()
                                Text(value == current ? "本周" : Display.day(ScheduleEngine.date(week: value, weekday: 1, semester: semester), in: semester))
                                    .font(.caption.weight(value == current ? .semibold : .regular)).monospacedDigit()
                                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : (value == current ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary)))
                            }
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background { if selected { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.accentSolid.gradient) } else { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)) } }
                            .overlay { if value == current && !selected { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.accent.opacity(0.5), lineWidth: 1.5) } }
                        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding()
            }.background(Color(.systemGroupedBackground)).navigationTitle("选择教学周").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showWeeks = false } } }
        }.presentationDetents([.medium, .large])
    }
    private func pendingKeys(_ semester: Semester) -> Set<String> {
        Set(store.holidays.days(for: semester).filter { $0.kind == .makeup && HolidayCalendar.isPending($0, semester: semester, snapshot: store.snapshot) }.map(\.dateKey))
    }
    private func pendingMakeup(on date: Date, semester: Semester) -> Bool {
        pendingKeys(semester).contains(HolidayCalendar.key(date, calendar: semester.calendar))
    }
    private func agenda(_ semester: Semester, now: Date) -> some View {
        AgendaView(semester: semester, week: week, occurrences: weekEvents, now: now,
                   holidayDays: semester.holidayHintsEnabled == false ? [] : store.holidays.days(for: semester),
                   pendingMakeupKeys: pendingKeys(semester), onCourse: onCourse)
    }
    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                BrandMark(size: 78).shadow(color: Palette.accent.opacity(0.28), radius: 18, y: 10).padding(.top, 20)
                VStack(alignment: .leading, spacing: 12) {
                    Text("每一节课，\n都心中有数。").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("把课表带进来，留更多时间给大学生活。上什么、在哪上、还有多久，一眼就知道。").font(.body).foregroundStyle(.secondary).lineSpacing(4)
                }
                VStack(alignment: .leading, spacing: 16) {
                    feature("图片、PDF、Excel，多种方式导入", systemImage: "square.and.arrow.down", color: Palette.color(0))
                    feature("先核对，再保存，时间由你确认", systemImage: "checklist", color: Palette.color(1))
                    feature("原生提醒与日历，安排好每一周", systemImage: "bell.badge", color: Palette.color(2))
                }
                VStack(spacing: 14) {
                    Button(action: onSetup) { Text("设置我的第一个学期").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9) }.buttonStyle(.glassProminent).accessibilityIdentifier("setup-semester")
                    Button { store.loadExample() } label: { Text("先体验示例课表").frame(maxWidth: .infinity) }.font(.subheadline.weight(.medium)).accessibilityIdentifier("load-example")
                    Text("示例仅用于体验，你可以随时删除或添加自己的学期。").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity)
            }.padding(26).frame(maxWidth: 560)
        }.frame(maxWidth: .infinity).background(Color(.systemGroupedBackground))
    }
    private func feature(_ title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 14) {
            SettingsIcon(systemImage: systemImage, color: color)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private func currentWeek(_ semester: Semester, at date: Date = .now) -> Int {
        max(1, min(semester.weekCount, ScheduleEngine.weekNumber(on: PreviewClock.now(date), semester: semester)))
    }
    private func resetWeek() {
        guard let semester = store.semester else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { week = currentWeek(semester) }
        syncedCurrentWeek = currentWeek(semester)
    }
    /// Advances to a new teaching week (e.g. after a weekend in the background) only if the
    /// user was looking at the current week; a week they browsed to stays put.
    private func followCurrentWeek() {
        guard let semester = store.semester else { return }
        let current = currentWeek(semester)
        if week == syncedCurrentWeek { week = current }
        syncedCurrentWeek = current
    }
    private func changeWeek(_ offset: Int, semester: Semester) { withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { week = max(1, min(semester.weekCount, week + offset)) } }
    private func exportWeek(_ semester: Semester, pdf: Bool) {
        let view = VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(semester.name) · 第 \(week) 周").font(.title.bold())
                Spacer()
                Text(weekRange(semester)).font(.title3).foregroundStyle(.secondary)
            }
            WeekGrid(semester: semester, week: week, occurrences: weekEvents, bells: store.bells, hideEmptyWeekends: false, onCourse: { _ in })
            Text("课序 · \(semester.timeZoneID)").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 900).background(Color(.systemGroupedBackground)).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("课表-第\(week)周.\(pdf ? "pdf" : "png")")
        do {
            if pdf {
                renderer.render { size, render in
                    var rect = CGRect(origin: .zero, size: size)
                    if let context = CGContext(url as CFURL, mediaBox: &rect, nil) { context.beginPDFPage(nil); render(context); context.endPDFPage(); context.closePDF() }
                }
                guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteUnknown) }
            } else { guard let data = renderer.uiImage?.pngData() else { throw CocoaError(.fileWriteUnknown) }; try data.write(to: url) }
            shareFile = SharedFile(url: url)
        } catch { store.errorMessage = "无法导出课表：\(error.localizedDescription)" }
    }
}

struct CurrentCourseCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let occurrences: [Occurrence]
    let semester: Semester
    var pendingMakeup = false
    let onCourse: (Occurrence) -> Void
    var body: some View {
        // Lesson boundaries fall on whole minutes and the countdown text updates itself,
        // so a per-minute timeline is exact without re-evaluating every second.
        TimelineView(.everyMinute) { context in
            let now = PreviewClock.now(context.date)
            let status = ScheduleEngine.status(at: now, occurrences: occurrences, semester: semester)
            let event = status.current ?? status.next
            let color = event.map { Palette.color($0.colorIndex) } ?? Palette.accent
            let active = [CurrentStatus.Kind.inClass, .onBreak, .upcoming].contains(status.kind)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    StatusPill(text: pendingMakeup ? "调休课程待定" : title(status.kind), color: pendingMakeup ? .orange : (active ? color : .secondary), live: status.kind == .inClass)
                    Spacer(minLength: 0)
                    if let current = status.current { Text("\(Display.time(current.start, zone: semester.timeZoneID))–\(Display.time(current.end, zone: semester.timeZoneID))").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                if pendingMakeup { Text("原课表待核对，确认学校安排后更新课程与提醒。").font(.caption).foregroundStyle(.orange) }
                if let event {
                    lesson(event, status: status, now: now)
                    if let progress = status.current?.progress(at: now) { lessonProgress(progress, status: status, color: color, now: now) }
                    if !status.conflicts.isEmpty { Label("此时还有重叠课程，请检查安排", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    footer(event, status: status, now: now)
                } else { empty(status, now: now) }
            }
            .padding(Theme.cardPadding).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(LinearGradient(colors: [color.opacity(active ? 0.17 : 0.08), color.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .onTapGesture { if let event { onCourse(event) } }
            .accessibilityElement(children: .combine)
        }
    }
    @ViewBuilder private func lesson(_ event: Occurrence, status: CurrentStatus, now: Date) -> some View {
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 6) {
                Text(event.courseName).font(.title2.weight(.bold)).lineLimit(2)
                HStack(spacing: 12) {
                    Label(event.location.isEmpty ? "地点待补充" : event.location, systemImage: "mappin")
                    if !event.teacher.isEmpty && !large { Label(event.teacher, systemImage: "person").lineLimit(1) }
                }.font(.subheadline).foregroundStyle(.secondary).lineLimit(large ? nil : 1)
            }
            if !large { Spacer(minLength: 0) }
            if let target = countdownTarget(status), target > now {
                VStack(alignment: large ? .leading : .trailing, spacing: 3) {
                    if status.current != nil || target.timeIntervalSince(now) < 4 * 3600 {
                        countdown(to: target, from: now).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).multilineTextAlignment(large ? .leading : .trailing)
                        Text(status.kind == .inClass ? "本节剩余" : (status.kind == .onBreak ? "后继续上课" : "后开始上课")).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(Display.relativeDay(target, now: now, in: semester)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(Display.time(target, zone: semester.timeZoneID)).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
                    }
                }.frame(maxWidth: large ? .infinity : 120, alignment: large ? .leading : .trailing)
            }
        }
    }
    /// The whole lesson's bar; a back-to-back lesson also says which period this is and when it all ends.
    @ViewBuilder private func lessonProgress(_ progress: LessonProgress, status: CurrentStatus, color: Color, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ClassProgressBar(progress: progress, color: color)
            if progress.parts.count > 1 {
                let done = progress.parts.filter { $0.fraction >= 1 }.count
                let minutes = Int((progress.end.timeIntervalSince(now) / 60).rounded(.up))
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    Text(status.kind == .onBreak ? "已上 \(done)/\(progress.parts.count) 节" : "第 \(progress.position)/\(progress.parts.count) 节").fontWeight(.semibold).foregroundStyle(color)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if minutes > 0 { Text("距全部下课 " + (minutes >= 60 ? "\(minutes / 60) 小时" + (minutes % 60 > 0 ? " \(minutes % 60) 分" : "") : "\(minutes) 分钟")).foregroundStyle(.secondary) }
                }.font(.caption).monospacedDigit()
            }
        }
    }
    @ViewBuilder private func footer(_ event: Occurrence, status: CurrentStatus, now: Date) -> some View {
        if let next = status.next, status.current != nil {
            Divider().opacity(0.6)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            layout {
                Text("接下来").foregroundStyle(.secondary)
                CourseDot(colorIndex: next.colorIndex, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.courseName).fontWeight(.semibold).lineLimit(1)
                    if !next.location.isEmpty { Text(next.location).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                Text(Display.relativeStart(next.start, now: now, in: semester)).fontWeight(.medium).monospacedDigit().foregroundStyle(.secondary)
            }.font(.footnote)
        } else if let nextSegment = status.nextSegment, status.kind == .inClass {
            Text("本课下一节 \(Display.time(nextSegment.start, zone: semester.timeZoneID)) 开始").font(.footnote).foregroundStyle(.secondary)
        } else if status.current == nil {
            Text("\(Display.relativeStart(event.start, now: now, in: semester)) 开始 · 第 \(event.week) 周").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func empty(_ status: CurrentStatus, now: Date) -> some View {
        HStack(spacing: 14) {
            Image(systemName: ScheduleTime.symbol(now: now, semester: semester)).font(.title2).foregroundStyle(Palette.accent)
                .frame(width: 48, height: 48).background(Palette.accent.opacity(0.12), in: .circle)
                .accessibilityIdentifier("day-night-icon").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.kind == .afterSemester ? "这一学期，辛苦了。" : "把时间留给自己。").font(.title3.weight(.semibold))
                Text(status.kind == .afterSemester ? "可以在设置中添加新学期。" : "添加课程后，这里会显示当前和下一节课。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
    private func title(_ kind: CurrentStatus.Kind) -> String {
        switch kind { case .inClass: "正在上课"; case .onBreak: "课间休息"; case .upcoming: "下一节课"; case .finishedToday: "今天的课已结束"; case .beforeSemester: "学期尚未开始"; case .afterSemester: "学期已结束"; case .empty: "今天，从容一点" }
    }
    /// A fixed preview clock shows the remaining time at that moment, so screenshots do not depend
    /// on the day the tests run; otherwise the system timer text counts down live.
    private func countdown(to target: Date, from now: Date) -> Text {
        guard PreviewClock.fixedDate != nil else { return Text(timerInterval: now...target, countsDown: true) }
        let remaining = Duration.seconds(Int(target.timeIntervalSince(now)))
        return Text(remaining.formatted(.time(pattern: remaining >= .seconds(3600) ? .hourMinuteSecond : .minuteSecond)))
    }
    private func countdownTarget(_ status: CurrentStatus) -> Date? { status.kind == .inClass ? status.segment?.end : (status.kind == .onBreak ? status.nextSegment?.start : status.next?.start) }
}

struct WeekGrid: View {
    var semester: Semester
    var week: Int
    var occurrences: [Occurrence]
    var bells: [BellSchedule]
    var hideEmptyWeekends: Bool
    var now: Date? = nil
    var holidayDays: [OfficialHolidayDay] = []
    var pendingMakeupKeys: Set<String> = []
    var onCourse: (Occurrence) -> Void
    @ScaledMetric(relativeTo: .caption) private var scaledRow: CGFloat = 54
    @ScaledMetric(relativeTo: .caption) private var scaledName: CGFloat = 12.5
    private let axis: CGFloat = 34
    private var rowHeight: CGFloat { min(max(scaledRow, 48), 72) }
    private var nameSize: CGFloat { min(max(scaledName, 11.5), 15) }
    private var detailSize: CGFloat { max(10, nameSize - 2) }
    private var periods: [Period] { ScheduleEngine.bellSchedule(on: ScheduleEngine.date(week: week, weekday: 1, semester: semester), semester: semester, schedules: bells)?.periods ?? [] }
    private func range(_ event: Occurrence) -> Range<Int> {
        let start = Display.minutes(event.start, in: semester)
        let end = semester.calendar.isDate(event.start, inSameDayAs: event.end) ? Display.minutes(event.end, in: semester) : 1440
        return start..<max(end, start + 1)
    }
    private var scale: TimelineScale {
        TimelineScale(periods: periods, lessons: occurrences.map(range), metrics: .init(periodHeight: Double(rowHeight), gapHeight: 4, longBreakHeight: 26, longBreakMinutes: 30))
    }
    private var days: [Int] {
        guard hideEmptyWeekends else { return Array(1...7) }
        return (1...7).filter { day in
            guard day >= 6 else { return true }
            let date = ScheduleEngine.date(week: week, weekday: day, semester: semester)
            let isToday = now.map { semester.calendar.isDate($0, inSameDayAs: date) } ?? false
            return isToday || pendingMakeupKeys.contains(HolidayCalendar.key(date, calendar: semester.calendar))
                || occurrences.contains { semester.calendar.isDate($0.start, inSameDayAs: date) }
        }
    }
    private var todayIndex: Int? {
        guard let now else { return nil }
        return days.firstIndex { semester.calendar.isDate(now, inSameDayAs: ScheduleEngine.date(week: week, weekday: $0, semester: semester)) }
    }
    var body: some View {
        let scale = scale
        let nowMinute = now.map { Display.minutes($0, in: semester) }
        let showsNow = todayIndex != nil && nowMinute != nil
        VStack(spacing: 8) {
            dayHeader
            if let now, showsNow, let nowMinute, nowMinute < scale.startMinute {
                NowMarker(now: now, semester: semester, note: "尚未进入课表时段").padding(.horizontal, 6)
            }
            GeometryReader { geometry in
                let column = (geometry.size.width - axis) / CGFloat(days.count)
                ZStack(alignment: .topLeading) {
                    if let todayIndex {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.accent.opacity(0.06))
                            .frame(width: column, height: CGFloat(scale.height))
                            .offset(x: axis + CGFloat(todayIndex) * column).allowsHitTesting(false)
                    }
                    ForEach(Array(scale.segments.enumerated()), id: \.offset) { _, segment in
                        rowDecoration(segment, width: geometry.size.width, nowMinute: showsNow ? nowMinute : nil)
                    }
                    // Behind the blocks: the lesson in progress is already marked, and the line never crosses its title.
                    if let now, let todayIndex, let nowMinute, (scale.startMinute...scale.endMinute).contains(nowMinute) {
                        GridNowLine(now: now, semester: semester, axis: axis, column: column, todayIndex: todayIndex, width: geometry.size.width)
                            .offset(y: CGFloat(scale.y(at: nowMinute)))
                    }
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        let date = ScheduleEngine.date(week: week, weekday: day, semester: semester)
                        let events = occurrences.filter { semester.calendar.isDate($0.start, inSameDayAs: date) }
                        let placements = OccurrenceLayout.lanes(for: events)
                        let pending = pendingMakeupKeys.contains(HolidayCalendar.key(date, calendar: semester.calendar))
                        ForEach(events) { event in
                            let placement = placements[event.id] ?? LanePlacement(lane: 0, laneCount: 1)
                            let laneWidth = column / CGFloat(max(1, placement.laneCount))
                            let span = range(event)
                            let top = CGFloat(scale.y(at: span.lowerBound))
                            let height = max(26, CGFloat(scale.y(at: span.upperBound)) - top - 3)
                            Button { onCourse(event) } label: { block(event, pending: pending, width: max(12, laneWidth - 3), height: height) }
                                .buttonStyle(.plain)
                                .offset(x: axis + CGFloat(index) * column + CGFloat(placement.lane) * laneWidth + 1.5, y: top + 1.5)
                                .accessibilityLabel("\(event.courseName)，\(Display.weekdays[day - 1])，\(Display.time(event.start, zone: semester.timeZoneID))至\(Display.time(event.end, zone: semester.timeZoneID))，\(event.location)")
                        }
                    }
                }
            }.frame(height: CGFloat(scale.height) + 3)
            if let now, showsNow, let nowMinute, nowMinute > scale.endMinute {
                NowMarker(now: now, semester: semester, note: "已超出课表时段").padding(.horizontal, 6)
            }
        }.padding(.vertical, 12).padding(.horizontal, 6).cardBackground()
    }
    private var dayHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(semester.calendar.component(.month, from: ScheduleEngine.date(week: week, weekday: 1, semester: semester)))\n月")
                .font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(width: axis).padding(.top, 2)
            ForEach(days, id: \.self) { day in
                let date = ScheduleEngine.date(week: week, weekday: day, semester: semester)
                let today = now.map { semester.calendar.isDate($0, inSameDayAs: date) } ?? false
                let key = HolidayCalendar.key(date, calendar: semester.calendar)
                let holiday = holidayDays.first { $0.dateKey == key }
                VStack(spacing: 3) {
                    Text(Display.weekdays[day - 1]).font(.system(size: 11, weight: today ? .semibold : .medium))
                        .foregroundStyle(today ? Palette.accent : .secondary)
                    Text("\(semester.calendar.component(.day, from: date))").font(.system(size: 15, weight: today ? .bold : .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(today ? Color.white : (day >= 6 ? Color.secondary : Color.primary))
                        .frame(width: 28, height: 28)
                        .background { if today { Circle().fill(Palette.accentSolid.gradient) } }
                    if pendingMakeupKeys.contains(key) { Text("课待定").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange) }
                    else if let holiday { Text(holiday.kind == .makeup ? "补班" : holiday.name).font(.system(size: 10)).foregroundStyle(holiday.kind == .makeup ? Color.secondary : Palette.now).lineLimit(1).minimumScaleFactor(0.8) }
                }.frame(maxWidth: .infinity)
            }
        }
    }
    @ViewBuilder private func rowDecoration(_ segment: TimelineScale.Segment, width: CGFloat, nowMinute: Int?) -> some View {
        let isNow = nowMinute.map { segment.startMinute <= $0 && $0 < segment.endMinute } ?? false
        let labelColor: Color = isNow ? Palette.now : .secondary
        switch segment.kind {
        case .period(let number):
            VStack(spacing: 1) {
                Text("\(number)").font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(Period.clock(segment.startMinute)).font(.system(size: 10)).opacity(isNow ? 1 : 0.7)
                Text(Period.clock(segment.endMinute)).font(.system(size: 10)).opacity(isNow ? 1 : 0.7)
            }
            .monospacedDigit().foregroundStyle(labelColor).frame(width: axis, height: CGFloat(segment.height))
            .offset(y: CGFloat(segment.y)).accessibilityHidden(true)
        case .hour:
            Text(Period.clock(segment.startMinute)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(labelColor)
                .frame(width: axis).offset(y: CGFloat(segment.y)).accessibilityHidden(true)
            Rectangle().fill(Color.primary.opacity(0.06)).frame(width: width - axis, height: 0.5).offset(x: axis, y: CGFloat(segment.y))
        case .gap:
            Rectangle().fill(Color.primary.opacity(0.06)).frame(width: width - axis, height: 0.5).offset(x: axis, y: CGFloat(segment.y + segment.height / 2))
        case .longBreak:
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.035))
                .frame(width: width - axis, height: max(0, CGFloat(segment.height) - 8)).offset(x: axis, y: CGFloat(segment.y) + 4)
            Text(breakName(segment.startMinute)).font(.system(size: 10, weight: isNow ? .semibold : .medium)).foregroundStyle(isNow ? Palette.now : Color.secondary.opacity(0.7))
                .frame(width: axis, height: CGFloat(segment.height)).offset(y: CGFloat(segment.y)).accessibilityHidden(true)
        case .open:
            EmptyView()
        }
    }
    private func breakName(_ minute: Int) -> String {
        switch minute {
        case 630..<840: "午休"
        case 990..<1170: "晚饭"
        default: "休息"
        }
    }
    private func block(_ event: Occurrence, pending: Bool, width: CGFloat, height: CGFloat) -> some View {
        let live = ScheduleTime.status(event, now: now)
        let past = now.map { event.end <= $0 } ?? false
        let shape = RoundedRectangle(cornerRadius: Theme.blockRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 3) {
            Text(event.courseName).font(.system(size: nameSize, weight: .semibold)).lineLimit(height > 96 ? 4 : (height > 60 ? 3 : 2))
            if !event.location.isEmpty && height > 44 { Text(event.location).font(.system(size: detailSize)).lineLimit(height > 100 ? 3 : 2).opacity(0.85) }
            if height > 150 && !event.teacher.isEmpty { Text(event.teacher).font(.system(size: detailSize)).lineLimit(1).opacity(0.7) }
            Spacer(minLength: 0)
            if live != nil || pending || event.isException {
                HStack(spacing: 3) {
                    if let live { Text(live == "课间休息" ? "课间" : "上课中").font(.system(size: 10, weight: .bold)).lineLimit(1) }
                    if pending { Text("待核对").font(.system(size: 10, weight: .semibold)).foregroundStyle(live == nil ? Color.orange : Color.white) }
                    if event.isException { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold)) }
                }
            }
        }
        .foregroundStyle(live != nil ? Color.white : Palette.color(event.colorIndex))
        .padding(.leading, live != nil ? 6 : 8).padding(.trailing, 3).padding(.vertical, 6)
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(shape)
        .background {
            if live != nil {
                shape.fill(Palette.solid(event.colorIndex).gradient).shadow(color: Palette.solid(event.colorIndex).opacity(0.35), radius: 6, y: 3)
            } else {
                shape.fill(Palette.fill(event.colorIndex))
                    .overlay(alignment: .leading) { Capsule().fill(Palette.color(event.colorIndex)).frame(width: 3).padding(.vertical, 6).padding(.leading, 2.5) }
            }
        }
        .opacity(past ? 0.5 : 1)
    }
}
