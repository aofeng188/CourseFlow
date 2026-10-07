import SwiftUI
import CourseKit

struct CourseEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let semester: Semester
    private let originalCourse: Course?
    private let fromOccurrence: Occurrence?
    @State private var course: Course
    @State private var rules: [MeetingRule] = []
    @State private var loaded = false
    @State private var errors: [String] = []
    @State private var conflictMessage = ""
    @State private var confirmConflicts = false

    init(semester: Semester, course: Course? = nil, from occurrence: Occurrence? = nil) {
        self.semester = semester; originalCourse = course; fromOccurrence = occurrence
        _course = State(initialValue: course ?? Course(semesterID: semester.id, name: ""))
    }

    private var minimumWeek: Int { max(1, min(semester.weekCount, fromOccurrence?.week ?? 1)) }
    private var title: String { fromOccurrence != nil ? "从本次起修改" : (originalCourse == nil ? "添加课程" : "编辑课程") }

    var body: some View {
        NavigationStack {
            Form {
                if fromOccurrence != nil {
                    Section {
                        Label(course.name, systemImage: "arrow.triangle.branch").font(.headline)
                        Text("仅修改这条安排从第 \(minimumWeek) 周起的课程。更早的安排与单次调整保留；课程名称、颜色等资料请在“全部安排”中修改。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Section("课程资料") {
                        TextField("课程名称", text: $course.name).accessibilityIdentifier("course-name")
                        colorChoices
                        TextField("备注、教材或其他说明", text: $course.notes, axis: .vertical).lineLimit(3...6)
                    }
                    reminderSection
                }
                Section {
                    ForEach($rules) { $rule in
                        NavigationLink {
                            MeetingRuleEditor(rule: $rule, semester: semester, minimumWeek: minimumWeek)
                        } label: { RuleSummary(rule: rule) }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) { rules.removeAll { $0.id == rule.id } }
                            Button("复制") { duplicate(rule) }.tint(Palette.accent)
                        }
                        .contextMenu {
                            Button("复制这条安排", systemImage: "doc.on.doc") { duplicate(rule) }
                            Button("删除这条安排", systemImage: "trash", role: .destructive) { rules.removeAll { $0.id == rule.id } }
                        }
                    }
                    Button("添加上课安排", systemImage: "plus") { addRule() }.accessibilityIdentifier("add-meeting-rule")
                } header: { Text("上课安排 · \(rules.count) 条") } footer: {
                    Text("同一门课可添加多条安排，分别设置星期、上课周数和地点。向左滑动可复制或删除。")
                }
                EditorErrors(errors: errors)
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold).accessibilityIdentifier("save-course") }
            }
            .task { load() }
            .alert("发现时间重叠", isPresented: $confirmConflicts) {
                Button("返回检查", role: .cancel) {}
                Button("仍然保存") { save(allowConflicts: true) }
            } message: { Text(conflictMessage) }
        }
    }

    private var colorChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("课程颜色").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 12)], spacing: 4) {
                ForEach(Palette.colors.indices, id: \.self) { index in
                    Button { course.colorIndex = index } label: {
                        Circle().fill(Palette.color(index)).frame(width: 28, height: 28)
                            .overlay { if course.colorIndex == index { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Color(.systemBackground)) } }
                            .padding(.vertical, 6)
                    }.buttonStyle(.plain).accessibilityLabel("课程颜色 \(index + 1)")
                        .accessibilityAddTraits(course.colorIndex == index ? .isSelected : [])
                }
            }
        }.padding(.vertical, 3)
    }

    private var reminderSection: some View {
        Section {
            Picker("上课提醒", selection: Binding<Int>(get: {
                course.reminderMinutes == nil ? -2 : (course.reminderMinutes == -1 ? -1 : 0)
            }, set: { course.reminderMinutes = $0 == -2 ? nil : ($0 == -1 ? -1 : 10) })) {
                Text("跟随全局设置").tag(-2)
                Text("本课程不提醒").tag(-1)
                Text("单独设置提前时间").tag(0)
            }
            if let minutes = course.reminderMinutes, minutes >= 0 {
                Stepper("提前 \(minutes) 分钟", value: Binding(get: { course.reminderMinutes ?? 10 }, set: { course.reminderMinutes = $0 }), in: 0...120, step: 5)
            }
        } header: { Text("提醒") } footer: { Text("连堂课默认只在本次安排的第一节前提醒。请同时在设置中开启上课提醒。") }
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        let existing = store.snapshot.rules.filter { $0.courseID == course.id }
        if let fromOccurrence, let original = existing.first(where: { $0.id == fromOccurrence.ruleID }) {
            var future = original; future.id = UUID(); future.weeks = original.weeks.filter { $0 >= minimumWeek }
            rules = [future]
        } else if fromOccurrence != nil { errors = ["这条安排已不存在，请关闭后重新选择课程。"] }
        else { rules = existing; if originalCourse == nil { addRule() } }
    }

    private func addRule() {
        let last = rules.last
        let hasBell = store.snapshot.bellSchedules.contains { $0.semesterID == semester.id && $0.isConfirmed }
        rules.append(MeetingRule(courseID: course.id, weekday: last.map { $0.weekday % 7 + 1 } ?? 1, weeks: Array(minimumWeek...semester.weekCount), periodNumbers: hasBell ? (last?.periodNumbers.isEmpty == false ? last!.periodNumbers : [1, 2]) : [], startMinute: hasBell ? nil : 480, endMinute: hasBell ? nil : 525, location: last?.location ?? "", teacher: last?.teacher ?? ""))
    }

    private func duplicate(_ original: MeetingRule) { var copied = original; copied.id = UUID(); rules.append(copied) }

    private func candidate(from snapshot: ScheduleSnapshot? = nil) throws -> ScheduleSnapshot {
        var value = snapshot ?? store.snapshot
        var edited = course; edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rules.isEmpty else { throw CourseEditError.message("请至少添加一条上课安排") }
        let problems = rules.enumerated().flatMap { index, rule in
            let draft = DraftLesson(name: edited.name, weekday: rule.weekday, weeks: rule.weeks, periods: rule.periodNumbers, startMinute: rule.startMinute, endMinute: rule.endMinute, location: rule.location, teacher: rule.teacher)
            return DraftValidator.issues(for: draft, semester: semester, bellSchedules: value.bellSchedules).map { "安排 \(index + 1)：\($0)" }
        }
        guard problems.isEmpty else { throw CourseEditError.message(problems.joined(separator: "\n")) }
        if let fromOccurrence {
            guard CourseEditChecks.canEditFuture(fromOccurrence, snapshot: value, semester: semester) else { throw CourseEditError.message("额外补课或调休课程请使用“仅本次”或“全部安排”修改，避免影响原周次的历史课程。") }
            value = try ScheduleEditing.replacingFuture(ruleID: fromOccurrence.ruleID, startingWeek: minimumWeek, with: rules, in: value)
        } else {
            value = try ScheduleEditing.replacingAllRules(for: edited, with: rules, in: value)
        }
        try BackupCodec.validate(value)
        return value
    }

    private func save(allowConflicts: Bool = false) {
        do {
            let value = try candidate()
            if !allowConflicts, let message = CourseEditChecks.conflicts(in: value, semester: semester, courseIDs: [course.id]) {
                conflictMessage = message; confirmConflicts = true; return
            }
            var editError: String?
            let saved = store.apply(fromOccurrence == nil ? "编辑课程" : "修改后续安排") { current in
                do { current = try candidate(from: current) } catch { editError = error.localizedDescription }
            }
            if let editError { errors = [editError] }
            else if saved { dismiss() }
            else { errors = [store.errorMessage ?? "未能保存，请重试。"] }
        } catch { errors = [error.localizedDescription] }
    }
}

private struct MeetingRuleEditor: View {
    @Environment(AppStore.self) private var store
    @Binding var rule: MeetingRule
    let semester: Semester
    var minimumWeek = 1
    @State private var weekText = ""
    @State private var weekError: String?
    private var bells: [BellSchedule] { store.snapshot.bellSchedules.filter { $0.semesterID == semester.id && $0.isConfirmed } }
    private var periods: [Int] { let values = Set(bells.flatMap { $0.periods.map(\.number) }).sorted(); return values.isEmpty ? Array(1...12) : values }
    private var selectedWeeks: Binding<[Int]> { Binding(get: { rule.weeks }, set: { rule.weeks = $0.filter { $0 >= minimumWeek } }) }
    private var timeMode: Binding<Int> {
        Binding(get: { rule.startMinute == nil ? 0 : 1 }, set: { value in
            if value == 0 { rule.startMinute = nil; rule.endMinute = nil; if rule.periodNumbers.isEmpty { rule.periodNumbers = Array(periods.prefix(2)) } }
            else { rule.periodNumbers = []; rule.startMinute = 480; rule.endMinute = 525 }
        })
    }
    var body: some View {
        Form {
            Section("上课时间") {
                Picker("星期", selection: $rule.weekday) { ForEach(1...7, id: \.self) { Text(Display.weekdays[$0 - 1]).tag($0) } }
                Picker("时间方式", selection: timeMode) { Text("按节次").tag(0); Text("具体时间").tag(1) }.pickerStyle(.segmented)
                if rule.startMinute == nil {
                    if bells.isEmpty { Label("还没有已确认的学校作息，请先在设置中添加或导入作息表。", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
                        ForEach(periods, id: \.self) { period in
                            Button { if rule.periodNumbers.contains(period) { rule.periodNumbers.removeAll { $0 == period } } else { rule.periodNumbers.append(period); rule.periodNumbers.sort() } } label: {
                                Text("第 \(period) 节").font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .foregroundStyle(rule.periodNumbers.contains(period) ? Color(.systemBackground) : Color.primary)
                                    .background(rule.periodNumbers.contains(period) ? Palette.accent : Color.secondary.opacity(0.09), in: .rect(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityAddTraits(rule.periodNumbers.contains(period) ? .isSelected : [])
                        }
                    }.padding(.vertical, 7)
                } else {
                    MinutePicker(title: "开始时间", minute: Binding(get: { rule.startMinute ?? 480 }, set: { rule.startMinute = $0 }))
                    MinutePicker(title: "结束时间", minute: Binding(get: { rule.endMinute ?? 525 }, set: { rule.endMinute = $0 }))
                }
            }
            Section {
                RecentCourseField(title: "上课地点", text: $rule.location, values: recentValues(\.location), symbol: "mappin")
                RecentCourseField(title: "任课教师", text: $rule.teacher, values: recentValues(\.teacher), symbol: "person")
            } header: { Text("地点与教师") } footer: { Text("点击历史按钮，可以复用已有课程的地点和教师。") }
            Section {
                HStack {
                    TextField("例如 1-8,10-16 或 1-16周(单)", text: $weekText).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("应用") { applyWeekText() }.buttonStyle(.borderless)
                }
                if let weekError { Text(weekError).font(.caption).foregroundStyle(.red) }
                WeekSelectionGrid(selected: selectedWeeks, count: semester.weekCount)
            } header: { Text("上课周数") } footer: {
                Text(minimumWeek > 1 ? "本次只修改第 \(minimumWeek) 周及之后的课程；较早周数不会选中。" : "支持范围、单双周和不连续周数，例如 1-16周(单)，排除7周。")
            }
            Section { Text("返回课程页后点击“保存”，这些修改才会生效。").font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("上课安排").navigationBarTitleDisplayMode(.inline)
        .onAppear { if weekText.isEmpty { weekText = WeekSelection.summary(rule.weeks) } }
    }
    private func recentValues(_ path: KeyPath<MeetingRule, String>) -> [String] {
        CourseEditChecks.recent(store.snapshot.rules.filter { item in store.snapshot.courses.contains { $0.id == item.courseID && $0.semesterID == semester.id } }.map { $0[keyPath: path] })
    }
    private func applyWeekText() {
        do {
            let weeks = try WeekSelection.parse(weekText, maxWeek: semester.weekCount).filter { $0 >= minimumWeek }
            guard !weeks.isEmpty else { throw CourseEditError.message("请选择第 \(minimumWeek) 周及之后的上课周") }
            rule.weeks = weeks; weekError = nil; weekText = WeekSelection.summary(weeks)
        } catch { weekError = error.localizedDescription }
    }
}

struct CourseDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let courseID: UUID
    var occurrence: Occurrence? = nil
    @State private var focused: Occurrence?
    @State private var useInitialOccurrence = true
    @State private var sheet: CourseDetailSheet?
    @State private var confirmDelete = false
    @State private var confirmCancel = false
    @State private var pendingExceptionRemoval: LessonException?
    @State private var confirmExceptionConflicts = false
    @State private var exceptionConflictMessage = ""
    private var course: Course? { store.snapshot.courses.first { $0.id == courseID } }
    private var semester: Semester? { course.flatMap { value in store.snapshot.semesters.first { $0.id == value.semesterID } } }
    private var rules: [MeetingRule] { store.snapshot.rules.filter { $0.courseID == courseID } }
    private var exceptions: [LessonException] {
        let ruleIDs = Set(rules.map(\.id))
        return store.snapshot.exceptions.filter { ruleIDs.contains($0.ruleID) }.sorted { ($0.replacementDate ?? $0.originalDate) > ($1.replacementDate ?? $1.originalDate) }
    }
    private var upcoming: [Occurrence] { store.occurrences.filter { $0.courseID == courseID && $0.end > .now }.sorted { $0.start < $1.start } }
    private var context: Occurrence? {
        if let selected = focused ?? (useInitialOccurrence ? occurrence : nil) { return store.occurrences.first { $0.id == selected.id } ?? selected }
        return upcoming.first
    }
    private var contextException: LessonException? {
        guard let context, let semester else { return nil }
        return store.snapshot.exceptions.first { item in
            "added-\(item.id.uuidString.lowercased())" == context.id || (item.kind != .added && item.ruleID == context.ruleID && semester.calendar.isDate(item.originalDate, inSameDayAs: context.originalDate))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let course, let semester {
                    List {
                        Section {
                            HStack(spacing: 14) {
                                CourseDot(colorIndex: course.colorIndex)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(course.name).font(.title2.weight(.bold))
                                    Text(semester.name).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 9)
                            if !course.notes.isEmpty { Text(course.notes).textSelection(.enabled) }
                            LabeledContent("课程提醒", value: reminderText(course))
                        }
                        if let context {
                            Section(focused != nil || occurrence != nil ? "本次上课" : "下次上课") {
                                LabeledContent("日期", value: "\(Display.day(context.start, in: semester)) · 第 \(context.week) 周")
                                LabeledContent("时间", value: "\(Display.time(context.start, zone: semester.timeZoneID))–\(Display.time(context.end, zone: semester.timeZoneID))")
                                LabeledContent("地点", value: context.location.isEmpty ? "尚未填写" : context.location)
                                if !context.teacher.isEmpty { LabeledContent("教师", value: context.teacher) }
                                if contextException?.kind == .cancelled { Label("本次已停课", systemImage: "calendar.badge.minus").foregroundStyle(.orange) }
                                if context.segments.count > 1 {
                                    ForEach(Array(context.segments.enumerated()), id: \.offset) { _, segment in
                                        LabeledContent(segment.periodNumber.map { "第 \($0) 节" } ?? "授课时段", value: "\(Display.time(segment.start, zone: semester.timeZoneID))–\(Display.time(segment.end, zone: semester.timeZoneID))").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                Menu("调整课程", systemImage: "slider.horizontal.3") {
                                    Button("仅本次：时间或地点") { sheet = .exception(semester, course, context, .moved) }
                                    Button("从本次起：后续安排") { sheet = .edit(semester, course, context) }.disabled(!CourseEditChecks.canEditFuture(context, snapshot: store.snapshot, semester: semester))
                                    Button("全部安排") { sheet = .edit(semester, course, nil) }
                                }.disabled(contextException?.kind == .cancelled)
                                if !CourseEditChecks.canEditFuture(context, snapshot: store.snapshot, semester: semester) {
                                    Text("额外补课和调休课程可修改仅本次或全部安排。").font(.caption).foregroundStyle(.secondary)
                                }
                                if contextException?.kind != .cancelled { Button("本次停课", systemImage: "calendar.badge.minus", role: .destructive) { confirmCancel = true } }
                                Button("新增一次补课", systemImage: "calendar.badge.plus") { sheet = .exception(semester, course, context, .added) }
                                if contextException != nil { Button("撤销本次调整", systemImage: "arrow.uturn.backward") { revertContext() } }
                            }
                        }
                        Section("所有上课安排") {
                            ForEach(rules) { rule in RuleSummary(rule: rule) }
                            Button("编辑全部安排", systemImage: "pencil") { sheet = .edit(semester, course, nil) }
                        }
                        if !exceptions.isEmpty { exceptionHistory(semester) }
                        if upcoming.count > 1 {
                            Section("接下来的课程") {
                                ForEach(Array(upcoming.prefix(8))) { item in
                                    Button { focused = item } label: {
                                        VStack(alignment: .leading, spacing: 3) { Text(Display.day(item.start, in: semester)).font(.caption).foregroundStyle(.secondary); CourseRow(occurrence: item, timeZoneID: semester.timeZoneID) }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        Section { Button("删除这门课程", systemImage: "trash", role: .destructive) { confirmDelete = true } }
                    }
                } else { ContentUnavailableView("课程已不存在", systemImage: "books.vertical", description: Text("课程可能已被删除或随备份恢复而替换。")) }
            }
            .navigationTitle("课程详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $sheet) { value in
                switch value {
                case .edit(let semester, let course, let from): CourseEditor(semester: semester, course: course, from: from)
                case .exception(let semester, let course, let occurrence, let kind): LessonExceptionEditor(semester: semester, course: course, occurrence: occurrence, kind: kind)
                }
            }
            .confirmationDialog("删除这门课程？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除课程及所有安排", role: .destructive) { deleteCourse() }
            } message: { Text("这门课的上课安排、调停补课及对应提醒都会移除。可从课表菜单撤销最近修改。") }
            .confirmationDialog("本次停课？", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("确认本次停课", role: .destructive) { cancelContext() }
            } message: { Text("仅取消当前选中的这一次课，其他周的安排保留。") }
            .alert("恢复后存在时间重叠", isPresented: $confirmExceptionConflicts) {
                Button("返回检查", role: .cancel) { pendingExceptionRemoval = nil }
                Button("仍然恢复") { if let pendingExceptionRemoval { removeException(pendingExceptionRemoval, allowConflicts: true) } }
            } message: { Text(exceptionConflictMessage) }
            .onChange(of: store.occurrences) {
                guard let selected = focused ?? (useInitialOccurrence ? occurrence : nil),
                      !store.occurrences.contains(where: { $0.id == selected.id }), contextException?.kind != .cancelled else { return }
                focused = upcoming.first { $0.start >= selected.start } ?? upcoming.first
                useInitialOccurrence = false
            }
        }
    }

    private func reminderText(_ course: Course) -> String {
        guard let minutes = course.reminderMinutes else { return "跟随全局设置" }
        return minutes < 0 ? "本课程不提醒" : "提前 \(minutes) 分钟"
    }
    private func exceptionHistory(_ semester: Semester) -> some View {
        Section {
            ForEach(exceptions) { item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(exceptionDescription(item, semester: semester), systemImage: item.kind == .cancelled ? "calendar.badge.minus" : (item.kind == .added ? "calendar.badge.plus" : "arrow.triangle.2.circlepath"))
                            .font(.subheadline.weight(.medium))
                        if let start = item.startMinute, let end = item.endMinute { Text("\(Period.clock(start))–\(Period.clock(end))").font(.caption).foregroundStyle(.secondary) }
                        if let location = item.location, !location.isEmpty { Text(location).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    Menu {
                        Button(item.kind == .added ? "移除这次补课" : (item.kind == .cancelled ? "恢复本次上课" : "撤销这次调课"), systemImage: item.kind == .added ? "trash" : "arrow.uturn.backward", role: item.kind == .added ? .destructive : nil) { removeException(item) }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 32, height: 32).accessibilityLabel("管理\(exceptionDescription(item, semester: semester))") }
                }.padding(.vertical, 4)
            }
        } header: { Text("单次调整记录") } footer: { Text("停课记录会保留在这里，可随时恢复。撤销单次调整后，课程按当前的重复规则安排。") }
    }
    private func exceptionDescription(_ item: LessonException, semester: Semester) -> String {
        switch item.kind {
        case .cancelled: "\(Display.day(item.originalDate, in: semester)) 已停课"
        case .added: "\(Display.day(item.replacementDate ?? item.originalDate, in: semester)) 补课"
        case .moved:
            if let destination = item.replacementDate, !semester.calendar.isDate(destination, inSameDayAs: item.originalDate) {
                "\(Display.day(item.originalDate, in: semester)) → \(Display.day(destination, in: semester))"
            } else { "\(Display.day(item.originalDate, in: semester)) 临时调整" }
        }
    }
    private func deleteCourse() {
        if store.apply("删除课程", { value in
            let ids = Set(value.rules.filter { $0.courseID == courseID }.map(\.id))
            value.courses.removeAll { $0.id == courseID }; value.rules.removeAll { $0.courseID == courseID }; value.exceptions.removeAll { ids.contains($0.ruleID) }
        }) { dismiss() }
    }
    private func cancelContext() {
        guard let context, let semester else { return }
        let existing = contextException
        _ = store.apply("本次停课") { value in
            if let existing, existing.kind == .added { value.exceptions.removeAll { $0.id == existing.id }; return }
            value.exceptions.removeAll { $0.kind != .added && $0.ruleID == context.ruleID && semester.calendar.isDate($0.originalDate, inSameDayAs: context.originalDate) }
            value.exceptions.append(LessonException(id: existing?.id ?? UUID(), ruleID: context.ruleID, originalDate: context.originalDate, kind: .cancelled))
        }
    }
    private func revertContext() {
        guard let existing = contextException else { return }
        removeException(existing)
    }
    private func removeException(_ existing: LessonException, allowConflicts: Bool = false) {
        guard let semester else { return }
        if !allowConflicts && existing.kind != .added {
            var candidate = store.snapshot
            candidate.exceptions.removeAll { $0.id == existing.id }
            if let message = CourseEditChecks.conflicts(in: candidate, semester: semester, courseIDs: [courseID]) {
                pendingExceptionRemoval = existing; exceptionConflictMessage = message; confirmExceptionConflicts = true; return
            }
        }
        if store.apply("撤销单次调整", { $0.exceptions.removeAll { $0.id == existing.id } }) { pendingExceptionRemoval = nil }
    }
}

private enum CourseDetailSheet: Identifiable {
    case edit(Semester, Course, Occurrence?)
    case exception(Semester, Course, Occurrence, ExceptionKind)
    var id: String {
        switch self {
        case .edit(_, let course, let item): "edit-\(course.id)-\(item?.id ?? "all")"
        case .exception(_, _, let item, let kind): "exception-\(item.id)-\(kind.rawValue)"
        }
    }
}

private struct LessonExceptionEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let semester: Semester
    let course: Course
    let occurrence: Occurrence
    let kind: ExceptionKind
    @State private var date: Date
    @State private var startMinute: Int
    @State private var endMinute: Int
    @State private var location: String
    @State private var usePeriods: Bool
    @State private var errors: [String] = []
    @State private var confirmConflicts = false
    @State private var conflictMessage = ""

    init(semester: Semester, course: Course, occurrence: Occurrence, kind: ExceptionKind) {
        self.semester = semester; self.course = course; self.occurrence = occurrence; self.kind = kind
        _date = State(initialValue: kind == .added ? semester.calendar.date(byAdding: .day, value: 1, to: occurrence.start)! : occurrence.start)
        _startMinute = State(initialValue: Display.minutes(occurrence.start, in: semester))
        _endMinute = State(initialValue: semester.calendar.isDate(occurrence.start, inSameDayAs: occurrence.end) ? Display.minutes(occurrence.end, in: semester) : 1440)
        _location = State(initialValue: occurrence.location)
        _usePeriods = State(initialValue: occurrence.segments.allSatisfy { $0.periodNumber != nil })
    }
    private var originalRule: MeetingRule? { store.snapshot.rules.first { $0.id == occurrence.ruleID } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(course.name).font(.headline)
                    DatePicker(kind == .added ? "补课日期" : "上课日期", selection: $date, displayedComponents: .date)
                    if originalRule?.periodNumbers.isEmpty == false {
                        Toggle("沿用节次，使用当日学校作息", isOn: $usePeriods)
                    }
                    if !usePeriods {
                        MinutePicker(title: "开始时间", minute: $startMinute)
                        MinutePicker(title: "结束时间", minute: $endMinute)
                    }
                    RecentCourseField(title: "上课地点", text: $location, values: CourseEditChecks.recent(store.snapshot.rules.map(\.location)), symbol: "mappin")
                } header: { Text(kind == .added ? "额外增加一次课程" : "只调整这一次") } footer: {
                    Text(kind == .added ? "补课不会占用或取消原有课程。" : "原定 \(Display.day(occurrence.originalDate, in: semester)) 的这一次课会更新，其他周保持原安排。")
                }
                EditorErrors(errors: errors)
            }
            .navigationTitle(kind == .added ? "添加补课" : "调整本次课程").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold) }
            }
            .alert("发现时间重叠", isPresented: $confirmConflicts) {
                Button("返回检查", role: .cancel) {}
                Button("仍然保存") { save(allowConflicts: true) }
            } message: { Text(conflictMessage) }
            .environment(\.timeZone, semester.calendar.timeZone).environment(\.calendar, semester.calendar)
        }
    }

    private func save(allowConflicts: Bool = false) {
        guard originalRule != nil else { errors = ["原上课安排已不存在，请重新打开课程。 "]; return }
        do {
            var value = store.snapshot
            let existing = kind == .added ? nil : value.exceptions.first { item in
                "added-\(item.id.uuidString.lowercased())" == occurrence.id || (item.kind != .added && item.ruleID == occurrence.ruleID && semester.calendar.isDate(item.originalDate, inSameDayAs: occurrence.originalDate))
            }
            let actualKind: ExceptionKind = existing?.kind == .added ? .added : kind
            let change = LessonException(id: existing?.id ?? UUID(), ruleID: occurrence.ruleID, originalDate: kind == .added ? semester.calendar.startOfDay(for: date) : occurrence.originalDate, kind: actualKind, replacementDate: semester.calendar.startOfDay(for: date), startMinute: usePeriods ? nil : startMinute, endMinute: usePeriods ? nil : endMinute, location: location)
            if let existing { value.exceptions.removeAll { $0.id == existing.id } }
            value.exceptions.append(change)
            try BackupCodec.validate(value)
            let generated = ScheduleEngine.occurrences(snapshot: value, semesterID: semester.id)
            let expectedID = actualKind == .added ? "added-\(change.id.uuidString.lowercased())" : occurrence.id
            guard generated.contains(where: { $0.id == expectedID }) else { throw CourseEditError.message("当前规则无法生成这次课程，请检查日期、节次和学校作息。") }
            if !allowConflicts, let message = CourseEditChecks.conflicts(in: value, semester: semester, occurrenceIDs: [expectedID]) {
                conflictMessage = message; confirmConflicts = true; return
            }
            if store.apply(kind == .added ? "添加补课" : "调整本次课程", { current in
                if let existing { current.exceptions.removeAll { $0.id == existing.id } }
                if actualKind != .added {
                    current.exceptions.removeAll { $0.kind != .added && $0.ruleID == occurrence.ruleID && semester.calendar.isDate($0.originalDate, inSameDayAs: occurrence.originalDate) }
                }
                current.exceptions.append(change)
            }) { dismiss() }
            else { errors = [store.errorMessage ?? "未能保存，请重试。"] }
        } catch { errors = [error.localizedDescription] }
    }
}

struct CourseListView: View {
    @Environment(AppStore.self) private var store
    var onCourse: (Course) -> Void
    @State private var query = ""
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var batch: BatchSelection?
    private var courses: [Course] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.courses.filter { course in
            query.isEmpty || ([course.name, course.notes] + store.snapshot.rules.filter { $0.courseID == course.id }.flatMap { [$0.teacher, $0.location] }).contains { $0.localizedStandardContains(query) }
        }
    }
    var body: some View {
        List {
            if let semester = store.semester {
                Section {
                    if selecting {
                        HStack {
                            Text("已选择 \(selected.count) 门课程").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Button("选择搜索结果") { selected.formUnion(courses.map(\.id)) }.font(.subheadline)
                        }
                    }
                    ForEach(courses) { course in
                        Button { if selecting { if selected.contains(course.id) { selected.remove(course.id) } else { selected.insert(course.id) } } else { onCourse(course) } } label: {
                            HStack(spacing: 12) {
                                if selecting { Image(systemName: selected.contains(course.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(course.id) ? Palette.accent : Color.secondary).font(.title3) }
                                CourseDot(colorIndex: course.colorIndex)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(course.name).font(.headline).foregroundStyle(.primary)
                                    let rules = store.snapshot.rules.filter { $0.courseID == course.id }
                                    Text("\(rules.count) 条安排" + (rules.first.map { " · " + WeekSelection.summary($0.weeks) } ?? "")).font(.caption).foregroundStyle(.secondary)
                                    if let next = store.occurrences.first(where: { $0.courseID == course.id && $0.end > .now }) {
                                        Text("下次 \(Display.day(next.start, in: semester)) \(Display.time(next.start, zone: semester.timeZoneID)) · \(next.location.isEmpty ? "地点待补充" : next.location)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                                if !selecting { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } header: { Text("\(semester.name) · \(courses.count) 门课程") }
            }
        }
        .overlay {
            if store.semester == nil { ContentUnavailableView("先设置一个学期", systemImage: "calendar.badge.plus", description: Text("点击右上角添加按钮，开始建立自己的课程。")) }
            else if courses.isEmpty { ContentUnavailableView(query.isEmpty ? "还没有课程" : "没有找到相关课程", systemImage: "books.vertical", description: Text(query.isEmpty ? "导入课表或手动添加第一门课程。" : "试试课程名、教师或上课地点。")) }
        }
        .navigationTitle("课程").searchable(text: $query, prompt: "课程、教师或地点")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(selecting ? "完成选择" : "批量编辑") { selecting.toggle(); if !selecting { selected.removeAll() } }.disabled(store.courses.isEmpty) }
            if selecting {
                ToolbarItem(placement: .bottomBar) {
                    Button("编辑所选 \(selected.count) 门课程") { if let semester = store.semester { batch = BatchSelection(semester: semester, courseIDs: selected) } }.disabled(selected.isEmpty)
                }
            }
        }
        .sheet(item: $batch) { BatchCourseEditor(semester: $0.semester, courseIDs: $0.courseIDs) }
        .onChange(of: store.semester?.id) { selected.removeAll(); selecting = false }
    }
}

private struct BatchSelection: Identifiable { let id = UUID(); let semester: Semester; let courseIDs: Set<UUID> }

private struct BatchCourseEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let semester: Semester
    let courseIDs: Set<UUID>
    @State private var changeWeeks = false
    @State private var weeks: [Int] = []
    @State private var changeLocation = false
    @State private var location = ""
    @State private var changeTeacher = false
    @State private var teacher = ""
    @State private var errors: [String] = []
    @State private var confirmConflicts = false
    @State private var conflictMessage = ""
    private var affectedCount: Int { store.snapshot.rules.filter { courseIDs.contains($0.courseID) }.count }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("将修改所选 \(courseIDs.count) 门课程的 \(affectedCount) 条上课安排。").font(.subheadline).foregroundStyle(.secondary) }
                Section {
                    Toggle("统一上课周数", isOn: $changeWeeks)
                    if changeWeeks { WeekSelectionGrid(selected: $weeks, count: semester.weekCount) }
                } footer: { if changeWeeks { Text("所选课程每条安排的周数都会替换为这里选择的周数。") } }
                Section {
                    Toggle("统一上课地点", isOn: $changeLocation)
                    if changeLocation { RecentCourseField(title: "上课地点", text: $location, values: CourseEditChecks.recent(store.snapshot.rules.map(\.location)), symbol: "mappin") }
                    Toggle("统一任课教师", isOn: $changeTeacher)
                    if changeTeacher { RecentCourseField(title: "任课教师", text: $teacher, values: CourseEditChecks.recent(store.snapshot.rules.map(\.teacher)), symbol: "person") }
                } footer: { Text("只修改已打开的项目。已单独设置的临时地点仍然保留。保存后可从课表菜单撤销最近修改。") }
                EditorErrors(errors: errors)
            }
            .navigationTitle("批量编辑").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold).disabled(!(changeWeeks || changeLocation || changeTeacher) || affectedCount == 0) }
            }
            .onAppear { if weeks.isEmpty { weeks = Array(1...semester.weekCount) } }
            .alert("发现时间重叠", isPresented: $confirmConflicts) {
                Button("返回检查", role: .cancel) {}
                Button("仍然保存") { save(allowConflicts: true) }
            } message: { Text(conflictMessage) }
        }
    }
    private func save(allowConflicts: Bool = false) {
        do {
            var value = store.snapshot
            for index in value.rules.indices where courseIDs.contains(value.rules[index].courseID) {
                if changeWeeks { value.rules[index].weeks = weeks }
                if changeLocation { value.rules[index].location = location }
                if changeTeacher { value.rules[index].teacher = teacher }
            }
            try BackupCodec.validate(value)
            if !allowConflicts, let message = CourseEditChecks.conflicts(in: value, semester: semester, courseIDs: courseIDs) { conflictMessage = message; confirmConflicts = true; return }
            if store.apply("批量编辑课程", { current in
                for index in current.rules.indices where courseIDs.contains(current.rules[index].courseID) {
                    if changeWeeks { current.rules[index].weeks = weeks }
                    if changeLocation { current.rules[index].location = location }
                    if changeTeacher { current.rules[index].teacher = teacher }
                }
            }) { dismiss() }
            else { errors = [store.errorMessage ?? "未能保存，请重试。"] }
        } catch { errors = [error.localizedDescription] }
    }
}

private struct RuleSummary: View {
    let rule: MeetingRule
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Display.weekdays[max(0, min(6, rule.weekday - 1))]) · \(timeText)").font(.subheadline.weight(.semibold))
            Text(WeekSelection.summary(rule.weeks)).font(.caption).foregroundStyle(.secondary)
            if !rule.location.isEmpty || !rule.teacher.isEmpty { Text([rule.location, rule.teacher].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
    private var timeText: String {
        if let start = rule.startMinute, let end = rule.endMinute { return "\(Period.clock(start))–\(Period.clock(end))" }
        return rule.periodNumbers.isEmpty ? "时间待设置" : "第 " + rule.periodNumbers.sorted().map(String.init).joined(separator: "、") + " 节"
    }
}

private struct RecentCourseField: View {
    let title: String
    @Binding var text: String
    let values: [String]
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            TextField(title, text: $text)
            if !values.isEmpty {
                Menu { ForEach(values, id: \.self) { value in Button(value) { text = value } } } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 30, height: 30) }
                    .accessibilityLabel("复用最近的\(title)")
            }
        }
    }
}

private struct EditorErrors: View {
    let errors: [String]
    var body: some View {
        if !errors.isEmpty {
            Section("请检查后保存") { ForEach(Array(errors.enumerated()), id: \.offset) { _, message in Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.red) } }
        }
    }
}

private enum CourseEditError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

private enum CourseEditChecks {
    static func canEditFuture(_ occurrence: Occurrence, snapshot: ScheduleSnapshot, semester: Semester) -> Bool {
        !occurrence.id.hasPrefix("added-") && !snapshot.dayOverrides.contains { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: occurrence.originalDate) }
    }
    static func recent(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.reversed().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(12).map { $0 }
    }
    static func conflicts(in snapshot: ScheduleSnapshot, semester: Semester, courseIDs: Set<UUID> = [], occurrenceIDs: Set<String> = []) -> String? {
        let occurrences = ScheduleEngine.occurrences(snapshot: snapshot, semesterID: semester.id)
        let byID = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.id, $0) })
        let overlaps = ScheduleEngine.conflicts(in: occurrences).filter { conflict in
            occurrenceIDs.contains(conflict.firstID) || occurrenceIDs.contains(conflict.secondID) || byID[conflict.firstID].map { courseIDs.contains($0.courseID) } == true || byID[conflict.secondID].map { courseIDs.contains($0.courseID) } == true
        }
        guard !overlaps.isEmpty else { return nil }
        let details = overlaps.prefix(3).compactMap { conflict -> String? in
            guard let a = byID[conflict.firstID], let b = byID[conflict.secondID] else { return nil }
            return "\(Display.day(conflict.overlapStart, in: semester)) \(Display.time(conflict.overlapStart, zone: semester.timeZoneID))：\(a.courseName) 与 \(b.courseName)"
        }
        return "共有 \(overlaps.count) 组授课时间重叠：\n" + details.joined(separator: "\n") + "\n确认这些安排需要同时保留后，可以仍然保存。"
    }
}
