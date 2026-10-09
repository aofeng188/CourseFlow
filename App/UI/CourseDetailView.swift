import SwiftUI
import CourseKit

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
