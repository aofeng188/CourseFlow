import Foundation
import SwiftUI
import Observation
import CourseKit

struct ImportConflictPreview: Identifiable, Equatable {
    var firstLessonID: UUID
    var secondLessonID: UUID
    var firstName: String
    var secondName: String
    var weekday: Int
    var weeks: [Int]
    var timeRanges: [String]
    var id: String {
        [firstLessonID.uuidString, secondLessonID.uuidString, firstName, secondName, weeks.map(String.init).joined(separator: ","), timeRanges.joined(separator: ",")].joined(separator: "|")
    }
}

@MainActor @Observable
final class ImportFlowModel {
    var workspace: ImportWorkspace
    var isBusy = false
    var progress = ""
    var error: String?
    var restored = false
    var pdfURL: URL?
    var pdfPages: [ImportPDFPage] = []
    var sheets: [ImportSheet] = []
    var currentTask: Task<Void, Never>?
    var previousDraft: ImportDraft?
    private var didCommit = false
    let semester: Semester?
    let bells: [BellSchedule]
    private let recognizer = ImportRecognitionService()
    private let reader = ImportFileReader()
    @ObservationIgnored private var cachedConflictLessons: [DraftLesson] = []
    @ObservationIgnored private var cachedConflicts: [ImportConflictPreview] = []

    init(semester: Semester?, bellSchedules: [BellSchedule]) {
        self.semester = semester; bells = bellSchedules
        if let saved = ImportDraftStorage.load(semesterID: semester?.id) {
            workspace = saved; restored = true
        } else { workspace = ImportWorkspace(semesterID: semester?.id, draft: ImportDraft()) }
    }
    var maxWeeks: Int { semester?.weekCount ?? 20 }
    var hasContent: Bool { !workspace.draft.lessons.isEmpty || !workspace.draft.periods.isEmpty || !workspace.assets.isEmpty || !workspace.draft.sourceText.isEmpty || !(workspace.aiPasteText ?? "").isEmpty }
    var pendingImages: Int { workspace.assets.filter { $0.extractedText.isEmpty }.count }
    var selectedLessons: [DraftLesson] { workspace.draft.lessons.filter(\.selected) }
    var conflictPreview: [ImportConflictPreview] {
        guard workspace.draft.kind == .timetable, let semester else { return [] }
        let lessons = selectedLessons
        if lessons == cachedConflictLessons { return cachedConflicts }
        cachedConflictLessons = lessons
        let valid = lessons.filter { issues($0).isEmpty }
        let courses = valid.map { Course(id: $0.id, semesterID: semester.id, name: $0.name) }
        let rules = valid.map { MeetingRule(id: $0.id, courseID: $0.id, weekday: $0.weekday!, weeks: $0.weeks, periodNumbers: $0.periods, startMinute: $0.startMinute, endMinute: $0.endMinute, location: $0.location, teacher: $0.teacher) }
        let snapshot = ScheduleSnapshot(semesters: [semester], bellSchedules: bells, courses: courses, rules: rules)
        let occurrences = ScheduleEngine.occurrences(snapshot: snapshot, semesterID: semester.id)
        let byID = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.id, $0) })
        var groups: [String: ImportConflictPreview] = [:]
        for conflict in ScheduleEngine.conflicts(in: occurrences) {
            guard let first = byID[conflict.firstID], let second = byID[conflict.secondID] else { continue }
            let pair = [first, second].sorted { $0.ruleID.uuidString < $1.ruleID.uuidString }
            let key = pair.map { $0.ruleID.uuidString }.joined(separator: "|")
            let startParts = semester.calendar.dateComponents([.hour, .minute], from: conflict.overlapStart)
            let endParts = semester.calendar.dateComponents([.hour, .minute], from: conflict.overlapEnd)
            let start = (startParts.hour ?? 0) * 60 + (startParts.minute ?? 0)
            let end = (endParts.hour ?? 0) * 60 + (endParts.minute ?? 0)
            let time = "\(Period.clock(start))–\(Period.clock(end))"
            if var group = groups[key] {
                group.weeks = Array(Set(group.weeks + [first.week])).sorted()
                group.timeRanges = Array(Set(group.timeRanges + [time])).sorted()
                groups[key] = group
            } else {
                let weekday = (semester.calendar.component(.weekday, from: conflict.overlapStart) + 5) % 7 + 1
                groups[key] = ImportConflictPreview(firstLessonID: pair[0].ruleID, secondLessonID: pair[1].ruleID, firstName: pair[0].courseName, secondName: pair[1].courseName, weekday: weekday, weeks: [first.week], timeRanges: [time])
            }
        }
        cachedConflicts = groups.values.sorted { $0.id < $1.id }
        return cachedConflicts
    }
    var conflictSignature: String { conflictPreview.map(\.id).joined(separator: "\n") }
    func issues(_ lesson: DraftLesson) -> [String] {
        guard let semester else { return ["请先创建学期"] }
        return DraftValidator.issues(for: lesson, semester: semester, bellSchedules: bells)
    }
    var blockingIssues: [String] {
        if semester == nil { return ["请先创建学期"] }
        if workspace.draft.kind == .timetable {
            if selectedLessons.isEmpty { return ["至少选择一条课程"] }
            let errors = selectedLessons.flatMap { lesson in issues(lesson).map { "\(lesson.name.isEmpty ? "未命名课程" : lesson.name)：\($0)" } }
            return Array(Set(errors)).sorted()
        }
        let periods = workspace.draft.periods
        if periods.isEmpty { return ["至少添加一节作息时间"] }
        var issues: [String] = []
        if Set(periods.map(\.number)).count != periods.count { issues.append("节次编号重复，请修正后再确认") }
        if periods.contains(where: { !(1...40).contains($0.number) || !(0..<1440).contains($0.startMinute) || !(1...1440).contains($0.endMinute) || $0.endMinute <= $0.startMinute }) { issues.append("每节的结束时间必须晚于开始时间，编号应在1至40之间") }
        let sorted = periods.sorted { $0.startMinute < $1.startMinute }
        if zip(sorted, sorted.dropFirst()).contains(where: { $0.endMinute > $1.startMinute }) { issues.append("作息时间有重叠，请核对") }
        return issues
    }
    func save() {
        guard !didCommit else { return }
        do { try ImportDraftStorage.save(workspace) }
        catch { self.error = "无法保存导入草稿：\(error.localizedDescription)" }
    }
    func start(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; error = nil
        currentTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.currentTask = nil; self.progress = ""; self.save() }
            do { try await operation() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { currentTask?.cancel() }
    func reset() {
        cancel(); ImportDraftStorage.clear(workspace)
        workspace = ImportWorkspace(semesterID: semester?.id, draft: ImportDraft(kind: workspace.draft.kind))
        previousDraft = nil; restored = false; save()
    }
    func switchKind(_ kind: ImportKind) {
        save()
        if let saved = ImportDraftStorage.load(semesterID: semester?.id, kind: kind) { workspace = saved; restored = true }
        else { workspace = ImportWorkspace(semesterID: semester?.id, draft: ImportDraft(kind: kind)); restored = false }
        previousDraft = nil
    }
    /// The callback has committed only selected lessons. Preserve the unselected
    /// draft and any images that still need recognition before deleting sources.
    @discardableResult func commitCleanup() -> Bool {
        guard workspace.draft.kind == .timetable else {
            didCommit = true; ImportDraftStorage.clear(workspace); return true
        }
        let remaining = workspace.draft.lessons.filter { !$0.selected }
        let hasUnprocessedImages = workspace.assets.contains { $0.extractedText.isEmpty }
        let hasUnprocessedAI = !(workspace.aiPasteText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !remaining.isEmpty || hasUnprocessedImages || hasUnprocessedAI else {
            didCommit = true; ImportDraftStorage.clear(workspace); return true
        }
        var pending = workspace
        pending.draft.lessons = remaining
        let sourcePages = Set(remaining.compactMap(\.sourcePage))
        let hasUnknownSource = remaining.contains { $0.sourcePage == nil }
        pending.assets = workspace.assets.filter { hasUnknownSource || sourcePages.contains($0.pageNumber) || $0.extractedText.isEmpty }
        if !hasUnknownSource { pending.textSources = [] }
        pending.draft.sourceText = (pending.textSources + pending.assets.filter { !$0.extractedText.isEmpty }.map { "[\($0.label)]\n\($0.extractedText)" }).joined(separator: "\n\n")
        pending.draft.warnings = ["已提交勾选的课程。未选择的 \(remaining.count) 条课程、未处理的原件和 AI 粘贴内容已保留，可以稍后继续。"]
        do {
            try ImportDraftStorage.save(pending)
        } catch {
            self.error = "课程已保存，但待处理草稿暂时无法更新。原有草稿和原件仍保留，请稍后重试。"
            return false
        }
        let retained = Set(pending.assets.flatMap { [$0.originalFile, $0.imageFile] })
        for name in Set(workspace.assets.flatMap { [$0.originalFile, $0.imageFile] }).subtracting(retained) {
            try? FileManager.default.removeItem(at: ImportDraftStorage.file(name))
        }
        workspace = pending; previousDraft = nil; didCommit = true
        return true
    }
    func append(_ result: ImportDraft, recordSource: Bool = true) {
        if workspace.draft.sourceName.isEmpty { workspace.draft.sourceName = result.sourceName }
        if recordSource && !result.sourceText.isEmpty { workspace.textSources.append(result.sourceText) }
        workspace.draft.lessons += result.lessons
        workspace.draft.periods += result.periods
        workspace.draft.warnings += result.warnings
        rebuildSourceText()
        save()
    }
    /// External AI output is data only. Parsing never touches the formal store,
    /// notifications or calendar, and failure leaves all edited rows untouched.
    func importAIText(_ text: String) async throws {
        workspace.aiPasteText = text
        save()
        let kind = workspace.draft.kind
        let weeks = maxWeeks
        let parser = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try AIImportFormat.parse(text, kind: kind, maxWeeks: weeks)
        }
        let draft = try await withTaskCancellationHandler {
            try await parser.value
        } onCancel: {
            parser.cancel()
        }
        try Task.checkCancellation()
        workspace.aiPasteText = nil
        append(draft)
    }
    func addImage(_ data: Data, label: String, embeddedText: String = "", embeddedTables: [[ImportTableCell]] = []) throws {
        guard let image = UIImage(data: data), let normalized = image.importNormalized().jpegData(compressionQuality: 0.92) else { throw ImportServiceError.message("这张图片无法读取，请换一张图片。") }
        let name = try ImportDraftStorage.saveImage(normalized)
        workspace.assets.append(ImportSourceAsset(label: label, imageFile: name, originalFile: name, embeddedText: embeddedText, embeddedTables: embeddedTables, pageNumber: (workspace.assets.map(\.pageNumber).max() ?? 0) + 1))
        save()
    }
    func updateImage(_ id: UUID, data: Data) {
        do {
            guard let index = workspace.assets.firstIndex(where: { $0.id == id }) else { return }
            let oldImage = workspace.assets[index].imageFile
            workspace.assets[index].imageFile = try ImportDraftStorage.saveImage(data)
            if oldImage != workspace.assets[index].originalFile { try? FileManager.default.removeItem(at: ImportDraftStorage.file(oldImage)) }
            workspace.assets[index].extractedText = ""
            workspace.assets[index].embeddedText = ""; workspace.assets[index].embeddedTables = []
            let previousPeriods = workspace.assets[index].recognizedPeriods
            workspace.draft.periods.removeAll { previousPeriods.contains($0) }
            workspace.assets[index].recognizedPeriods = []
            let page = workspace.assets[index].pageNumber
            workspace.draft.lessons.removeAll { $0.sourcePage == page }
            rebuildSourceText()
            save()
        } catch { self.error = error.localizedDescription }
    }
    func removeImage(_ id: UUID) {
        guard let asset = workspace.assets.first(where: { $0.id == id }) else { return }
        workspace.assets.removeAll { $0.id == id }
        workspace.draft.lessons.removeAll { $0.sourcePage == asset.pageNumber }
        workspace.draft.periods.removeAll { asset.recognizedPeriods.contains($0) }
        rebuildSourceText()
        try? FileManager.default.removeItem(at: ImportDraftStorage.file(asset.imageFile))
        try? FileManager.default.removeItem(at: ImportDraftStorage.file(asset.originalFile))
        save()
    }
    func recognizePending() {
        start { [self] in
            let pending = workspace.assets.filter { $0.extractedText.isEmpty }
            for (offset, asset) in pending.enumerated() {
                try Task.checkCancellation()
                progress = "正在识别 \(offset + 1)/\(pending.count)：\(asset.label)"
                let data = try Data(contentsOf: ImportDraftStorage.file(asset.imageFile))
                let recognized: RecognizedImportPage
                let native = RecognizedImportPage(text: asset.embeddedText, tables: asset.embeddedTables, warning: "已优先读取 PDF 原生文字，请核对表格对应关系。")
                let nativeDraft = await recognizer.draft(from: native, kind: workspace.draft.kind, sourceName: asset.label, sourcePage: asset.pageNumber, maxWeeks: maxWeeks)
                let usableNative = workspace.draft.kind == .bellSchedule ? !nativeDraft.periods.isEmpty : !nativeDraft.lessons.isEmpty && nativeDraft.lessons.allSatisfy { $0.weekday != nil && (!$0.periods.isEmpty || $0.startMinute != nil) && !$0.name.isEmpty && $0.name.first?.isNumber != true && ImportParser.guessedMapping([$0.name]).first != .name }
                if !asset.embeddedText.isEmpty && usableNative { recognized = native }
                else {
                    do { recognized = try await recognizer.recognize(data) }
                    catch {
                        if !asset.embeddedText.isEmpty { recognized = native }
                        else { throw error }
                    }
                }
                try Task.checkCancellation()
                let result = await recognizer.draft(from: recognized, kind: workspace.draft.kind, sourceName: asset.label, sourcePage: asset.pageNumber, maxWeeks: maxWeeks)
                if let index = workspace.assets.firstIndex(where: { $0.id == asset.id }) { workspace.assets[index].extractedText = recognized.text; workspace.assets[index].recognizedPeriods = result.periods }
                append(result, recordSource: false)
            }
        }
    }
    func prepareFile(_ url: URL, onPDF: @escaping () -> Void, onTable: @escaping () -> Void) {
        start { [self] in
            progress = "正在读取文件"
            let copy = try ImportDraftStorage.copyInput(url)
            switch url.pathExtension.lowercased() {
            case "pdf":
                do { pdfPages = try await reader.pdfPages(at: copy); pdfURL = copy; onPDF() }
                catch { try? FileManager.default.removeItem(at: copy); throw error }
            case "xlsx":
                defer { try? FileManager.default.removeItem(at: copy) }
                sheets = try await reader.workbook(at: copy); onTable()
            case "csv", "tsv", "txt":
                defer { try? FileManager.default.removeItem(at: copy) }
                let text = try await reader.readText(at: copy)
                if url.pathExtension.lowercased() == "txt" { append(ImportParser.text(text, kind: workspace.draft.kind, sourceName: url.lastPathComponent, maxWeeks: maxWeeks)) }
                else {
                    let rows = ImportParser.delimitedRows(text, delimiter: url.pathExtension.lowercased() == "tsv" ? "\t" : nil)
                    let cells = rows.enumerated().flatMap { row, values in values.enumerated().map { ImportTableCell(text: $0.element, row: row, column: $0.offset) } }
                    sheets = [ImportSheet(id: UUID().uuidString, name: url.lastPathComponent, rows: rows, cells: cells)]; onTable()
                }
            case "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff":
                defer { try? FileManager.default.removeItem(at: copy) }
                try addImage(Data(contentsOf: copy), label: url.lastPathComponent)
            default:
                try? FileManager.default.removeItem(at: copy)
                throw ImportServiceError.message("支持图片、PDF、CSV、TSV、TXT 和 XLSX。旧版 XLS 请另存为 XLSX。")
            }
        }
    }
    func addPDFPages(_ selected: Set<Int>) {
        guard let url = pdfURL else { return }
        pdfURL = nil
        start { [self] in
            defer { try? FileManager.default.removeItem(at: url); pdfURL = nil; pdfPages = [] }
            for number in selected.sorted() {
                try Task.checkCancellation()
                progress = "正在读取 PDF 第 \(number) 页"
                let (data, native) = try await reader.pdfImage(at: url, pageNumber: number)
                try addImage(data, label: "PDF 第 \(number) 页", embeddedText: native.text, embeddedTables: native.tables)
            }
        }
    }
    func releasePendingPDF() {
        guard let url = pdfURL else { return }
        try? FileManager.default.removeItem(at: url); pdfURL = nil; pdfPages = []
    }
    func updateLesson(_ lesson: DraftLesson) {
        if let index = workspace.draft.lessons.firstIndex(where: { $0.id == lesson.id }) { workspace.draft.lessons[index] = lesson }
        else { workspace.draft.lessons.append(lesson) }
        save()
    }
    func copyLesson(_ lesson: DraftLesson) {
        var copy = lesson; copy.id = UUID(); copy.warnings = ["已复制，请修改星期、节次或周次"]
        workspace.draft.lessons.append(copy); save()
    }
    func enhanceLocally() {
        start { [self] in
            progress = "正在用本机模型重新整理"
            let source = workspace.draft.sourceText
            let images = workspace.assets.map { ImportDraftStorage.file($0.imageFile) }
            let result = try await OnDeviceImportEnhancer().enhance(text: source, imageURLs: images, kind: workspace.draft.kind, maxWeeks: maxWeeks)
            try Task.checkCancellation()
            guard workspace.draft.kind == .timetable ? !result.lessons.isEmpty : !result.periods.isEmpty else { throw ImportServiceError.message("本机模型未提取到数据，原有草稿已保留。") }
            replaceWithEnhanced(result)
        }
    }
    func enhanceInCloud(configuration: CloudImportConfiguration? = nil) {
        let configuration = configuration ?? CloudImportConfiguration.load()
        start { [self] in
            progress = "正在等待 \(configuration.destination) 返回结果"
            let images = configuration.includeImages ? try workspace.assets.map { try Data(contentsOf: ImportDraftStorage.file($0.imageFile)) } : []
            let result = try await CloudImportService().enhance(text: workspace.draft.sourceText, images: images, configuration: configuration, kind: workspace.draft.kind, maxWeeks: maxWeeks)
            try Task.checkCancellation()
            replaceWithEnhanced(result)
        }
    }
    private func replaceWithEnhanced(_ result: ImportDraft) {
        previousDraft = workspace.draft
        let sourceName = workspace.draft.sourceName
        workspace.draft = result; workspace.draft.sourceName = sourceName
        save()
    }
    private func rebuildSourceText() {
        workspace.draft.sourceText = (workspace.textSources + workspace.assets.filter { !$0.extractedText.isEmpty }.map { "[\($0.label)]\n\($0.extractedText)" }).joined(separator: "\n\n")
    }
    func undoEnhancement() {
        guard let previousDraft else { return }
        workspace.draft = previousDraft; self.previousDraft = nil; save()
    }
}
