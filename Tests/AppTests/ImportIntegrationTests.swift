import XCTest
import UIKit
import PDFKit
import CourseKit
@testable import CourseFlow

@MainActor
final class ImportIntegrationTests: XCTestCase {
    func testVisionRecognizesActualChineseTimetableImage() async throws {
        let image = fixtureImage()
        let data = try XCTUnwrap(image.pngData())
        let service = ImportRecognitionService()
        let page = try await service.recognize(data)
        XCTAssertTrue(page.text.contains("高等数学"), page.text)
        let draft = await service.draft(from: page, kind: .timetable, sourceName: "测试图片", sourcePage: 1, maxWeeks: 20)
        let math = try XCTUnwrap(draft.lessons.first { $0.name.contains("高等数学") }, "Actual Vision text: \(page.text); draft: \(draft.lessons)")
        XCTAssertEqual(math.weekday, 1)
        XCTAssertEqual(math.periods, [1, 2])
        XCTAssertEqual(math.weeks, Array(1...8))
        XCTAssertTrue(math.location.contains("A301"))
        XCTAssertNil(math.startMinute, "Image has periods only; the importer must not invent clock times.")
    }

    func testPDFPageSelectionTextLayerAndImportedFields() async throws {
        let url = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 1600, height: 720))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            ("测试文件封面，不含课程" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 32)])
            context.beginPage()
            drawFixtureTable()
        }
        let reader = ImportFileReader()
        let pages = try await reader.pdfPages(at: url)
        XCTAssertEqual(pages.map(\.number), [1, 2])
        let (rendered, native) = try await reader.pdfImage(at: url, pageNumber: 2)
        XCTAssertTrue(native.text.contains("高等数学"), "PDFKit must read the native text layer before OCR")
        XCTAssertFalse(native.tables.isEmpty, "Native PDF list columns must retain their geometry. Text: \(native.text)")
        let nativeDraft = await ImportRecognitionService().draft(from: native, kind: .timetable, sourceName: "PDF", sourcePage: 2, maxWeeks: 20)
        XCTAssertTrue(nativeDraft.lessons.contains { $0.name == "高等数学" }, "Native text: \(native.text); tables: \(native.tables); lessons: \(nativeDraft.lessons)")
        let semester = Semester(firstMonday: Date(), weekCount: 20)
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        defer { ImportDraftStorage.clear(model.workspace) }
        try model.addImage(rendered, label: "PDF 第2页", embeddedText: native.text, embeddedTables: native.tables)
        model.recognizePending()
        await model.currentTask?.value
        XCTAssertNil(model.error)
        let math = try XCTUnwrap(model.workspace.draft.lessons.first { $0.name.contains("高等数学") }, "Native text: \(native.text); tables: \(native.tables); final lessons: \(model.workspace.draft.lessons)")
        XCTAssertEqual(math.weekday, 1)
        XCTAssertEqual(math.periods, [1, 2])
        XCTAssertEqual(math.weeks, Array(1...8))
    }

    func testScannedPDFHasNoTextLayerAndFallsBackToVision() async throws {
        let url = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = fixtureImage()
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 1600, height: 720)).writePDF(to: url) { context in
            context.beginPage(); image.draw(in: CGRect(x: 0, y: 0, width: 1600, height: 720))
        }
        let reader = ImportFileReader()
        let (rendered, native) = try await reader.pdfImage(at: url, pageNumber: 1)
        XCTAssertTrue(native.text.isEmpty)
        let service = ImportRecognitionService()
        let page = try await service.recognize(rendered)
        XCTAssertTrue(page.text.contains("大学英语"), page.text)
    }

    func testXLSXReaderPreservesMergedCellsAndMultipleWorksheets() async throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "merged-timetable", withExtension: "xlsx") ?? bundle.url(forResource: "merged-timetable", withExtension: "xlsx", subdirectory: "Fixtures"), "Include Tests/AppTests/Fixtures in CourseFlowTests resources.")
        let sheets = try await ImportFileReader().workbook(at: url)
        XCTAssertEqual(sheets.count, 2)
        let grid = try XCTUnwrap(sheets.first { $0.name == "周课表" })
        let merged = try XCTUnwrap(grid.cells.first { $0.text.contains("高等数学") })
        XCTAssertEqual(merged.rowSpan, 2)
        let draft = ImportParser.grid(grid.cells, maxWeeks: 20)
        let math = try XCTUnwrap(draft.lessons.first { $0.name == "高等数学" })
        XCTAssertEqual(math.periods, [1, 2])
        XCTAssertEqual(math.weekday, 1)
        XCTAssertEqual(math.weeks, Array(1...8))
        let list = try XCTUnwrap(sheets.first { $0.name == "课程清单" })
        let mapped = ImportParser.table(list.rows, maxWeeks: 20)
        XCTAssertEqual(mapped.lessons.first?.startMinute, 840)
        XCTAssertEqual(mapped.lessons.first?.endMinute, 960)
    }

    func testDraftRecoveryIsSeparatedByKindAndCropCleanupKeepsOnlyOriginalAndCurrent() throws {
        let semester = Semester(firstMonday: Date())
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        let data = try XCTUnwrap(fixtureImage().jpegData(compressionQuality: 0.8))
        try model.addImage(data, label: "原件")
        let id = try XCTUnwrap(model.workspace.assets.first?.id)
        let original = try XCTUnwrap(model.workspace.assets.first?.originalFile)
        model.updateImage(id, data: data)
        let middle = try XCTUnwrap(model.workspace.assets.first?.imageFile)
        model.updateImage(id, data: data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImportDraftStorage.file(middle).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ImportDraftStorage.file(original).path))
        model.append(ImportParser.text("高等数学 周一 第1-2节 1-8周"))
        let count = model.workspace.draft.lessons.count
        model.switchKind(.bellSchedule)
        model.append(ImportParser.text("第1节 08:00-08:45", kind: .bellSchedule))
        let bellWorkspace = model.workspace
        model.switchKind(.timetable)
        XCTAssertEqual(model.workspace.draft.lessons.count, count)
        XCTAssertEqual(model.workspace.assets.count, 1)
        let courseWorkspace = model.workspace
        defer { ImportDraftStorage.clear(courseWorkspace); ImportDraftStorage.clear(bellWorkspace) }
        let recovered = try XCTUnwrap(ImportDraftStorage.load(semesterID: semester.id, kind: .bellSchedule))
        XCTAssertEqual(recovered.draft.periods.first?.startMinute, 480)
    }

    func testCloudConfigurationRejectsInsecureOrCredentialBearingURLsWithoutNetwork() {
        XCTAssertThrowsError(try CloudImportConfiguration(baseURL: "http://example.com/v1", model: "example").endpoint())
        XCTAssertThrowsError(try CloudImportConfiguration(baseURL: "https://secret@example.com/v1", model: "example").endpoint())
        XCTAssertThrowsError(try CloudImportConfiguration(baseURL: "https://example.com/v1?api_key=secret", model: "example").endpoint())
        XCTAssertEqual(try CloudImportConfiguration(baseURL: "https://example.com/v1", model: "example").endpoint().absoluteString, "https://example.com/v1/chat/completions")
    }

    func testFailedCloudEnhancementPreservesEditedDraftWithoutSendingNetworkRequest() async throws {
        let semester = Semester(firstMonday: Date())
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        defer { ImportDraftStorage.clear(model.workspace) }
        model.append(ImportParser.text("高等数学 周一 第1-2节 1-8周 地点:已手动改过的A302"))
        let before = model.workspace.draft.lessons
        let source = model.workspace.draft.sourceText
        // A unique endpoint has no Keychain key, so the service fails before URLSession.
        let configuration = CloudImportConfiguration(baseURL: "https://example.invalid/\(UUID().uuidString)/v1", model: "test")
        model.enhanceInCloud(configuration: configuration)
        await model.currentTask?.value
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.workspace.draft.lessons, before)
        XCTAssertEqual(model.workspace.draft.sourceText, source)
        XCTAssertNil(model.previousDraft)
    }

    func testPartialCommitKeepsUnselectedDraftAndOnlyRequiredOriginals() throws {
        let semester = Semester(firstMonday: Date())
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        let data = try XCTUnwrap(fixtureImage().jpegData(compressionQuality: 0.7))
        try model.addImage(data, label: "已完成的来源")
        try model.addImage(data, label: "待补全的来源")
        try model.addImage(data, label: "尚未识别的来源")
        let firstFile = model.workspace.assets[0].originalFile
        let pendingFile = model.workspace.assets[1].originalFile
        let unprocessedFile = model.workspace.assets[2].originalFile
        model.workspace.assets[0].extractedText = "已完成的课程"
        model.workspace.assets[1].extractedText = "还缺周次的课程"
        let imported = DraftLesson(name: "已完成的课程", weekday: 1, weeks: [1], startMinute: 480, endMinute: 525, sourcePage: 1)
        let pending = DraftLesson(name: "还缺周次的课程", weekday: 2, sourcePage: 2, selected: false)
        model.workspace.draft.lessons = [imported, pending]
        model.save()
        XCTAssertTrue(model.commitCleanup())
        model.save() // onDisappear must not resurrect the already submitted items.
        let saved = try XCTUnwrap(ImportDraftStorage.load(semesterID: semester.id))
        XCTAssertEqual(saved.draft.lessons, [pending])
        XCTAssertEqual(saved.assets.map(\.pageNumber), [2, 3])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImportDraftStorage.file(firstFile).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ImportDraftStorage.file(pendingFile).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ImportDraftStorage.file(unprocessedFile).path))
        let resumed = ImportFlowModel(semester: semester, bellSchedules: [])
        XCTAssertTrue(resumed.restored)
        XCTAssertEqual(resumed.workspace.draft.lessons.first?.id, pending.id)
        resumed.workspace.draft.lessons[0].selected = true
        let unprocessed = try XCTUnwrap(resumed.workspace.assets.first { $0.extractedText.isEmpty })
        resumed.removeImage(unprocessed.id)
        XCTAssertTrue(resumed.commitCleanup())
        XCTAssertNil(ImportDraftStorage.load(semesterID: semester.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImportDraftStorage.file(pendingFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ImportDraftStorage.file(unprocessedFile).path))
    }

    func testDraftConflictPreviewUsesRealTeachingSegmentsAndWeekSelection() throws {
        let monday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T00:00:00+08:00"))
        let semester = Semester(firstMonday: monday, weekCount: 4)
        let bell = BellSchedule(semesterID: semester.id, effectiveFrom: monday, periods: [Period(number: 1, startMinute: 480, endMinute: 525), Period(number: 2, startMinute: 535, endMinute: 580)], isConfirmed: true)
        let model = ImportFlowModel(semester: semester, bellSchedules: [bell])
        defer { ImportDraftStorage.clear(model.workspace) }
        let math = DraftLesson(name: "数学", weekday: 1, weeks: [1, 2], periods: [1, 2])
        var other = DraftLesson(name: "另一张图片的课程", weekday: 1, weeks: [1, 2], startMinute: 525, endMinute: 535)
        model.workspace.draft.lessons = [math, other]
        XCTAssertTrue(model.conflictPreview.isEmpty, "A class during a break must not be reported as overlapping teaching.")
        other.startMinute = 520
        model.updateLesson(other)
        let conflict = try XCTUnwrap(model.conflictPreview.first)
        XCTAssertEqual(model.conflictPreview.count, 1)
        XCTAssertEqual(conflict.weeks, [1, 2])
        XCTAssertEqual(conflict.timeRanges, ["08:40–08:45"])
        let signature = model.conflictSignature
        other.weeks = [2]
        model.updateLesson(other)
        XCTAssertEqual(model.conflictPreview.first?.weeks, [2])
        XCTAssertNotEqual(model.conflictSignature, signature, "Editing the conflict invalidates the UI acknowledgement.")
        other.selected = false
        model.updateLesson(other)
        XCTAssertTrue(model.conflictPreview.isEmpty)
    }

    private func fixtureImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 720), format: format).image { _ in drawFixtureTable() }
    }
    private func drawFixtureTable() {
        UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 1600, height: 720))
        let x: [CGFloat] = [40, 430, 650, 910, 1130, 1560]
        let rows = [["课程名称", "星期", "周次", "节次", "上课地点"], ["高等数学", "星期一", "1-8周", "1-2节", "主楼 A301"], ["大学英语", "星期二", "1-16周", "3-4节", "东楼 B202"]]
        let context = UIGraphicsGetCurrentContext()!
        context.setStrokeColor(UIColor.black.cgColor); context.setLineWidth(2)
        for index in 0...rows.count {
            let y = CGFloat(index) * 180 + 70
            context.move(to: CGPoint(x: x[0], y: y)); context.addLine(to: CGPoint(x: x.last!, y: y))
        }
        for column in x { context.move(to: CGPoint(x: column, y: 70)); context.addLine(to: CGPoint(x: column, y: 610)) }
        context.strokePath()
        for (rowIndex, values) in rows.enumerated() {
            for (column, value) in values.enumerated() {
                (value as NSString).draw(in: CGRect(x: x[column] + 22, y: 130 + CGFloat(rowIndex) * 180, width: x[column + 1] - x[column] - 36, height: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
            }
        }
    }
    private func temporaryURL(extension value: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(value) }
}
