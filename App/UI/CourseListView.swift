import SwiftUI
import CourseKit

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
    private var now: Date { PreviewClock.now(.now) }
    /// "周一、周四 · 1-18 周": the weekdays it meets, then every week it meets in.
    private func schedule(_ rules: [MeetingRule]) -> String {
        let days = Set(rules.map(\.weekday)).sorted().map { Display.weekdays[max(0, min(6, $0 - 1))] }
        let weeks = rules.isEmpty ? nil : WeekSelection.summary(Array(Set(rules.flatMap(\.weeks))))
        return ([days.isEmpty ? "尚未安排时间" : days.joined(separator: "、")] + (weeks.map { [$0] } ?? [])).joined(separator: " · ")
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
                        let rules = store.snapshot.rules.filter { $0.courseID == course.id }
                        Button { if selecting { if selected.contains(course.id) { selected.remove(course.id) } else { selected.insert(course.id) } } else { onCourse(course) } } label: {
                            HStack(spacing: 14) {
                                if selecting { Image(systemName: selected.contains(course.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(course.id) ? Palette.accent : Color.secondary).font(.title3) }
                                CourseAvatar(name: course.name, colorIndex: course.colorIndex, size: 44)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(course.name).font(.headline).foregroundStyle(.primary)
                                    Text(schedule(rules)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    if let next = store.occurrences.first(where: { $0.courseID == course.id && $0.end > now }) {
                                        let when = next.start <= now ? "正在上课" : Display.relativeStart(next.start, now: now, in: semester)
                                        Text("\(Image(systemName: next.start <= now ? "dot.radiowaves.left.and.right" : "clock")) \(when)\(next.location.isEmpty ? "" : " · \(next.location)")")
                                            .font(.caption.weight(.medium)).foregroundStyle(Palette.color(course.colorIndex)).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if !selecting { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                            }.padding(.vertical, 6).contentShape(Rectangle())
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
