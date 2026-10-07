import SwiftUI
import CourseKit

/// Display full official groups without changing their membership when dates are confirmed.
enum HolidayPresentation {
    static func date(_ day: OfficialHolidayDay, semester: Semester) -> String {
        guard let date = day.date(in: semester) else { return day.dateKey }
        let parts = semester.calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }
    static func ranges(_ days: [OfficialHolidayDay], semester: Semester) -> String {
        let sorted = days.sorted { $0.dateKey < $1.dateKey }
        guard let first = sorted.first else { return "无" }
        var start = first; var previous = first; var segments: [String] = []
        func segment(_ start: OfficialHolidayDay, _ end: OfficialHolidayDay) -> String {
            start.dateKey == end.dateKey ? date(start, semester: semester) : "\(date(start, semester: semester))–\(date(end, semester: semester))"
        }
        for day in sorted.dropFirst() {
            let contiguous = previous.date(in: semester).flatMap { before in day.date(in: semester).map { semester.calendar.dateComponents([.day], from: before, to: $0).day == 1 } } ?? false
            if !contiguous { segments.append(segment(start, previous)); start = day }
            previous = day
        }
        segments.append(segment(start, previous))
        return segments.joined(separator: "、")
    }
    static func isPast(_ day: OfficialHolidayDay, semester: Semester, now: Date) -> Bool {
        day.date(in: semester).map { $0 < semester.calendar.startOfDay(for: now) } ?? false
    }
    static func status(_ day: OfficialHolidayDay, semester: Semester, snapshot: ScheduleSnapshot, now: Date) -> String {
        guard let date = day.date(in: semester), (1...semester.weekCount).contains(ScheduleEngine.weekNumber(on: date, semester: semester)) else { return "不在本学期" }
        if let change = snapshot.dayOverrides.first(where: { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: date) }) {
            return "\(change.officialSourceURL == nil ? "已手动换课" : "已确认")：按\(Display.day(change.followsDate, in: semester))上课"
        }
        if let decision = snapshot.holidayDecisions.first(where: { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: date) }) {
            return decision.kind == .noClasses ? "已确认不上课" : "已确认照常上课"
        }
        if isPast(day, semester: semester, now: now) { return "已过，未确认" }
        return day.kind == .makeup ? "调休课程待定" : "学校放假待核对"
    }
}

private struct HolidayArrangementDraft {
    var choice: HolidayEditing.Choice?
    var week: Int
    var weekday = 1
    var useDate = false
    var sourceDate: Date
    init(day: OfficialHolidayDay, semester: Semester) {
        let date = day.date(in: semester) ?? semester.firstMonday
        week = max(1, min(semester.weekCount, ScheduleEngine.weekNumber(on: date, semester: semester)))
        sourceDate = ScheduleEngine.date(week: week, weekday: 1, semester: semester)
    }
    func reference(in semester: Semester) -> Date {
        useDate ? sourceDate : ScheduleEngine.date(week: week, weekday: weekday, semester: semester)
    }
}

struct HolidayGroupConfirmationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let semester: Semester
    let group: OfficialHolidayGroup
    @State private var selectedHolidayKeys: Set<String> = []
    @State private var holidayChoice: HolidayEditing.Choice = .noClasses
    @State private var makeupDrafts: [String: HolidayArrangementDraft] = [:]
    @State private var selectedDay: OfficialHolidayDay?
    @State private var loaded = false
    @State private var error: String?
    private var now: Date { PreviewClock.now(.now) }
    private var days: [OfficialHolidayDay] { group.days(in: semester) }
    private var selectedDays: [OfficialHolidayDay] {
        days.filter { $0.kind == .holiday ? selectedHolidayKeys.contains($0.dateKey) : makeupDrafts[$0.dateKey]?.choice != nil }
    }
    private var edits: [HolidayEditing.Edit] {
        selectedDays.compactMap { day in
            guard let target = day.date(in: semester) else { return nil }
            if day.kind == .holiday { return .init(date: target, choice: holidayChoice, sourceURL: store.holidays.source(for: day)) }
            guard let draft = makeupDrafts[day.dateKey], let choice = draft.choice else { return nil }
            return .init(date: target, choice: choice, sourceDate: choice == .followDate ? draft.reference(in: semester) : nil, sourceURL: store.holidays.source(for: day))
        }
    }
    private var preview: Result<[Occurrence], Error> {
        do {
            let result = try HolidayEditing.applyingBatch(edits, semesterID: semester.id, to: store.snapshot)
            let keys = Set(selectedDays.map(\.dateKey))
            return .success(ScheduleEngine.occurrences(snapshot: result, semesterID: semester.id).filter { keys.contains(HolidayCalendar.key($0.start, calendar: semester.calendar)) })
        } catch { return .failure(error) }
    }
    private var previewFailed: Bool { if case .failure = preview { return true }; return false }
    private func hasArrangement(_ day: OfficialHolidayDay) -> Bool {
        guard let date = day.date(in: semester) else { return false }
        return HolidayCalendar.hasArrangement(date, semester: semester, snapshot: store.snapshot)
    }
    var body: some View {
        NavigationStack {
            Form {
                overview
                holidaySection
                makeupSection
                coursePreview
                if let error { Section { Text(error).foregroundStyle(.red); Button("重新核对所选日期") { loadSelections() } } }
                Section {
                    Button("稍后再说") { dismiss() }
                } footer: {
                    Text("只有点击确认才会保存。待确定、未勾选及已确认的日期保持原安排。单次新增或移入的课程继续保留；学校安排以正式通知为准。")
                }
            }
            .environment(\.timeZone, semester.calendar.timeZone)
            .navigationTitle("\(group.name)学校安排").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后再说") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { confirmationBar }
            .onAppear { if !loaded { loadSelections(); loaded = true } }
            .sheet(item: $selectedDay, onDismiss: removeExplicitlyConfirmedSelections) { day in
                HolidayConfirmationView(semester: semester, day: day)
            }
        }
    }
    private var overview: some View {
        Section {
            Text("\(String(group.year))年\(group.name)").font(.headline)
            Text("放假：\(HolidayPresentation.ranges(group.days.filter { $0.kind == .holiday }, semester: semester))")
            Text("补班：\(HolidayPresentation.ranges(group.days.filter { $0.kind == .makeup }, semester: semester))")
            Text("放假可以整段确认，补班日分别设置。可以先确认放假，补班稍后再定。").font(.subheadline).foregroundStyle(.secondary)
            if let day = group.days.first, let url = URL(string: store.holidays.source(for: day)) { Link("查看官方公告", destination: url) }
            if group.days.count > days.count { Text("不在本学期的日期仅供参考，不参与确认。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var holidaySection: some View {
        Section("放假安排") {
            Picker("整段学校安排", selection: $holidayChoice) {
                Text("整段不上课").tag(HolidayEditing.Choice.noClasses)
                Text("照常按原课表").tag(HolidayEditing.Choice.keepSchedule)
            }.accessibilityIdentifier("holiday-batch-rest-choice")
            ForEach(days.filter { $0.kind == .holiday }) { day in
                if hasArrangement(day) { confirmedRow(day) }
                else {
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { selectedHolidayKeys.contains(day.dateKey) }, set: { selected in
                            if selected { selectedHolidayKeys.insert(day.dateKey) } else { selectedHolidayKeys.remove(day.dateKey) }
                        })) {
                            Text("\(HolidayPresentation.date(day, semester: semester))\(HolidayPresentation.isPast(day, semester: semester, now: now) ? "（已过）" : "")")
                        }.accessibilityIdentifier("holiday-select-\(day.dateKey)")
                        Button { selectedDay = day } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(HolidayPresentation.date(day, semester: semester))，单独查看或修改")
                    }
                }
            }
        }
    }
    private var makeupSection: some View {
        Section("补班安排") {
            if !days.contains(where: { $0.kind == .makeup }) { Text("本学期没有关联补班日").foregroundStyle(.secondary) }
            ForEach(days.filter { $0.kind == .makeup }) { day in
                Text("\(HolidayPresentation.date(day, semester: semester))补班\(HolidayPresentation.isPast(day, semester: semester, now: now) ? "（已过）" : "")").font(.headline)
                    .accessibilityIdentifier("holiday-group-day-\(day.dateKey)")
                if hasArrangement(day) { confirmedRow(day) }
                else {
                    HolidayMakeupEditor(day: day, semester: semester, draft: draftBinding(day))
                    Button("单独查看或修改") { selectedDay = day }.font(.caption).buttonStyle(.borderless)
                        .accessibilityLabel("\(HolidayPresentation.date(day, semester: semester))，单独查看或修改")
                }
            }
        }
    }
    private func confirmedRow(_ day: OfficialHolidayDay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HolidayPresentation.status(day, semester: semester, snapshot: store.snapshot, now: now)).font(.subheadline).foregroundStyle(.secondary)
            Button("\(HolidayPresentation.date(day, semester: semester)) · 修改或恢复待确认") { selectedDay = day }.font(.caption).buttonStyle(.borderless)
        }
    }
    private var coursePreview: some View {
        Section("确认后的课程预览") {
            if selectedDays.isEmpty { Text("尚未选择要确认的日期，补班可保留待确定。").foregroundStyle(.secondary) }
            else {
                switch preview {
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(.red)
                    Button("重新核对所选日期") { loadSelections() }
                case .success(let occurrences):
                    DisclosureGroup("查看所选\(selectedDays.count)天课程") {
                        ForEach(selectedDays) { day in
                            Text(HolidayPresentation.date(day, semester: semester)).font(.subheadline.weight(.semibold))
                            let events = occurrences.filter { HolidayCalendar.key($0.start, calendar: semester.calendar) == day.dateKey }
                            if events.isEmpty { Text("没有课程").font(.caption).foregroundStyle(.secondary) }
                            ForEach(events) { CourseRow(occurrence: $0, timeZoneID: semester.timeZoneID) }
                        }
                    }
                    Text("明确新增或移入停课日期的单次课程仍保留，以上预览会显示这些课程。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var confirmationBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !selectedDays.isEmpty {
                Text("本次：\(HolidayPresentation.ranges(selectedDays, semester: semester)) · \(selectedDays.count)天").font(.caption).fixedSize(horizontal: false, vertical: true)
                if selectedDays.contains(where: { HolidayPresentation.isPast($0, semester: semester, now: now) }) {
                    Text("包含已过日期，只在确认后写入安排。").font(.caption).foregroundStyle(.orange)
                }
            }
            Button("确认\(selectedDays.count)天安排") { save() }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                .disabled(selectedDays.isEmpty || previewFailed).accessibilityIdentifier("holiday-batch-confirm")
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
    private func draftBinding(_ day: OfficialHolidayDay) -> Binding<HolidayArrangementDraft> {
        Binding(get: { makeupDrafts[day.dateKey] ?? .init(day: day, semester: semester) }, set: { makeupDrafts[day.dateKey] = $0 })
    }
    private func loadSelections() {
        selectedHolidayKeys = Set(days.filter { $0.kind == .holiday && !hasArrangement($0) }.map(\.dateKey))
        makeupDrafts = Dictionary(uniqueKeysWithValues: days.filter { $0.kind == .makeup }.map { ($0.dateKey, HolidayArrangementDraft(day: $0, semester: semester)) })
        error = nil
    }
    private func removeExplicitlyConfirmedSelections() {
        for day in days where hasArrangement(day) { selectedHolidayKeys.remove(day.dateKey); makeupDrafts[day.dateKey]?.choice = nil }
    }
    private func save() {
        let batch = edits
        guard !batch.isEmpty else { return }
        var editError: Error?
        let saved = store.apply("批量确认\(group.name)安排") { latest in
            do { latest = try HolidayEditing.applyingBatch(batch, semesterID: semester.id, to: latest) }
            catch { editError = error }
        }
        if let editError { error = editError.localizedDescription }
        else if saved { dismiss() }
        else { error = store.errorMessage }
    }
}

private struct HolidayMakeupEditor: View {
    let day: OfficialHolidayDay
    let semester: Semester
    @Binding var draft: HolidayArrangementDraft
    var body: some View {
        Picker("学校安排", selection: $draft.choice) {
            Text("待确定").tag(Optional<HolidayEditing.Choice>.none)
            Text("按周几上课").tag(Optional.some(HolidayEditing.Choice.followDate))
            Text("照常按原课表").tag(Optional.some(HolidayEditing.Choice.keepSchedule))
            Text("当天不上课").tag(Optional.some(HolidayEditing.Choice.noClasses))
        }.accessibilityIdentifier("holiday-makeup-choice-\(day.dateKey)")
            .accessibilityLabel("\(HolidayPresentation.date(day, semester: semester))补班学校安排")
        if draft.choice == .followDate {
            Toggle("使用具体参照日期", isOn: $draft.useDate)
            if draft.useDate { DatePicker("参照日期", selection: $draft.sourceDate, displayedComponents: .date) }
            else {
                Picker("教学周", selection: $draft.week) { ForEach(1...semester.weekCount, id: \.self) { Text("第 \($0) 周").tag($0) } }
                Picker("星期", selection: $draft.weekday) { ForEach(1...7, id: \.self) { Text(Display.weekdays[$0 - 1]).tag($0) } }
            }
            let reference = draft.reference(in: semester)
            Text("参照第\(ScheduleEngine.weekNumber(on: reference, semester: semester))周 · \(Display.day(reference, in: semester))的课程；单双周按参照日计算，参照日保持原安排。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
