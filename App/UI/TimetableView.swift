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
                    VStack(spacing: 22) {
                        semesterHeading(semester, now: now)
                        HolidayBanner(semester: semester, now: now) { holidaySheet = $0 }
                        CurrentCourseCard(occurrences: store.occurrences, semester: semester, pendingMakeup: pendingMakeup(on: now, semester: semester), onCourse: onCourse)
                        weekControls(semester)
                        if listMode || typeSize.isAccessibilitySize { agenda(semester, now: now) }
                        else { WeekGrid(semester: semester, week: week, occurrences: weekEvents, bells: store.bells, hideEmptyWeekends: store.preferences.hideEmptyWeekends, now: now, holidayDays: semester.holidayHintsEnabled == false ? [] : store.holidays.days(for: semester), pendingMakeupKeys: pendingKeys(semester), onCourse: onCourse) }
                        Text("\(semester.name) · 学校时间 \(semester.timeZoneID)").font(.caption2).foregroundStyle(.tertiary).padding(.bottom, 20)
                    }.padding(.horizontal, 16).padding(.top, 8)
                }
                .background(Color(.systemGroupedBackground))
                .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                    if abs(value.translation.width) > abs(value.translation.height) * 1.8 { changeWeek(value.translation.width < 0 ? 1 : -1, semester: semester) }
                })
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(listMode ? "显示周课表" : "显示日程列表", systemImage: listMode ? "calendar" : "list.bullet") { listMode.toggle() }
                            Button("分享本周图片", systemImage: "photo") { exportWeek(semester, pdf: false) }
                            Button("分享本周 PDF", systemImage: "doc") { exportWeek(semester, pdf: true) }
                            if store.canUndo { Button("撤销最近修改", systemImage: "arrow.uturn.backward") { store.undo() } }
                        } label: { Image(systemName: "ellipsis").accessibilityLabel("课表显示与分享") }
                    }
                }
            } else { welcome }
        }
        .navigationTitle("课序")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { resetWeek(); if ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--preview-agenda") { listMode = true } }
        .onChange(of: store.semester?.id) { resetWeek() }
        .sheet(isPresented: $showWeeks) {
            if let semester = store.semester {
                NavigationStack {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 12) {
                            ForEach(1...semester.weekCount, id: \.self) { value in
                                Button { week = value; showWeeks = false } label: {
                                    VStack(spacing: 6) { Text("第 \(value) 周").font(.headline); Text(Display.day(ScheduleEngine.date(week: value, weekday: 1, semester: semester), in: semester)).font(.caption) }.frame(maxWidth: .infinity).padding(.vertical, 16).background(value == week ? Palette.accent.opacity(0.16) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                                }.buttonStyle(.plain)
                            }
                        }.padding()
                    }.background(Color(.systemGroupedBackground)).navigationTitle("选择教学周").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showWeeks = false } } }
                }.presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $shareFile) { ShareSheet(items: [$0.url]) }
        .sheet(item: $holidaySheet) { group in if let semester = store.semester { HolidayGroupConfirmationView(semester: semester, group: group) } }
    }
    private func semesterHeading(_ semester: Semester, now: Date) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Display.format(now, style: .dateTime.month(.wide).day().weekday(.wide), zone: semester.timeZoneID)).font(.title2.weight(.bold))
                Text(semester.name).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: ScheduleTime.symbol(now: now, semester: semester)).accessibilityIdentifier("day-night-icon").font(.title2.weight(.light)).foregroundStyle(Palette.accent).padding(12).background(Palette.accent.opacity(0.08), in: .circle).accessibilityHidden(true)
        }.padding(.horizontal, 3)
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
                if week != max(1, min(semester.weekCount, ScheduleEngine.weekNumber(on: PreviewClock.fixedDate ?? .now, semester: semester))) {
                    Button("回到本周") { resetWeek() }.font(.body)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                Button { changeWeek(-1, semester: semester) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 38) }.disabled(week == 1).accessibilityLabel("上一周")
                Button { showWeeks = true } label: { HStack(spacing: 5) { Text("第 \(week) 周").font(.subheadline.weight(.semibold)); Image(systemName: "chevron.down").font(.caption2.weight(.semibold)) }.padding(.horizontal, 4).frame(height: 38) }.accessibilityIdentifier("week-picker")
                Button { changeWeek(1, semester: semester) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 38) }.disabled(week == semester.weekCount).accessibilityLabel("下一周")
            }.buttonStyle(.plain).glassEffect()
            Spacer(minLength: 0)
            if week != max(1, min(semester.weekCount, ScheduleEngine.weekNumber(on: PreviewClock.fixedDate ?? .now, semester: semester))) {
                Button("本周") { resetWeek() }.font(.subheadline).buttonStyle(.glass)
            } else { Text("\(weekEvents.count) 次课").font(.caption).foregroundStyle(.secondary) }
        }
        }
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
            VStack(alignment: .leading, spacing: 28) {
                Spacer().frame(height: 25)
                Image(systemName: "calendar").font(.system(size: 48, weight: .light)).foregroundStyle(Palette.accent).padding(24).background(Palette.accent.opacity(0.09), in: .rect(cornerRadius: 30))
                VStack(alignment: .leading, spacing: 12) {
                    Text("每一节课，\n都心中有数。").font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("把课表带进来，留更多时间给大学生活。\n上什么、在哪上、还有多久，一眼就知道。") .font(.body).foregroundStyle(.secondary).lineSpacing(5)
                }
                VStack(alignment: .leading, spacing: 18) {
                    Label("图片、PDF、Excel，多种方式导入", systemImage: "square.and.arrow.down")
                    Label("先核对，再保存，时间由你确认", systemImage: "checkmark.viewfinder")
                    Label("原生提醒与日历，安排好每一周", systemImage: "bell.badge")
                }.font(.subheadline).foregroundStyle(.secondary)
                Button(action: onSetup) { Text("设置我的第一个学期").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9) }.buttonStyle(.glassProminent).accessibilityIdentifier("setup-semester")
                Button { store.loadExample() } label: { Text("先体验示例课表").frame(maxWidth: .infinity) }.font(.subheadline).accessibilityIdentifier("load-example")
                Text("示例仅用于体验，你可以随时删除或添加自己的学期。").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
            }.padding(26)
        }.background(Color(.systemGroupedBackground))
    }
    private func resetWeek() { if let semester = store.semester { week = max(1, min(semester.weekCount, ScheduleEngine.weekNumber(on: PreviewClock.fixedDate ?? .now, semester: semester))) } }
    private func changeWeek(_ offset: Int, semester: Semester) { withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { week = max(1, min(semester.weekCount, week + offset)) } }
    private func exportWeek(_ semester: Semester, pdf: Bool) {
        let view = VStack(alignment: .leading, spacing: 20) {
            Text("\(semester.name) · 第 \(week) 周").font(.title.bold())
            WeekGrid(semester: semester, week: week, occurrences: weekEvents, bells: store.bells, hideEmptyWeekends: false, onCourse: { _ in })
            Text("课序 · \(semester.timeZoneID)").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 900).background(.white).environment(\.colorScheme, .light)
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = PreviewClock.now(context.date)
            let status = ScheduleEngine.status(at: now, occurrences: occurrences, semester: semester)
            let event = status.current ?? status.next
            let color = Palette.color(event?.colorIndex ?? 0)
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    HStack(spacing: 6) { Circle().fill(color).frame(width: 6, height: 6); Text(pendingMakeup ? "调休课程待定" : title(status.kind)).font(.caption.weight(.semibold)) }.foregroundStyle(color)
                    Spacer()
                    if let current = status.current { Text("\(Display.time(current.start, zone: semester.timeZoneID))–\(Display.time(current.end, zone: semester.timeZoneID))").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                if pendingMakeup { Text("原课表待核对，确认学校安排后更新课程与提醒。").font(.caption).foregroundStyle(.orange) }
                if let event {
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                    layout {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(event.courseName).font(.title2.weight(.bold)).lineLimit(2)
                            Label(event.location.isEmpty ? "地点待补充" : event.location, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                        if let target = countdownTarget(status), target > now {
                            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                                if target.timeIntervalSince(now) < 86400 {
                                    Text(timerInterval: now...target, countsDown: true).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                                } else { Text(target, format: .dateTime.month().day()).font(.title3.weight(.semibold)) }
                                Text(status.kind == .inClass ? "本节剩余" : (status.kind == .onBreak ? "后继续上课" : "后开始上课")).font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 116, alignment: typeSize.isAccessibilitySize ? .leading : .trailing)
                        }
                    }
                    if !status.conflicts.isEmpty { Label("此时还有重叠课程，请检查安排", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let next = status.next, status.current != nil {
                        Divider().opacity(0.5)
                        let nextLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .top, spacing: 7))
                        nextLayout {
                            Text("下一门").foregroundStyle(.secondary)
                            Text(next.courseName).fontWeight(.medium)
                            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                            Text("\(Display.day(next.start, in: semester)) \(Display.time(next.start, zone: semester.timeZoneID))\n\(next.location)").multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing).foregroundStyle(.secondary)
                        }.font(.caption)
                    } else if let nextSegment = status.nextSegment, status.kind == .inClass {
                        Text("下一节 \(Display.time(nextSegment.start, zone: semester.timeZoneID)) · \(event.location)").font(.caption).foregroundStyle(.secondary)
                    } else if status.current == nil {
                        Text("\(Display.day(event.start, in: semester)) · \(Display.time(event.start, zone: semester.timeZoneID)) 开始").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(status.kind == .afterSemester ? "这一学期，辛苦了。" : "把时间留给自己。").font(.title3.weight(.semibold))
                    Text("添加课程后，这里会显示当前和下一节课。").font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding(19).frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.085), in: .rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(color.opacity(0.12), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 24))
                .onTapGesture { if let event { onCourse(event) } }
                .accessibilityElement(children: .combine)
        }
    }
    private func title(_ kind: CurrentStatus.Kind) -> String {
        switch kind { case .inClass: "正在上课"; case .onBreak: "课间休息"; case .upcoming: "下一节课"; case .finishedToday: "今日课程已结束"; case .beforeSemester: "学期尚未开始"; case .afterSemester: "学期已结束"; case .empty: "今天，从容一点" }
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
    private let scale: CGFloat = 1.1
    private var periods: [Period] { ScheduleEngine.bellSchedule(on: ScheduleEngine.date(week: week, weekday: 1, semester: semester), semester: semester, schedules: bells)?.periods ?? [] }
    private var minMinute: Int { min(periods.map(\.startMinute).min() ?? 480, occurrences.map { Display.minutes($0.start, in: semester) }.min() ?? 480) }
    private var maxMinute: Int { max(periods.map(\.endMinute).max() ?? 1080, occurrences.map { semester.calendar.isDate($0.start, inSameDayAs: $0.end) ? Display.minutes($0.end, in: semester) : 1440 }.max() ?? 1080) }
    private var days: [Int] { (1...7).filter { day in !hideEmptyWeekends || day < 6 || now.map { semester.calendar.isDate($0, inSameDayAs: ScheduleEngine.date(week: week, weekday: day, semester: semester)) } == true || pendingMakeupKeys.contains(HolidayCalendar.key(ScheduleEngine.date(week: week, weekday: day, semester: semester), calendar: semester.calendar)) || occurrences.contains { semester.calendar.isDate($0.start, inSameDayAs: ScheduleEngine.date(week: week, weekday: day, semester: semester)) } } }
    private var todayIndex: Int? {
        guard let now else { return nil }
        return days.firstIndex { semester.calendar.isDate(now, inSameDayAs: ScheduleEngine.date(week: week, weekday: $0, semester: semester)) }
    }
    private var inTimeRange: Bool { now.map { (minMinute...maxMinute).contains(Display.minutes($0, in: semester)) } ?? false }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 3) {
                Text("\(semester.calendar.component(.month, from: ScheduleEngine.date(week: week, weekday: 1, semester: semester)))\n月").font(.caption2).foregroundStyle(.secondary).frame(width: 31)
                ForEach(days, id: \.self) { day in
                    let date = ScheduleEngine.date(week: week, weekday: day, semester: semester)
                    let today = now.map { semester.calendar.isDate($0, inSameDayAs: date) } ?? false
                    let key = HolidayCalendar.key(date, calendar: semester.calendar)
                    let holiday = holidayDays.first { $0.dateKey == key }
                    VStack(spacing: 4) {
                        Text(Display.weekdays[day - 1]).font(.system(size: 11, weight: .medium))
                        Text("\(semester.calendar.component(.day, from: date))").font(.system(.subheadline, design: .rounded, weight: today ? .bold : .medium))
                        if pendingMakeupKeys.contains(key) { Text("课待定").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange) }
                        else if let holiday { Text(holiday.kind == .makeup ? "补班" : holiday.name).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                        .frame(maxWidth: .infinity).padding(.vertical, 7).foregroundStyle(today ? Palette.accent : Color.secondary).background(today ? Palette.accent.opacity(0.11) : .clear, in: .rect(cornerRadius: 12))
                }
            }
            if let now, todayIndex != nil, !inTimeRange, Display.minutes(now, in: semester) < minMinute {
                NowMarker(now: now, semester: semester, note: "尚未进入课表时段").padding(.horizontal, 8)
            }
            GeometryReader { geometry in
                let column = (geometry.size.width - 34) / CGFloat(days.count)
                ZStack(alignment: .topLeading) {
                    if let todayIndex {
                        RoundedRectangle(cornerRadius: 8).fill(Palette.accent.opacity(0.035))
                            .frame(width: column - 2, height: CGFloat(max(60, maxMinute - minMinute)) * scale)
                            .offset(x: 34 + CGFloat(todayIndex) * column).allowsHitTesting(false)
                    }
                    ForEach(periods.isEmpty ? stride(from: minMinute, through: maxMinute, by: 60).map { Period(number: ($0 - minMinute) / 60 + 1, startMinute: $0, endMinute: $0 + 45) } : periods) { period in
                        HStack(alignment: .top, spacing: 3) {
                            VStack(spacing: 2) { Text("\(period.number)").font(.caption.weight(.medium)); Text(Period.clock(period.startMinute)).font(.system(size: 8)); Text(Period.clock(period.endMinute)).font(.system(size: 8)) }.foregroundStyle(.tertiary).frame(width: 31)
                            Rectangle().fill(Color.primary.opacity(0.045)).frame(height: 0.5)
                        }.offset(y: CGFloat(period.startMinute - minMinute) * scale)
                    }
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        let date = ScheduleEngine.date(week: week, weekday: day, semester: semester)
                        let events = occurrences.filter { semester.calendar.isDate($0.start, inSameDayAs: date) }
                        ForEach(events) { event in
                            let overlaps = events.filter { $0.start < event.end && event.start < $0.end }.sorted { $0.id < $1.id }
                            let lane = overlaps.firstIndex(where: { $0.id == event.id }) ?? 0
                            let laneWidth = column / CGFloat(max(1, overlaps.count))
                            let height = max(40, CGFloat(event.end.timeIntervalSince(event.start) / 60) * scale - 4)
                            Button { onCourse(event) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.courseName).font(.system(size: 12, weight: .semibold)).lineLimit(height > 75 ? 4 : 2)
                                    if !event.location.isEmpty { Text(event.location).font(.system(size: 10)).lineLimit(2).opacity(0.8) }
                                    if height > 110 && !event.teacher.isEmpty { Text(event.teacher).font(.system(size: 9)).lineLimit(1).opacity(0.65) }
                                    if let state = ScheduleTime.status(event, now: now) { Text(state == "课间休息" ? "课间" : "上课中").font(.system(size: 9, weight: .bold)).lineLimit(1) }
                                    if pendingMakeupKeys.contains(HolidayCalendar.key(date, calendar: semester.calendar)) { Text("待核对").font(.system(size: 9)).foregroundStyle(.orange) }
                                    Spacer(minLength: 0)
                                    if event.isException { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)) }
                                }.padding(.horizontal, 5).padding(.vertical, 8).frame(width: max(12, laneWidth - 3), height: height, alignment: .topLeading)
                                    .foregroundStyle(Palette.color(event.colorIndex)).background(Palette.color(event.colorIndex).opacity(0.13), in: .rect(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ScheduleTime.status(event, now: now) != nil ? Palette.color(event.colorIndex) : .clear, lineWidth: 1.5))
                                    .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 2).fill(Palette.color(event.colorIndex).opacity(0.7)).frame(height: 3).padding(.horizontal, 6) }
                            }.buttonStyle(.plain)
                                .offset(x: 34 + CGFloat(index) * column + CGFloat(lane) * laneWidth, y: CGFloat(Display.minutes(event.start, in: semester) - minMinute) * scale)
                                .accessibilityLabel("\(event.courseName)，\(Display.weekdays[day - 1])，\(Display.time(event.start, zone: semester.timeZoneID))至\(Display.time(event.end, zone: semester.timeZoneID))，\(event.location)")
                        }
                    }
                    if let now, let todayIndex, inTimeRange {
                        GridNowLine(now: now, semester: semester, column: column, todayIndex: todayIndex, width: geometry.size.width)
                            .offset(y: CGFloat(Display.minutes(now, in: semester) - minMinute) * scale)
                    }
                }
            }.frame(height: CGFloat(max(60, maxMinute - minMinute)) * scale + 12)
            if let now, todayIndex != nil, !inTimeRange, Display.minutes(now, in: semester) > maxMinute {
                NowMarker(now: now, semester: semester, note: "已超出课表时段").padding(.horizontal, 8)
            }
        }.padding(.vertical, 10).padding(.horizontal, 5).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}
