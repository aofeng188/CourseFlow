import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import VisionKit
import CourseKit

private enum ImportSheetRoute: Identifiable {
    case paste, aiText, scanner, pdf, table, cloudSettings, cloudConfirm, batch, generator
    case lesson(UUID), source(UUID), crop(UUID), period(Int)
    var id: String {
        switch self {
        case .paste: "paste"; case .aiText: "aiText"; case .scanner: "scanner"; case .pdf: "pdf"; case .table: "table"
        case .cloudSettings: "cloudSettings"; case .cloudConfirm: "cloudConfirm"; case .batch: "batch"; case .generator: "generator"
        case .lesson(let id): "lesson-\(id)"; case .source(let id): "source-\(id)"; case .crop(let id): "crop-\(id)"; case .period(let number): "period-\(number)"
        }
    }
}

struct ImportFlowView: View {
    let semester: Semester?
    let bellSchedules: [BellSchedule]
    let onCommit: (ImportDraft, Bool) -> Bool
    @State private var model: ImportFlowModel
    @State private var selection: [PhotosPickerItem] = []
    @State private var route: ImportSheetRoute?
    @State private var filePicker = false
    @State private var discardConfirmation = false
    @State private var replaceDuplicates = false
    @State private var acknowledgedConflictSignature: String?
    @Environment(\.dismiss) private var dismiss

    init(semester: Semester?, bellSchedules: [BellSchedule], onCommit: @escaping (ImportDraft, Bool) -> Bool) {
        self.semester = semester; self.bellSchedules = bellSchedules; self.onCommit = onCommit
        _model = State(initialValue: ImportFlowModel(semester: semester, bellSchedules: bellSchedules))
    }
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                intro
                if semester == nil { Section { Label("请先在设置中创建学期，再确认导入。", systemImage: "calendar.badge.exclamationmark").foregroundStyle(.orange) } }
                if model.restored { Section { Label("已恢复上次未完成的导入，你可以接着核对。", systemImage: "arrow.counterclockwise").font(.footnote) } }
                sourceActions
                if !model.workspace.assets.isEmpty { imageSources }
                if !model.workspace.draft.sourceText.isEmpty || !model.workspace.assets.isEmpty { intelligenceActions }
                if model.workspace.draft.kind == .timetable {
                    lessonReview
                    if !model.conflictPreview.isEmpty { conflictReview }
                } else { bellReview }
                if !model.workspace.draft.warnings.isEmpty {
                    Section("识别说明") { ForEach(Array(Set(model.workspace.draft.warnings)).sorted(), id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) } }
                }
                if model.hasContent { confirmation }
            }
            .navigationTitle("导入课表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.cancel(); model.save(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("云端识别设置", systemImage: "cloud") { route = .cloudSettings }
                        Button("清空本次导入", systemImage: "trash", role: .destructive) { discardConfirmation = true }
                    } label: { Image(systemName: "ellipsis") }
                    .disabled(model.isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.isBusy {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(model.progress.isEmpty ? "处理中…" : model.progress).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        Button("取消") { model.cancel() }
                    }
                    .padding().background(.regularMaterial)
                }
            }
            .sheet(item: $route, content: sheet)
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.image, .pdf, .commaSeparatedText, .tabSeparatedText, .plainText, UTType(filenameExtension: "xlsx") ?? .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { model.prepareFile(url, onPDF: { route = .pdf }, onTable: { route = .table }) }
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .alert("导入提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
            .confirmationDialog("清空草稿和本次保存的原图？", isPresented: $discardConfirmation, titleVisibility: .visible) {
                Button("清空本次导入", role: .destructive) { model.reset() }
            }
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                model.start {
                    for (index, item) in items.enumerated() {
                        try Task.checkCancellation()
                        model.progress = "读取图片 \(index + 1)/\(items.count)"
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw ImportServiceError.message("无法从照片图库读取图片，请下载原图后重试。") }
                        try model.addImage(data, label: "图片 \(model.workspace.assets.count + 1)")
                    }
                    selection = []
                }
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .onDisappear { model.save() }
    }

    private var intro: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("把你的课表，变成每天的从容", systemImage: "viewfinder").font(.headline)
                Text("照片、PDF 或表格都可以。先识别，再对照原件核对，最后确认。草稿会自动保存在这台设备上。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("导入内容", selection: Binding(get: { model.workspace.draft.kind }, set: { model.switchKind($0) })) {
                    Text("课程表").tag(ImportKind.timetable)
                    Text("学校作息表").tag(ImportKind.bellSchedule)
                }.pickerStyle(.segmented).disabled(model.isBusy)
            }.padding(.vertical, 4)
        }
    }
    private var sourceActions: some View {
        Section("选择来源") {
            Button { route = .aiText } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI 文本导入")
                        Text("复制提示词，让其他 AI 看图，再粘贴结果").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "sparkles") }
            }.accessibilityIdentifier("import-ai")
            PhotosPicker(selection: $selection, maxSelectionCount: 12, matching: .images) { Label("照片与截图", systemImage: "photo.on.rectangle") }
            Button { route = .scanner } label: { Label("扫描纸质课表", systemImage: "doc.viewfinder") }.disabled(!VNDocumentCameraViewController.isSupported)
            Button { filePicker = true } label: { Label("文件 · PDF / Excel / CSV", systemImage: "doc.badge.plus") }
            Button { route = .paste } label: { Label("粘贴文字", systemImage: "doc.on.clipboard") }.accessibilityIdentifier("import-paste")
            if model.workspace.draft.kind == .timetable {
                Button { route = .lesson(UUID()) } label: { Label("手动添加课程", systemImage: "plus.circle") }
            } else {
                Button { route = .generator } label: { Label("快速生成每节时间", systemImage: "clock.badge") }
            }
        }.disabled(model.isBusy || semester == nil)
    }
    private var imageSources: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(model.workspace.assets) { asset in
                        VStack(spacing: 8) {
                            Button { route = .source(asset.id) } label: {
                                if let image = UIImage(contentsOfFile: ImportDraftStorage.file(asset.imageFile).path) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 100, height: 126).clipped().clipShape(.rect(cornerRadius: 14))
                                } else { Image(systemName: "doc.questionmark").frame(width: 100, height: 126) }
                            }.accessibilityLabel("查看\(asset.label)原件")
                            Text(asset.label).font(.caption).lineLimit(1).frame(width: 100)
                            Menu {
                                Button("裁剪与旋转", systemImage: "crop.rotate") { route = .crop(asset.id) }
                                Button("删除图片及识别课程", systemImage: "trash", role: .destructive) { model.removeImage(asset.id) }
                            } label: { Label(asset.extractedText.isEmpty ? "待识别" : "已识别", systemImage: asset.extractedText.isEmpty ? "ellipsis.circle" : "checkmark.circle").font(.caption) }
                        }
                    }
                }.padding(.vertical, 6)
            }.scrollIndicators(.hidden)
            if model.pendingImages > 0 {
                Button { model.recognizePending() } label: { Label("识别 \(model.pendingImages) 张待处理图片", systemImage: "text.viewfinder").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
            }
        } header: { Text("原件 · 点开对照，菜单可裁剪") }
    }
    private var intelligenceActions: some View {
        Section {
            Menu {
                Button("使用本机 Apple Intelligence", systemImage: "apple.intelligence") { model.enhanceLocally() }
                Button("使用自配云端模型…", systemImage: "cloud") { route = .cloudConfirm }
            } label: { Label("智能整理识别结果", systemImage: "sparkles") }
            if model.previousDraft != nil { Button("撤销上次智能整理", systemImage: "arrow.uturn.backward") { model.undoEnhancement() } }
            Text("智能整理会重新生成待核对条目。已有手动修改可用“撤销”恢复；云端上传前会再次显示发送内容。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.isBusy)
    }
    private var lessonReview: some View {
        Section {
            ForEach(model.workspace.draft.lessons) { lesson in
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        var updated = lesson; updated.selected.toggle(); model.updateLesson(updated)
                    } label: { Image(systemName: lesson.selected ? "checkmark.circle.fill" : "circle").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(lesson.selected ? Color.accentColor : .secondary).accessibilityLabel(lesson.selected ? "取消选择\(lesson.name)" : "选择\(lesson.name)")
                    Button { route = .lesson(lesson.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(lesson.name.isEmpty ? "未命名课程" : lesson.name).font(.headline).foregroundStyle(.primary)
                            Text(summary(lesson)).font(.caption).foregroundStyle(.secondary)
                            if !lesson.location.isEmpty { Label(lesson.location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary) }
                            if !model.issues(lesson).isEmpty { Label("还有 \(model.issues(lesson).count) 项待补全", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Menu {
                        Button("编辑", systemImage: "pencil") { route = .lesson(lesson.id) }
                        Button("复制后拆分", systemImage: "doc.on.doc") { model.copyLesson(lesson) }
                        Button("删除", systemImage: "trash", role: .destructive) { model.workspace.draft.lessons.removeAll { $0.id == lesson.id }; model.save() }
                    } label: { Image(systemName: "ellipsis").padding(6) }
                }.padding(.vertical, 3)
            }
            if !model.workspace.draft.lessons.isEmpty {
                Button("批量修改选中课程", systemImage: "slider.horizontal.3") { route = .batch }
            }
        } header: { Text("待核对课程 · \(model.selectedLessons.count) 条已选") }
        footer: { if !model.workspace.draft.lessons.isEmpty { Text("不同星期、不同周次或地点的一门课可拆成多条。只会导入勾选的条目。") } }
        .disabled(model.isBusy)
    }
    private var bellReview: some View {
        Section {
            TextField("作息表名称", text: Binding(get: { model.workspace.draft.sourceName }, set: { model.workspace.draft.sourceName = $0; model.save() }))
            ForEach(Array(model.workspace.draft.periods.enumerated()), id: \.offset) { index, period in
                Button { route = .period(index) } label: {
                    HStack { Text("第 \(period.number) 节"); Spacer(); Text("\(Period.clock(period.startMinute))–\(Period.clock(period.endMinute))").monospacedDigit().foregroundStyle(.secondary) }
                }.swipeActions { Button("删除", role: .destructive) { model.workspace.draft.periods.remove(at: index); model.save() } }
            }
            Button("添加一节", systemImage: "plus") { route = .period(-1) }
            Button("按规律生成时间", systemImage: "clock.arrow.2.circlepath") { route = .generator }
        } header: { Text("核对每节时间") }
        footer: { Text("确认后作为学校作息保存，从学期首日生效。夏令、冬令作息的生效日期可以在作息设置中调整。") }
        .disabled(model.isBusy)
    }
    private var confirmation: some View {
        Section {
            if model.workspace.draft.kind == .timetable {
                Picker("遇到已匹配的课程", selection: $replaceDuplicates) {
                    Text("跳过已有课程").tag(false)
                    Text("更新已有课程资料").tag(true)
                }
                Text("新课程会正常添加。更新选项会将识别后的资料用于匹配的已有课程；请确认周次和时间无误。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.blockingIssues.isEmpty {
                DisclosureGroup("需要核对 \(model.blockingIssues.count) 项") {
                    ForEach(model.blockingIssues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
            }
            if !model.conflictPreview.isEmpty {
                Toggle("我已核对上述重叠安排，仍要导入", isOn: Binding(get: { acknowledgedConflictSignature == model.conflictSignature }, set: { acknowledgedConflictSignature = $0 ? model.conflictSignature : nil }))
                    .font(.subheadline)
            }
            let remainingCount = model.workspace.draft.lessons.filter { !$0.selected }.count
            if model.workspace.draft.kind == .timetable && (remainingCount > 0 || model.pendingImages > 0) {
                Text("本次导入 \(model.selectedLessons.count) 条；未选择的 \(remainingCount) 条课程与 \(model.pendingImages) 张待识别图片会保留在草稿中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                var draft = model.workspace.draft
                draft.lessons = draft.lessons.filter(\.selected)
                if onCommit(draft, replaceDuplicates) {
                    if model.commitCleanup() { dismiss() }
                } else { model.error = "保存未完成，草稿和原件已保留。请处理提示的问题后重试。" }
            } label: {
                Label(model.workspace.draft.kind == .timetable ? "核对完成，确认导入" : "确认学校作息", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .accessibilityIdentifier("import-confirm")
            .disabled(!model.blockingIssues.isEmpty || model.isBusy || (!model.conflictPreview.isEmpty && acknowledgedConflictSignature != model.conflictSignature))
        } footer: { Text("确认前不会写入正式课表、日历或提醒。你可以随时关闭，稍后继续。") }
    }
    private var conflictReview: some View {
        Section {
            ForEach(model.conflictPreview) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(conflict.firstName) 与 \(conflict.secondName)", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                    Text("星期\(["一", "二", "三", "四", "五", "六", "日"][conflict.weekday - 1]) · \(WeekSelection.summary(conflict.weeks))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("重叠：" + conflict.timeRanges.joined(separator: "、")).font(.caption.monospacedDigit())
                    HStack {
                        Button("修改\(conflict.firstName)") { route = .lesson(conflict.firstLessonID) }
                        Button("修改\(conflict.secondName)") { route = .lesson(conflict.secondLessonID) }
                    }.font(.caption).buttonStyle(.bordered)
                }.padding(.vertical, 4)
            }
        } header: { Text("本次资料中的时间冲突") }
        footer: { Text("只比较本次勾选课程的实际授课时段，课间休息不算冲突。请核对多张图片中是否重复或错位；需要保留重叠时，在下方明确确认。") }
        .disabled(model.isBusy)
    }
    private func summary(_ lesson: DraftLesson) -> String {
        let day = lesson.weekday.map { "周" + ["一", "二", "三", "四", "五", "六", "日"][max(0, min(6, $0 - 1))] } ?? "星期待定"
        let time = !lesson.periods.isEmpty ? "第\(lesson.periods.map(String.init).joined(separator: ","))节" : lesson.startMinute.map { "\(Period.clock($0))–\(Period.clock(lesson.endMinute ?? $0))" } ?? "时间待定"
        return [day, time, lesson.weeks.isEmpty ? "周次待定" : WeekSelection.summary(lesson.weeks)].joined(separator: " · ")
    }

    @ViewBuilder private func sheet(_ route: ImportSheetRoute) -> some View {
        switch route {
        case .paste:
            ImportPasteView(kind: model.workspace.draft.kind) { text in model.append(ImportParser.text(text, kind: model.workspace.draft.kind, maxWeeks: model.maxWeeks)) }
        case .aiText:
            AIImportView(model: model)
        case .scanner:
            ImportDocumentScanner { result in
                self.route = nil
                do { for (index, data) in try result.get().enumerated() { try model.addImage(data, label: "扫描 \(index + 1)") } }
                catch { model.error = error.localizedDescription }
            }.ignoresSafeArea()
        case .pdf:
            ImportPDFSelectionView(pages: model.pdfPages) { model.addPDFPages($0) }.onDisappear { model.releasePendingPDF() }
        case .table:
            ImportTableSelectionView(sheets: model.sheets, kind: model.workspace.draft.kind, maxWeeks: model.maxWeeks) { model.append($0) }
        case .lesson(let id):
            ImportLessonEditor(lesson: model.workspace.draft.lessons.first(where: { $0.id == id }) ?? DraftLesson(id: id), maxWeeks: model.maxWeeks, issues: [], assets: model.workspace.assets, onSave: model.updateLesson)
        case .source(let id):
            if let source = model.workspace.assets.first(where: { $0.id == id }) { ImportSourcePreview(asset: source) }
        case .crop(let id):
            if let source = model.workspace.assets.first(where: { $0.id == id }), let image = UIImage(contentsOfFile: ImportDraftStorage.file(source.imageFile).path) {
                ImportCropView(image: image) { model.updateImage(id, data: $0) }
            }
        case .period(let index):
            ImportPeriodEditor(period: model.workspace.draft.periods.indices.contains(index) ? model.workspace.draft.periods[index] : Period(number: (model.workspace.draft.periods.map(\.number).max() ?? 0) + 1, startMinute: 480, endMinute: 525)) { value in
                if model.workspace.draft.periods.indices.contains(index) { model.workspace.draft.periods[index] = value }
                else { model.workspace.draft.periods.append(value) }
                model.save()
            }
        case .generator:
            ImportPeriodGenerator { periods in model.workspace.draft.periods = periods; model.save() }
        case .batch:
            ImportBatchEditor(count: model.selectedLessons.count, maxWeeks: model.maxWeeks) { weeks, location, teacher in
                for index in model.workspace.draft.lessons.indices where model.workspace.draft.lessons[index].selected {
                    if let weeks { model.workspace.draft.lessons[index].weeks = weeks }
                    if let location { model.workspace.draft.lessons[index].location = location }
                    if let teacher { model.workspace.draft.lessons[index].teacher = teacher }
                }
                model.save()
            }
        case .cloudSettings:
            NavigationStack { CloudSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { self.route = nil } } } }
        case .cloudConfirm:
            ImportCloudConfirmationView(text: model.workspace.draft.sourceText, images: model.workspace.assets.count) { model.enhanceInCloud() }
        }
    }
}
