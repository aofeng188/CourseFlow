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

struct RuleSummary: View {
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

struct RecentCourseField: View {
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

struct EditorErrors: View {
    let errors: [String]
    var body: some View {
        if !errors.isEmpty {
            Section("请检查后保存") { ForEach(Array(errors.enumerated()), id: \.offset) { _, message in Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.red) } }
        }
    }
}

enum CourseEditError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

enum CourseEditChecks {
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
