import SwiftUI
import CourseKit

struct HolidayBanner: View {
    @Environment(AppStore.self) private var store
    let semester: Semester
    let now: Date
    let onSelect: (OfficialHolidayGroup) -> Void
    private var pending: [OfficialHolidayGroup] {
        store.holidays.groups(for: semester).filter { HolidayCalendar.shouldPrompt($0, now: now, semester: semester, snapshot: store.snapshot) }
    }
    var body: some View {
        ForEach(pending) { group in
            Button { onSelect(group) } label: {
                HStack(alignment: .top, spacing: 12) {
                    SettingsIcon(systemImage: "calendar.badge.exclamationmark", color: .orange)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(group.name)学校安排待确认").font(.subheadline.weight(.semibold))
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        Text("放假：\(HolidayPresentation.ranges(group.days.filter { $0.kind == .holiday }, semester: semester))").font(.subheadline).foregroundStyle(.secondary)
                        ForEach(group.days.filter { $0.kind == .makeup }) { day in
                            Text("\(HolidayPresentation.date(day, semester: semester))补班 · \(HolidayPresentation.status(day, semester: semester, snapshot: store.snapshot, now: now))")
                                .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("holiday-group-day-\(day.dateKey)")
                        }
                        Text("整段放假可一次确认；补班日可以稍后决定。原课程和提醒继续保留。").font(.caption).foregroundStyle(.tertiary)
                    }
                }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
                            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(LinearGradient(colors: [Color.orange.opacity(0.14), Color.orange.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    }
            }.buttonStyle(.plain).accessibilityIdentifier("holiday-group-prompt-\(group.id)")
        }
    }
}

struct HolidaySettingsView: View {
    @Environment(AppStore.self) private var store
    let semester: Semester
    @State private var selected: OfficialHolidayDay?
    @State private var selectedGroup: OfficialHolidayGroup?
    private var current: Semester { store.snapshot.semesters.first { $0.id == semester.id } ?? semester }
    var body: some View {
        List {
            Section {
                Toggle("官方节假日与调休提示", isOn: Binding(get: { current.holidayHintsEnabled != false }, set: { enabled in
                    store.apply("节假日提示设置") { data in if let index = data.semesters.firstIndex(where: { $0.id == semester.id }) { data.semesters[index].holidayHintsEnabled = enabled } }
                    if enabled { Task { await store.holidays.refresh(for: current) } }
                }))
                Text("自动检测全国性放假和补班日期，学校课程由你确认。关闭提示不会撤销已经确认的课程安排。").font(.caption).foregroundStyle(.secondary)
                Button { Task { await store.holidays.refresh(for: current, force: true) } } label: {
                    HStack { Text("刷新官方安排"); if store.holidays.isRefreshing { Spacer(); ProgressView() } }
                }.disabled(store.holidays.isRefreshing)
                Text(store.holidays.updateMessage).font(.caption).foregroundStyle(.secondary)
                ForEach(store.holidays.missingYears(for: semester), id: \.self) { year in Text("暂无 \(String(year)) 年度官方安排").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(store.holidays.groups(for: current)) { group in
                Section("\(String(group.year))年\(group.name)") {
                    Button("批量确认\(group.name)安排") { selectedGroup = group }
                    ForEach(group.days(in: current)) { day in
                        Button { selected = day } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(HolidayPresentation.date(day, semester: current)) · \(day.kind == .makeup ? "官方补班" : "官方放假")").foregroundStyle(.primary)
                                Text(decisionText(day)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("资料来源") {
                ForEach(store.holidays.relevantYears(semester), id: \.self) { year in
                    if let notice = store.holidays.years[year], let url = URL(string: notice.sourceURL) {
                        Link(notice.title, destination: url).font(.footnote)
                        Text("核对时间：\(Display.format(notice.checkedAt, style: .dateTime.year().month().day(), zone: semester.timeZoneID))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("官方假期与学校调休").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selected) { day in HolidayConfirmationView(semester: current, day: day) }
            .sheet(item: $selectedGroup) { group in HolidayGroupConfirmationView(semester: current, group: group) }
    }
    private func decisionText(_ day: OfficialHolidayDay) -> String {
        guard let date = day.date(in: semester) else { return "日期无效" }
        if let change = store.snapshot.dayOverrides.first(where: { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: date) }) { return "已确认：按 \(Display.day(change.followsDate, in: semester)) 上课" }
        if let decision = store.snapshot.holidayDecisions.first(where: { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: date) }) { return decision.kind == .noClasses ? "已确认：当天常规课程停课" : "已确认：照常按原课表" }
        return day.kind == .makeup ? "调休课程待定 · 原课表待核对" : "学校放假安排待核对"
    }
}

struct HolidayConfirmationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let semester: Semester
    let day: OfficialHolidayDay
    @State private var choice: HolidayEditing.Choice
    @State private var sourceWeek: Int
    @State private var sourceWeekday = 1
    @State private var useDate = false
    @State private var sourceDate: Date
    @State private var error: String?
    init(semester: Semester, day: OfficialHolidayDay) {
        self.semester = semester; self.day = day
        let date = day.date(in: semester) ?? semester.firstMonday
        let week = max(1, min(semester.weekCount, ScheduleEngine.weekNumber(on: date, semester: semester)))
        _sourceWeek = State(initialValue: week)
        _sourceDate = State(initialValue: ScheduleEngine.date(week: week, weekday: 1, semester: semester))
        _choice = State(initialValue: day.kind == .holiday ? .noClasses : .followDate)
    }
    private var target: Date { day.date(in: semester) ?? semester.firstMonday }
    private var reference: Date { useDate ? sourceDate : ScheduleEngine.date(week: sourceWeek, weekday: sourceWeekday, semester: semester) }
    private var preview: Result<[Occurrence], Error> {
        do {
            let data = try HolidayEditing.applying(choice, date: target, sourceDate: reference, sourceURL: store.holidays.source(for: day), semesterID: semester.id, to: store.snapshot)
            return .success(ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id).filter { semester.calendar.isDate($0.start, inSameDayAs: target) })
        } catch { return .failure(error) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(Display.day(target, in: semester)) · \(day.name) · \(day.kind == .makeup ? "官方补班日" : "官方放假日")").font(.headline)
                    Text("请选择学校安排。确认前保留原课程和提醒。").font(.subheadline).foregroundStyle(.secondary)
                    if let url = URL(string: store.holidays.source(for: day)) { Link("查看官方公告", destination: url) }
                }
                Section("当天课程") {
                    Picker("学校安排", selection: $choice) {
                        Text("按周几上课").tag(HolidayEditing.Choice.followDate)
                        Text("照常按原课表").tag(HolidayEditing.Choice.keepSchedule)
                        Text("当天不上课").tag(HolidayEditing.Choice.noClasses)
                    }.accessibilityIdentifier("holiday-choice")
                    if choice == .followDate {
                        Toggle("使用具体参照日期", isOn: $useDate)
                        if useDate { DatePicker("参照日期", selection: $sourceDate, displayedComponents: .date) }
                        else {
                            Picker("教学周", selection: $sourceWeek) { ForEach(1...semester.weekCount, id: \.self) { Text("第 \($0) 周").tag($0) } }
                            Picker("星期", selection: $sourceWeekday) { ForEach(1...7, id: \.self) { Text(Display.weekdays[$0 - 1]).tag($0) } }
                        }
                        Text("按第 \(ScheduleEngine.weekNumber(on: reference, semester: semester)) 周 · \(Display.day(reference, in: semester)) 的课程上课，单双周与限定周次按参照日期计算。参照日自身保持原安排。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("确认后的课程预览") {
                    switch preview {
                    case .success(let events):
                        if events.isEmpty { Text(choice == .noClasses ? "当天常规课程将停课" : "参照安排当天没有课程").foregroundStyle(.secondary) }
                        ForEach(events) { CourseRow(occurrence: $0, timeZoneID: semester.timeZoneID) }
                        if choice == .noClasses && !events.isEmpty { Text("以上为明确添加或移入当天的单次课程，仍会保留。可在课程详情中另行停课。").font(.caption).foregroundStyle(.secondary) }
                    case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("确认学校安排") { save() }.disabled(previewFailed).accessibilityIdentifier("holiday-confirm")
                    Button("稍后再说") { dismiss() }
                    Button("恢复待确认", role: .destructive) {
                        if store.apply("恢复调休待确认", { $0 = HolidayEditing.resetting(date: target, semester: semester, in: $0) }) { dismiss() }
                    }
                } footer: { Text("已有手动整日换课会优先使用；确认新安排会替换当天的整日安排，课程和提醒随之更新。恢复待确认不会删除手动整日换课。") }
            }.environment(\.timeZone, semester.calendar.timeZone)
                .navigationTitle("确认学校调休").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后再说") { dismiss() } } }
                .onAppear { loadDecision() }
        }
    }
    private var previewFailed: Bool { if case .failure = preview { return true }; return false }
    private func loadDecision() {
        if let change = store.snapshot.dayOverrides.first(where: { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: target) }) {
            choice = .followDate; useDate = true; sourceDate = change.followsDate
        } else if let decision = store.snapshot.holidayDecisions.first(where: { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: target) }) { choice = decision.kind == .noClasses ? .noClasses : .keepSchedule }
    }
    private func save() {
        // AppStore reloads the latest persisted snapshot before editing; preview never writes data.
        var editError: Error?
        let saved = store.apply("确认学校调休") { data in
            do { data = try HolidayEditing.applying(choice, date: target, sourceDate: reference, sourceURL: store.holidays.source(for: day), semesterID: semester.id, to: data) }
            catch { editError = error }
        }
        if let editError { error = editError.localizedDescription }
        else if saved { dismiss() }
        else { error = store.errorMessage }
    }
}
