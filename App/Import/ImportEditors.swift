import SwiftUI
import CourseKit

struct ImportPasteView: View {
    let kind: ImportKind
    let onSubmit: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).frame(minHeight: 260).font(.body).accessibilityLabel("课表或作息表原文").accessibilityIdentifier("import-paste-text")
                } footer: {
                    Text(kind == .timetable ? "保留原文换行。可粘贴包含课程名称、星期、节次、周次、教师和地点的文字；多门课之间空一行。" : "每行一节，例如：第1节 08:00–08:45。")
                }
                Section {
                    PasteButton(payloadType: String.self) { values in text += values.joined(separator: "\n") }
                }
            }
            .navigationTitle("粘贴原文").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("识别") { onSubmit(text); dismiss() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("import-paste-recognize") }
            }
        }
    }
}

struct ImportLessonEditor: View {
    @State var lesson: DraftLesson
    let maxWeeks: Int
    let issues: [String]
    let assets: [ImportSourceAsset]
    let onSave: (DraftLesson) -> Void
    @State private var weekText = ""
    @State private var periodText = ""
    @State private var usesPeriods = true
    @State private var startText = ""
    @State private var endText = ""
    @State private var error: String?
    @State private var preview: ImportSourceAsset?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("课程") {
                    TextField("课程名称", text: $lesson.name).accessibilityIdentifier("import-lesson-name")
                    Picker("星期", selection: Binding(get: { lesson.weekday ?? 0 }, set: { lesson.weekday = $0 == 0 ? nil : $0 })) {
                        Text("待确认").tag(0)
                        ForEach(1...7, id: \.self) { index in Text("星期" + ["一", "二", "三", "四", "五", "六", "日"][index - 1]).tag(index) }
                    }
                    TextField("上课地点，例如主楼 A301", text: $lesson.location).accessibilityIdentifier("import-lesson-location")
                    TextField("授课教师（选填）", text: $lesson.teacher)
                }
                Section("上课时间") {
                    Picker("时间形式", selection: $usesPeriods) { Text("学校节次").tag(true); Text("具体时间").tag(false) }.pickerStyle(.segmented)
                    if usesPeriods {
                        TextField("节次，例如 1-2 或 1,3", text: $periodText).keyboardType(.numbersAndPunctuation)
                        HStack {
                            ForEach(["1-2", "3-4", "5-6", "7-8", "9-10"], id: \.self) { value in Button(value) { periodText = value }.buttonStyle(.bordered).font(.caption) }
                        }
                        Text("节次按你确认的学校作息换算；节间休息会保留。没有作息时可先关闭草稿，去导入作息表。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("开始 HH:mm", text: $startText).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("import-lesson-start")
                        TextField("结束 HH:mm", text: $endText).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("import-lesson-end")
                    }
                }
                Section("上课周次") {
                    TextField("例如 1-8、10-16双周、1,3,5", text: $weekText).textInputAutocapitalization(.never).accessibilityIdentifier("import-lesson-weeks")
                    HStack {
                        Button("全学期") { selectWeeks(Array(1...maxWeeks)) }
                        Button("单周") { selectWeeks((1...maxWeeks).filter { $0 % 2 == 1 }) }
                        Button("双周") { selectWeeks((1...maxWeeks).filter { $0 % 2 == 0 }) }
                        Button("清空") { selectWeeks([]) }
                    }.buttonStyle(.bordered).font(.caption)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                        ForEach(1...maxWeeks, id: \.self) { week in
                            let selected = currentWeeks.contains(week)
                            Button {
                                var weeks = Set(currentWeeks)
                                if selected { weeks.remove(week) } else { weeks.insert(week) }
                                selectWeeks(weeks.sorted())
                            } label: {
                                Text("\(week)").font(.callout.monospacedDigit()).frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .background(selected ? Color.accentColor : Color.secondary.opacity(0.1), in: .rect(cornerRadius: 9))
                                    .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
                            }.buttonStyle(.plain).accessibilityLabel("第\(week)周，\(selected ? "已选" : "未选")")
                        }
                    }
                    Text("不同周次在不同地点上课，可以复制条目后分别设置。未选周次的课程不能确认导入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !lesson.sourceText.isEmpty || !assets.isEmpty {
                    Section("对照原件") {
                        if let page = lesson.sourcePage, let asset = assets.first(where: { $0.pageNumber == page }) { Button("查看\(asset.label)", systemImage: "doc.text.magnifyingglass") { preview = asset } }
                        else if !assets.isEmpty {
                            Menu("查看导入原图") { ForEach(assets) { asset in Button(asset.label) { preview = asset } } }
                        }
                        Text(lesson.sourceText).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        ForEach(Array(Set(lesson.warnings)), id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("核对课程").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.accessibilityIdentifier("import-lesson-save") }
            }
            .sheet(item: $preview) { ImportSourcePreview(asset: $0) }
            .onAppear {
                weekText = lesson.weeks.isEmpty ? "" : WeekSelection.summary(lesson.weeks)
                periodText = lesson.periods.map(String.init).joined(separator: ",")
                usesPeriods = !lesson.periods.isEmpty || lesson.startMinute == nil
                startText = lesson.startMinute.map(Period.clock) ?? ""
                endText = lesson.endMinute.map(Period.clock) ?? ""
            }
        }
    }
    private var currentWeeks: [Int] { (try? WeekSelection.parse(weekText, maxWeek: maxWeeks)) ?? [] }
    private func selectWeeks(_ weeks: [Int]) { weekText = weeks.isEmpty ? "" : WeekSelection.summary(weeks) }
    private func save() {
        do {
            lesson.weeks = weekText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : try WeekSelection.parse(weekText, maxWeek: maxWeeks)
            if usesPeriods {
                let cleaned = periodText.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = ImportParser.numbers(cleaned)
                if !cleaned.isEmpty && parsed.isEmpty { throw ImportServiceError.message("请输入有效节次，例如 1-2 或 1,3。") }
                lesson.periods = parsed; lesson.startMinute = nil; lesson.endMinute = nil
            } else {
                let start = ImportParser.minute(startText)
                let end = endText.trimmingCharacters(in: .whitespacesAndNewlines) == "24:00" ? 1440 : ImportParser.minute(endText)
                if (!startText.isEmpty && start == nil) || (!endText.isEmpty && end == nil) { throw ImportServiceError.message("时间请使用 24 小时制，例如 08:00。") }
                lesson.periods = []; lesson.startMinute = start; lesson.endMinute = end
            }
            onSave(lesson); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ImportBatchEditor: View {
    let count: Int
    let maxWeeks: Int
    let onSave: ([Int]?, String?, String?) -> Void
    @State private var changeWeeks = false
    @State private var changeLocation = false
    @State private var changeTeacher = false
    @State private var weeks = ""
    @State private var location = ""
    @State private var teacher = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("修改已勾选的 \(count) 条课程，只应用开启的字段。") }
                Section {
                    Toggle("修改周次", isOn: $changeWeeks)
                    if changeWeeks {
                        TextField("例如 1-8、1-16单周", text: $weeks)
                        Button("设置为全学期") { weeks = "1-\(maxWeeks)" }
                    }
                    Toggle("修改地点", isOn: $changeLocation)
                    if changeLocation { TextField("新的上课地点，可留空清除", text: $location) }
                    Toggle("修改教师", isOn: $changeTeacher)
                    if changeTeacher { TextField("新的教师，可留空清除", text: $teacher) }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .navigationTitle("批量编辑").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        do { let parsed = changeWeeks ? try WeekSelection.parse(weeks, maxWeek: maxWeeks) : nil; onSave(parsed, changeLocation ? location : nil, changeTeacher ? teacher : nil); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(count == 0 || (!changeWeeks && !changeLocation && !changeTeacher))
                }
            }
        }
    }
}

struct ImportPeriodEditor: View {
    let period: Period
    let onSave: (Period) -> Void
    @State private var number = 1
    @State private var start = ""
    @State private var end = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Stepper("第 \(number) 节", value: $number, in: 1...40)
                TextField("开始时间 HH:mm", text: $start).keyboardType(.numbersAndPunctuation)
                TextField("结束时间 HH:mm", text: $end).keyboardType(.numbersAndPunctuation)
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("编辑作息").navigationBarTitleDisplayMode(.inline)
            .onAppear { number = period.number; start = Period.clock(period.startMinute); end = Period.clock(period.endMinute) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let start = ImportParser.minute(start), let end = ImportParser.minute(end), end > start else { error = "请填写正确的24小时制时间，结束应晚于开始。"; return }
                        onSave(Period(number: number, startMinute: start, endMinute: end)); dismiss()
                    }
                }
            }
        }
    }
}

struct ImportPeriodGenerator: View {
    let onGenerate: ([Period]) -> Void
    @State private var first = "08:00"
    @State private var duration = 45
    @State private var gap = 10
    @State private var count = 12
    @State private var lunchAfter = 4
    @State private var lunch = 120
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("生成规律") {
                    TextField("第一节开始 HH:mm", text: $first).keyboardType(.numbersAndPunctuation)
                    Stepper("每节 \(duration) 分钟", value: $duration, in: 20...120, step: 5)
                    Stepper("课间 \(gap) 分钟", value: $gap, in: 0...60, step: 5)
                    Stepper("一天 \(count) 节", value: $count, in: 1...24)
                    Stepper("第 \(lunchAfter) 节后长休息", value: $lunchAfter, in: 1...24)
                    Stepper("长休息 \(lunch) 分钟", value: $lunch, in: 0...240, step: 5)
                    Text("长休息替换该节后的普通课间。生成后可逐节改时间，适合学校午休与晚课。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let periods = generated {
                    Section("预览") {
                        ForEach(periods) { period in HStack { Text("第\(period.number)节"); Spacer(); Text("\(Period.clock(period.startMinute))–\(Period.clock(period.endMinute))").monospacedDigit() } }
                    }
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("快速设置作息").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成") {
                        guard let periods = generated else { error = "请检查开始时间，所有课程应在当天结束。"; return }
                        onGenerate(periods); dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { Text("生成将替换本次导入的作息草稿。默认时间只是起点，请以学校官方作息为准。").font(.caption).foregroundStyle(.secondary).padding().background(.regularMaterial) }
        }
    }
    private var generated: [Period]? {
        guard var cursor = ImportParser.minute(first) else { return nil }
        var result: [Period] = []
        for number in 1...count {
            guard cursor + duration < 1440 else { return nil }
            result.append(Period(number: number, startMinute: cursor, endMinute: cursor + duration))
            cursor += duration + (number == lunchAfter ? lunch : gap)
        }
        return result
    }
}

struct ImportCloudConfirmationView: View {
    let text: String
    let images: Int
    let onConfirm: () -> Void
    @State private var configuration = CloudImportConfiguration.load()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("这次会发送") {
                    LabeledContent("服务商", value: configuration.destination.isEmpty ? "尚未配置" : configuration.destination)
                    LabeledContent("模型", value: configuration.model.isEmpty ? "尚未配置" : configuration.model)
                    LabeledContent("识别文字", value: "\(text.count) 字")
                    LabeledContent("图片", value: configuration.includeImages ? "\(images) 张" : "不发送")
                    Text("课表可能包含姓名、教师、教室等信息。点击发送后，内容会交给你配置的服务商处理，并按该服务商的政策保留和计费。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink("检查或修改配置") { CloudSettingsView().onDisappear { configuration = .load() } }
                }
                Section("待发送文字预览") { Text(text.isEmpty ? "没有文字，将使用图片。" : text).font(.caption).textSelection(.enabled) }
                Section {
                    Button("确认并发送本次内容") { onConfirm(); dismiss() }.buttonStyle(.borderedProminent)
                        .disabled((try? configuration.endpoint()) == nil || ImportAPIKeychain.read(for: configuration)?.isEmpty != false || (text.isEmpty && (!configuration.includeImages || images == 0)))
                }
            }
            .navigationTitle("确认云端识别").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
