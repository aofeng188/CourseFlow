import SwiftUI
import UniformTypeIdentifiers
import CourseKit

private enum SettingsSheet: Identifiable {
    case semester(Semester?), bells(BellSchedule?), reschedule, cloud, calendar
    var id: String { switch self { case .semester(let value): "semester-\(value?.id.uuidString ?? "new")"; case .bells(let value): "bells-\(value?.id.uuidString ?? "new")"; case .reschedule: "reschedule"; case .cloud: "cloud"; case .calendar: "calendar" } }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var sheet: SettingsSheet?
    @State private var shareFile: SharedFile?
    @State private var showRestore = false
    @State private var backup: ScheduleSnapshot?
    @State private var restoreConfirmation = false
    @State private var deletingSemester = false
    @State private var deletingSemesterHasCalendar = false
    @State private var confirmCalendarTakeover = false
    private var version: String { "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"))" }
    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                HStack(spacing: 15) {
                    BrandMark(size: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("课序").font(.title2.bold())
                        Text("把每一周，安排得刚刚好。").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            }
            if BuildFeatures.isTrial {
                Section {
                    SettingsLabel(title: "个人试用版", systemImage: "iphone", color: .gray)
                } footer: { Text("课程、导入、提醒和日历可正常试用。此版本不包含 iCloud、小组件与实况活动，课表保存在本机，可通过文件备份迁移。") }
            }
            Section {
                if !store.snapshot.semesters.isEmpty {
                    Picker(selection: Binding(get: { store.semester?.id }, set: { store.selectedSemesterID = $0 })) {
                        ForEach(store.snapshot.semesters.sorted { $0.firstMonday > $1.firstMonday }) { semester in Text(semester.name).tag(Optional(semester.id)) }
                    } label: { SettingsLabel(title: "当前学期", systemImage: "graduationcap.fill", color: Palette.solid(0)) }
                }
                if let semester = store.semester {
                    Button { sheet = .semester(semester) } label: { SettingsLabel(title: "学期设置", systemImage: "calendar", color: Palette.solid(1), value: "\(semester.weekCount) 周", showsChevron: true) }
                    ForEach(store.bells) { value in
                        Button { sheet = .bells(value) } label: { SettingsLabel(title: value.name, systemImage: "clock.fill", color: Palette.solid(2), value: "\(value.periods.count) 节", showsChevron: true) }
                    }
                    NavigationLink { HolidaySettingsView(semester: semester) } label: { SettingsLabel(title: "节假日与调休", systemImage: "flag.fill", color: Palette.solid(4)) }
                    let overrides = store.snapshot.dayOverrides.filter { $0.semesterID == semester.id }.count
                    Button { sheet = .reschedule } label: { SettingsLabel(title: "整日换课", systemImage: "arrow.left.arrow.right", color: Palette.solid(3), value: overrides > 0 ? "\(overrides) 天" : nil, showsChevron: true) }
                    actionRow("添加作息方案") { sheet = .bells(nil) }
                }
                actionRow("添加新学期") { sheet = .semester(nil) }
            } header: { Text("学期与作息") } footer: { if store.semester != nil { Text("「节假日与调休」跟随官方放假安排；「整日换课」用于学校临时让某天按另一天的课表上课。") } }
            Section {
                Toggle(isOn: Binding(get: { store.preferences.notificationsEnabled }, set: { enabled in
                    if enabled { Task { if await NotificationService.shared.requestAuthorization() { store.preferences.notificationsEnabled = true } else { store.errorMessage = "通知权限未开启，请到系统设置中允许课序发送通知。" } } }
                    else { store.preferences.notificationsEnabled = false }
                })) { SettingsLabel(title: "上课提醒", systemImage: "bell.fill", color: Palette.now) }
                Picker(selection: $store.preferences.reminderMinutes) {
                    ForEach([0, 5, 10, 15, 20, 30, 60], id: \.self) { value in Text(value == 0 ? "上课时" : "\(value) 分钟").tag(value) }
                } label: { SettingsLabel(title: "默认提前", systemImage: "timer", color: Palette.solid(2)) }
                if store.semester != nil { Button { sheet = .calendar } label: { SettingsLabel(title: "系统日历", systemImage: "calendar.badge.plus", color: Palette.solid(1), showsChevron: true) } }
                if let semester = store.semester, let owner = semester.calendarOwnerDeviceID {
                    if owner == CalendarSyncService.shared.deviceIdentifier {
                        actionRow("暂停本设备日历自动同步", systemImage: "pause.circle") { store.apply("暂停日历同步") { data in if let index = data.semesters.firstIndex(where: { $0.id == semester.id }) { data.semesters[index].calendarOwnerDeviceID = nil } } }
                    } else { actionRow("在本设备接管日历同步", systemImage: "arrow.triangle.2.circlepath") { confirmCalendarTakeover = true } }
                }
                Toggle(isOn: $store.preferences.duplicateReminders) { SettingsLabel(title: "同时使用 App 和日历提醒", systemImage: "bell.badge.fill", color: .gray) }
            } header: { Text("提醒与日历") } footer: { Text("\(store.notificationSummary)。连堂课只提醒一次；需要整学期提醒时，可交给系统日历。") }
            if !BuildFeatures.isTrial {
                Section {
                    Toggle(isOn: $store.preferences.activitiesEnabled) { SettingsLabel(title: "课程实况活动", systemImage: "dot.radiowaves.left.and.right", color: Palette.solid(6)) }
                } header: { Text("锁屏与灵动岛") } footer: { Text("在锁屏和灵动岛查看当前课程，或预约下一场课，预约启动时系统会提示。长按主屏幕或锁屏，可添加「课序」小组件。") }
            }
            Section("显示") {
                Toggle(isOn: $store.preferences.hideEmptyWeekends) { SettingsLabel(title: "隐藏没有课的周末", systemImage: "calendar.day.timeline.left", color: Palette.solid(5)) }
            }
            Section {
                Button { sheet = .cloud } label: { SettingsLabel(title: "识别增强", systemImage: "sparkles", color: Palette.solid(3), showsChevron: true) }
                if !BuildFeatures.isTrial {
                    SettingsLabel(title: "iCloud 同步", systemImage: "icloud.fill", color: Palette.solid(1), value: store.persistence.cloudEnabled ? "已开启" : "未配置")
                }
                Button { exportBackup() } label: { SettingsLabel(title: "导出完整备份", systemImage: "square.and.arrow.up", color: Palette.solid(5)) }
                Button { showRestore = true } label: { SettingsLabel(title: "从备份恢复", systemImage: "arrow.counterclockwise", color: Palette.solid(2)) }
                if let semester = store.semester { Button { exportICS(semester) } label: { SettingsLabel(title: "导出学期日历 (.ics)", systemImage: "calendar", color: Palette.now) } }
                if let label = store.undoLabel { actionRow("撤销“\(label)”", systemImage: "arrow.uturn.backward") { store.undo() } }
            } header: { Text("识别与数据") } footer: {
                Text((BuildFeatures.isTrial ? "" : (store.persistence.cloudEnabled ? "学期、课程和作息同步到同一 Apple 账户。" : "配置开发者账户与 CloudKit 容器后，可启用 iCloud 同步。")) + "备份不含 API Key、设备提醒记录或识别原图；恢复前会自动保存当前资料。")
            }
            if let semester = store.semester {
                Section {
                    Button(role: .destructive) {
                        Task {
                            deletingSemesterHasCalendar = await CalendarSyncService.shared.hasExport(for: semester)
                            deletingSemester = true
                        }
                    } label: { Text("删除“\(semester.name)”").frame(maxWidth: .infinity) }
                }
            }
            Section {
                NavigationLink { PrivacyView() } label: { SettingsLabel(title: "隐私与数据说明", systemImage: "hand.raised.fill", color: Palette.solid(1)) }
                SettingsLabel(title: "版本", systemImage: "info", color: .gray, value: version)
            } footer: { Text("课序 · 无广告，无追踪，课表属于你。").frame(maxWidth: .infinity).padding(.top, 8) }
        }.navigationTitle("设置")
        .sheet(item: $sheet) { value in
            switch value {
            case .semester(let value): SemesterEditor(semester: value)
            case .bells(let value): if let semester = store.semester { BellScheduleEditor(semester: semester, schedule: value) }
            case .reschedule: if let semester = store.semester { DayOverrideEditor(semester: semester) }
            case .cloud: CloudSettingsView()
            case .calendar:
                if let semester = store.semester {
                    CalendarSettingsView(semester: semester, occurrences: store.occurrences, defaultLeadMinutes: store.preferences.reminderMinutes) { _, enabled in
                        store.apply("日历同步设置") { data in
                            if let index = data.semesters.firstIndex(where: { $0.id == semester.id }) { data.semesters[index].calendarOwnerDeviceID = enabled ? CalendarSyncService.shared.deviceIdentifier : nil }
                        }
                        store.refresh()
                    }
                }
            }
        }
        .sheet(item: $shareFile) { ShareSheet(items: [$0.url]) }
        .fileImporter(isPresented: $showRestore, allowedContentTypes: [UTType(filenameExtension: "courseflow") ?? .json, .json]) { result in
            do { let url = try result.get(); let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }; backup = try BackupCodec.decode(Data(contentsOf: url)); restoreConfirmation = true } catch { store.errorMessage = "无法读取备份：\(error.localizedDescription)" }
        }
        .alert("恢复备份？", isPresented: $restoreConfirmation) {
            Button("取消", role: .cancel) { backup = nil }
            Button("备份当前资料并恢复") { do { if let backup { try store.restore(backup); store.notice = "已恢复课表资料" } } catch { store.errorMessage = error.localizedDescription }; backup = nil }
        } message: { Text("将恢复 \(backup?.semesters.count ?? 0) 个学期、\(backup?.courses.count ?? 0) 门课程、\(backup?.rules.count ?? 0) 条上课安排。当前资料会先保存为恢复前备份。") }
        .confirmationDialog("删除当前学期及其课程？", isPresented: $deletingSemester, titleVisibility: .visible) {
            if deletingSemesterHasCalendar {
                Button("先管理已导出的日历") { sheet = .calendar }
                Button("保留日历并删除学期", role: .destructive) { deleteSemester() }
            } else {
                Button("删除学期", role: .destructive) { deleteSemester() }
            }
        } message: { Text("如需移除日历事件，请先在日历同步页面撤销，再删除学期。选择保留后，原日历提醒会继续，后续需在系统日历中管理。") }
        .confirmationDialog("在本设备接管日历同步？", isPresented: $confirmCalendarTakeover, titleVisibility: .visible) {
            Button("接管并核对日历") {
                if let semester = store.semester {
                    if store.apply("接管日历同步", { data in if let index = data.semesters.firstIndex(where: { $0.id == semester.id }) { data.semesters[index].calendarOwnerDeviceID = CalendarSyncService.shared.deviceIdentifier } }) { sheet = .calendar }
                }
            }
        } message: { Text("请先在原设备暂停日历自动同步。本设备将按课程标识查找已有事件，展示差异后再同步。其他设备需联网获取新的负责设备信息。") }
    }
    /// An add or one-off action: tinted text aligned with the titles of the icon rows above it.
    private func actionRow(_ title: String, systemImage: String = "plus", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.body.weight(.semibold)).frame(width: 29).accessibilityHidden(true)
                Text(title)
            }
        }
    }
    private func exportBackup() { do { let url = FileManager.default.temporaryDirectory.appendingPathComponent("课序备份-\(Int(Date.now.timeIntervalSince1970)).courseflow"); try BackupCodec.encode(store.snapshot).write(to: url, options: .atomic); shareFile = SharedFile(url: url) } catch { store.errorMessage = error.localizedDescription } }
    private func exportICS(_ semester: Semester) { do { let url = FileManager.default.temporaryDirectory.appendingPathComponent("课序-学期日历.ics"); try ICSExporter.export(occurrences: store.occurrences, semester: semester, defaultLeadMinutes: store.preferences.reminderMinutes).write(to: url, atomically: true, encoding: .utf8); shareFile = SharedFile(url: url) } catch { store.errorMessage = error.localizedDescription } }
    private func deleteSemester() {
        guard let semester = store.semester else { return }
        store.apply("删除学期") { data in
            let courses = Set(data.courses.filter { $0.semesterID == semester.id }.map(\.id))
            let rules = Set(data.rules.filter { courses.contains($0.courseID) }.map(\.id))
            data.semesters.removeAll { $0.id == semester.id }
            data.bellSchedules.removeAll { $0.semesterID == semester.id }
            data.courses.removeAll { courses.contains($0.id) }
            data.rules.removeAll { rules.contains($0.id) }
            data.exceptions.removeAll { rules.contains($0.ruleID) }
            data.dayOverrides.removeAll { $0.semesterID == semester.id }
            data.holidayDecisions.removeAll { $0.semesterID == semester.id }
        }
        store.selectedSemesterID = store.snapshot.semesters.first?.id
    }
}

struct SemesterEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var value: Semester
    @State private var currentWeek = 1
    private let editing: Bool
    init(semester: Semester? = nil) {
        editing = semester != nil
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!; calendar.firstWeekday = 2
        let now = calendar.startOfDay(for: .now)
        let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: now) + 5) % 7), to: now)!
        _value = State(initialValue: semester ?? Semester(name: "\(calendar.component(.year, from: now)) 年秋季学期", firstMonday: monday))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("学期") {
                    TextField("学期名称", text: $value.name).accessibilityIdentifier("semester-name")
                    DatePicker("第 1 周的周一", selection: $value.firstMonday, displayedComponents: .date).environment(\.timeZone, value.calendar.timeZone)
                    Stepper("共 \(value.weekCount) 周", value: $value.weekCount, in: 1...52)
                    NavigationLink {
                        TimeZonePicker(selection: $value.timeZoneID)
                    } label: {
                        LabeledContent("学校时区", value: TimeZonePicker.title(for: value.timeZoneID))
                    }.accessibilityIdentifier("semester-time-zone")
                }
                Section {
                    Stepper("今天是第 \(currentWeek) 周", value: $currentWeek, in: 1...max(1, value.weekCount))
                    Button("根据今天校准开学日期") {
                        let calendar = value.calendar, now = calendar.startOfDay(for: .now)
                        let days = ((calendar.component(.weekday, from: now) + 5) % 7) + (currentWeek - 1) * 7
                        value.firstMonday = calendar.date(byAdding: .day, value: -days, to: now) ?? now
                    }
                } header: { Text("快捷校准") } footer: { Text("单双周按学校教学周计算。请选择第 1 周所在星期的周一；时间和提醒始终按学校时区计算。") }
                if editing { Section { Text("修改已有学期会影响课程日期。若缩短学期，请先在课程中调整超出范围的周次。").font(.caption).foregroundStyle(.secondary) } }
            }.navigationTitle(editing ? "学期设置" : "新建学期").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold).disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || TimeZone(identifier: value.timeZoneID) == nil).accessibilityIdentifier("save-semester") }
                }
                .onChange(of: value.firstMonday) { _, date in
                    let calendar = value.calendar
                    let day = calendar.startOfDay(for: date)
                    let monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: day) + 5) % 7), to: day) ?? day
                    if monday != date { value.firstMonday = monday }
                }
        }
    }
    private func save() {
        let success = store.apply("修改学期") { data in data.semesters.removeAll { $0.id == value.id }; data.semesters.append(value) }
        if success { store.selectedSemesterID = value.id; dismiss() }
    }
}

struct BellScheduleEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let semester: Semester
    @State private var value: BellSchedule
    @State private var firstMinute = 480
    @State private var duration = 45
    @State private var gap = 10
    @State private var count = 8
    @State private var confirmGenerate = false
    init(semester: Semester, schedule: BellSchedule? = nil) { self.semester = semester; _value = State(initialValue: schedule ?? BellSchedule(semesterID: semester.id, effectiveFrom: semester.firstMonday)) }
    private var issues: [String] { var copy = value; copy.isConfirmed = true; return DraftValidator.issues(for: copy) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("作息名称，如秋季作息", text: $value.name)
                    DatePicker("生效日期", selection: $value.effectiveFrom, displayedComponents: .date).environment(\.timeZone, semester.calendar.timeZone)
                } footer: { Text("新方案从生效日开始使用，之前的课次保持原作息。同一生效日的方案保存时会替换。") }
                Section("快速生成后逐节调整") {
                    MinutePicker(title: "第一节开始", minute: $firstMinute)
                    Stepper("每节 \(duration) 分钟", value: $duration, in: 10...180, step: 5)
                    Stepper("课间 \(gap) 分钟", value: $gap, in: 0...90, step: 5)
                    Stepper("每天 \(count) 节", value: $count, in: 1...20)
                    Button("生成节次时间") { if value.periods.isEmpty { generate() } else { confirmGenerate = true } }
                }
                ForEach($value.periods) { $period in
                    Section("第 \(period.number) 节") {
                        MinutePicker(title: "开始", minute: $period.startMinute)
                        MinutePicker(title: "结束", minute: $period.endMinute)
                    }
                }
                Section {
                    Button("添加一节", systemImage: "plus") { let n = (value.periods.map(\.number).max() ?? 0) + 1; let start = min(1370, (value.periods.last?.endMinute ?? 470) + 10); value.periods.append(Period(number: n, startMinute: start, endMinute: min(1439, start + 45))) }
                    if !value.periods.isEmpty { Button("移除最后一节", role: .destructive) { value.periods.removeLast() } }
                    ForEach(issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                } footer: { Text("请对照学校官方作息确认。午休、晚课等间隔可直接修改相应节次的起止时间。") }
            }.navigationTitle("学校作息").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("确认保存") { save() }.disabled(!issues.isEmpty) }
                }
                .confirmationDialog("重新生成会替换当前节次时间", isPresented: $confirmGenerate, titleVisibility: .visible) { Button("重新生成", role: .destructive) { generate() } }
        }
    }
    private func generate() { value.periods = (1...count).map { n in let start = firstMinute + (n - 1) * (duration + gap); return Period(number: n, startMinute: start, endMinute: start + duration) } }
    private func save() {
        value.isConfirmed = true; value.effectiveFrom = semester.calendar.startOfDay(for: value.effectiveFrom)
        if store.apply("修改作息", { data in data.bellSchedules.removeAll { $0.id == value.id || ($0.semesterID == semester.id && semester.calendar.isDate($0.effectiveFrom, inSameDayAs: value.effectiveFrom)) }; data.bellSchedules.append(value) }) { dismiss() }
    }
}

struct DayOverrideEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let semester: Semester
    @State private var target = Date.now
    @State private var source = Date.now
    @State private var preview: [Occurrence]?
    @State private var previewError: String?
    private var overrides: [DayOverride] { store.snapshot.dayOverrides.filter { $0.semesterID == semester.id }.sorted { $0.date < $1.date } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("调休日期", selection: $target, displayedComponents: .date)
                    DatePicker("按照哪一天上课", selection: $source, displayedComponents: .date)
                    Button("预览调整后的课程") { previewChange() }
                } footer: { Text("目标日期原有的课程将被替换，采用来源日期对应教学周和星期的课程。来源日期本身保持不变。按节次上课的课程，需要目标日已有生效的学校作息。") }
                if let previewError {
                    Section("请检查后再预览") { Label(previewError, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.red) }
                }
                if let preview {
                    Section("调整后 · \(preview.count) 次课") {
                        if preview.isEmpty { Text("来源日期没有符合上课周数的课程").foregroundStyle(.secondary) }
                        ForEach(preview) { CourseRow(occurrence: $0, timeZoneID: semester.timeZoneID) }
                        Button("确认应用调休") {
                            let value = DayOverride(semesterID: semester.id, date: semester.calendar.startOfDay(for: target), followsDate: semester.calendar.startOfDay(for: source))
                            if store.apply("学校调休", { data in data.dayOverrides.removeAll { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: value.date) }; data.dayOverrides.append(value) }) { dismiss() }
                            else { previewError = store.errorMessage ?? "保存前资料发生变化，请重新核对调休安排。"; self.preview = nil }
                        }
                    }
                }
                if !overrides.isEmpty {
                    Section("已设置的调休") {
                        ForEach(overrides) { value in HStack { Text("\(Display.day(value.date, in: semester)) 按 \(Display.day(value.followsDate, in: semester)) 上课"); Spacer(); Button(role: .destructive) { store.apply("移除调休") { $0.dayOverrides.removeAll { $0.id == value.id } } } label: { Image(systemName: "trash") } } }
                    }
                }
            }.environment(\.timeZone, semester.calendar.timeZone).navigationTitle("学校调休").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onChange(of: target) { preview = nil; previewError = nil }.onChange(of: source) { preview = nil; previewError = nil }
        }
    }
    private func previewChange() {
        preview = nil; previewError = nil
        var data = store.snapshot
        let value = DayOverride(semesterID: semester.id, date: semester.calendar.startOfDay(for: target), followsDate: semester.calendar.startOfDay(for: source))
        data.dayOverrides.removeAll { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: value.date) }; data.dayOverrides.append(value)
        do { try BackupCodec.validate(data); preview = ScheduleEngine.occurrences(snapshot: data, semesterID: semester.id).filter { semester.calendar.isDate($0.start, inSameDayAs: target) } }
        catch { previewError = error.localizedDescription }
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section("课表属于你") { Text("课程资料默认保存在设备。配置 iCloud 的版本仅同步至你自己的 Apple 账户，无需注册课序账号。") }
            Section("识别与云端") { Text("本地识别不上传课表。只有你主动选择云端增强并确认上传内容时，资料才会发送到你配置的模型服务。请查看该服务的数据政策。API Key 保存在本机 Keychain，不进入 iCloud 或备份。") }
            Section("系统权限") { Text("照片通过系统选择器读取你选择的项目。相机仅用于扫描。通知和日历权限只在启用相关功能时请求。课序只管理自己创建的日历事件。") }
            Section("备份与删除") { Text("可以导出完整课表备份或删除学期。恢复前自动备份存于 App 文稿的 Backups 文件夹。导入草稿与原件留在本地，可在导入页面清除。如需移除日历事件，请在删除学期前撤销日历同步；选择保留后，需在系统日历中管理这些事件。") }
            Section("无广告与追踪") { Text("本版本不包含广告、用户行为追踪或开发者运营的数据后端。系统日历和模型服务分别遵循对应服务的政策。") }
        }.navigationTitle("隐私与数据")
    }
}
