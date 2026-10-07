import XCTest
import CourseKit
@testable import CourseFlow

@MainActor
final class AIImportIntegrationTests: XCTestCase {
    private let validJSON = #"{"format":"courseflow.ai","version":1,"kind":"timetable","sourceName":"测试","lessons":[{"name":"AI导入验收课","weekday":7,"weeks":"1-8","periods":null,"start":"21:00","end":"21:45","location":"测试楼Z909","teacher":"AI测试教师","source":"原文","warnings":[]}],"periods":[],"warnings":[]}"#

    func testInvalidAIInputPreservesEditedDraftAndPersistsPastedContent() async throws {
        let semester = try makeSemester()
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        defer { ImportDraftStorage.clear(model.workspace) }
        let edited = DraftLesson(name: "已经手动核对", weekday: 2, weeks: [2, 4], startMinute: 480, endMinute: 525, location: "已改教室 A302", teacher: "已改教师", sourceText: "旧原文", warnings: ["待确认备注"])
        model.append(ImportDraft(sourceName: "已有来源", sourceText: "旧原文", lessons: [edited], warnings: ["保留已有提示"]))
        let before = model.workspace.draft
        let sources = model.workspace.textSources
        let invalidInputs = [String(validJSON.dropLast()), validJSON.replacingOccurrences(of: "courseflow.ai", with: "unrecognized.format")]

        for input in invalidInputs {
            do {
                try await model.importAIText(input)
                XCTFail("Invalid AI data must fail before changing any reviewed row.")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            XCTAssertEqual(model.workspace.draft.id, before.id)
            XCTAssertEqual(model.workspace.draft.lessons, before.lessons)
            XCTAssertEqual(model.workspace.draft.periods, before.periods)
            XCTAssertEqual(model.workspace.draft.sourceName, before.sourceName)
            XCTAssertEqual(model.workspace.draft.sourceText, before.sourceText)
            XCTAssertEqual(model.workspace.draft.warnings, before.warnings)
            XCTAssertEqual(model.workspace.textSources, sources)
            XCTAssertEqual(model.workspace.aiPasteText, input)
            let saved = try XCTUnwrap(ImportDraftStorage.load(semesterID: semester.id))
            XCTAssertEqual(saved.aiPasteText, input, "Failed input must survive closing the importer.")
            XCTAssertEqual(saved.draft.lessons, before.lessons)
        }
    }

    func testSuccessfulAIImportAppendsOnlyToDraftAndClearsSavedPaste() async throws {
        let semester = try makeSemester()
        let persistence = try Persistence(inMemory: true)
        let formal = ScheduleSnapshot(semesters: [semester])
        try persistence.write(formal)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        defer { ImportDraftStorage.clear(model.workspace) }
        let pending = DraftLesson(name: "尚未补全的旧草稿", location: "手动地点", selected: false)
        model.append(ImportDraft(lessons: [pending]))

        try await model.importAIText(validJSON)

        XCTAssertEqual(model.workspace.draft.lessons.count, 2)
        XCTAssertEqual(model.workspace.draft.lessons.first, pending)
        let lesson = try XCTUnwrap(model.workspace.draft.lessons.last)
        XCTAssertEqual(lesson.name, "AI导入验收课")
        XCTAssertEqual(lesson.weekday, 7)
        XCTAssertEqual(lesson.weeks, Array(1...8))
        XCTAssertTrue(lesson.periods.isEmpty)
        XCTAssertEqual(lesson.startMinute, 1260)
        XCTAssertEqual(lesson.endMinute, 1305)
        XCTAssertEqual(lesson.location, "测试楼Z909")
        XCTAssertEqual(lesson.teacher, "AI测试教师")
        XCTAssertTrue(lesson.sourceText.contains("原文"))
        XCTAssertTrue(model.blockingIssues.isEmpty)
        XCTAssertNil(model.workspace.aiPasteText)
        let saved = try XCTUnwrap(ImportDraftStorage.load(semesterID: semester.id))
        XCTAssertNil(saved.aiPasteText)
        XCTAssertEqual(saved.draft.lessons, model.workspace.draft.lessons)
        XCTAssertEqual(try persistence.read(), formal, "Parsing must not commit a formal course.")
        XCTAssertEqual(store.snapshot, formal)
        await store.waitForRefresh()
        XCTAssertTrue(store.occurrences.isEmpty)
    }

    func testUnfinishedAIPasteAndEditedDraftRecoverTogether() throws {
        let semester = try makeSemester()
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        defer { ImportDraftStorage.clear(model.workspace) }
        model.workspace.draft.lessons = [DraftLesson(name: "已编辑但未确认", location: "手动教室")]
        model.workspace.aiPasteText = String(validJSON.prefix(115))
        model.save()

        let recovered = ImportFlowModel(semester: semester, bellSchedules: [])
        XCTAssertTrue(recovered.restored)
        XCTAssertEqual(recovered.workspace.draft.id, model.workspace.draft.id)
        XCTAssertEqual(recovered.workspace.draft.lessons, model.workspace.draft.lessons)
        XCTAssertEqual(recovered.workspace.aiPasteText, model.workspace.aiPasteText)
    }

    func testLegacyWorkspaceWithoutAIPasteFieldStillRecovers() throws {
        let semester = try makeSemester()
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        defer { ImportDraftStorage.clear(model.workspace) }
        model.workspace.draft.lessons = [DraftLesson(name: "升级前保留的课程", weeks: [1, 3])]
        model.save()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model.workspace)) as? [String: Any])
        legacy.removeValue(forKey: "aiPasteText")
        let file = ImportDraftStorage.file("draft-\(semester.id.uuidString)-timetable.json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: file, options: .atomic)

        let recovered = ImportFlowModel(semester: semester, bellSchedules: [])
        XCTAssertTrue(recovered.restored)
        XCTAssertNil(recovered.workspace.aiPasteText)
        XCTAssertEqual(recovered.workspace.draft.lessons, model.workspace.draft.lessons)
        XCTAssertEqual(recovered.workspace.draft.id, model.workspace.draft.id)
    }

    func testTimetableAIDataCannotOverwriteBellScheduleDraft() async throws {
        let semester = try makeSemester()
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        let timetableWorkspace = model.workspace
        model.switchKind(.bellSchedule)
        defer { ImportDraftStorage.clear(timetableWorkspace); ImportDraftStorage.clear(model.workspace) }
        model.append(ImportDraft(kind: .bellSchedule, sourceText: "手动核对的作息", periods: [Period(number: 1, startMinute: 485, endMinute: 530)]))
        let before = model.workspace.draft

        do {
            try await model.importAIText(validJSON)
            XCTFail("Timetable output must be rejected by a bell-schedule importer.")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(model.workspace.draft.kind, .bellSchedule)
        XCTAssertEqual(model.workspace.draft.periods, before.periods)
        XCTAssertEqual(model.workspace.draft.lessons, before.lessons)
        XCTAssertEqual(model.workspace.draft.sourceText, before.sourceText)
        let saved = try XCTUnwrap(ImportDraftStorage.load(semesterID: semester.id, kind: .bellSchedule))
        XCTAssertEqual(saved.aiPasteText, validJSON)
        XCTAssertEqual(saved.draft.periods, before.periods)
    }

    func testReviewedAIImportCommitsWithoutDuplicatesOnRetry() async throws {
        let semester = try makeSemester()
        let persistence = try Persistence(inMemory: true)
        try persistence.write(ScheduleSnapshot(semesters: [semester]))
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        store.selectedSemesterID = semester.id
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        defer { ImportDraftStorage.clear(model.workspace) }
        try await model.importAIText(validJSON)
        var reviewed = try XCTUnwrap(model.workspace.draft.lessons.first)
        reviewed.name = "已核对 AI 课程"
        reviewed.location = "更正后的教室 Z910"
        model.updateLesson(reviewed)
        XCTAssertTrue(model.blockingIssues.isEmpty)

        XCTAssertTrue(store.commitImport(model.workspace.draft, replaceDuplicates: false))
        await store.waitForRefresh()
        let saved = try persistence.read()
        XCTAssertEqual(saved.courses.count, 1)
        XCTAssertEqual(saved.courses.first?.name, reviewed.name)
        let rule = try XCTUnwrap(saved.rules.first)
        XCTAssertEqual(saved.rules.count, 1)
        XCTAssertEqual(rule.weeks, Array(1...8))
        XCTAssertEqual(rule.weekday, 7)
        XCTAssertEqual(rule.startMinute, 1260)
        XCTAssertEqual(rule.endMinute, 1305)
        XCTAssertEqual(rule.location, reviewed.location)
        XCTAssertEqual(rule.teacher, "AI测试教师")
        XCTAssertEqual(store.occurrences.count, 8)
        XCTAssertTrue(store.commitImport(model.workspace.draft, replaceDuplicates: false))
        XCTAssertEqual(try persistence.read(), saved, "Retrying confirmation must not add duplicate rules or courses.")
        XCTAssertTrue(model.commitCleanup())
        model.save()
        XCTAssertNil(ImportDraftStorage.load(semesterID: semester.id), "Leaving the importer must not resurrect a committed draft.")
    }

    func testCommittingReviewedRowsKeepsUnprocessedAIPasteForLater() async throws {
        let semester = try makeSemester()
        let model = ImportFlowModel(semester: semester, bellSchedules: [])
        defer { ImportDraftStorage.clear(model.workspace) }
        try await model.importAIText(validJSON)
        let unfinished = String(validJSON.prefix(120))
        model.workspace.aiPasteText = unfinished
        model.save()

        XCTAssertTrue(model.commitCleanup())
        model.save()
        let saved = try XCTUnwrap(ImportDraftStorage.load(semesterID: semester.id))
        XCTAssertTrue(saved.draft.lessons.isEmpty, "Already submitted rows must be removed from the remaining workspace.")
        XCTAssertEqual(saved.aiPasteText, unfinished)
        let recovered = ImportFlowModel(semester: semester, bellSchedules: [])
        XCTAssertTrue(recovered.restored)
        XCTAssertTrue(recovered.hasContent)
        XCTAssertEqual(recovered.workspace.aiPasteText, unfinished)
    }

    private func makeSemester() throws -> Semester {
        let monday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T00:00:00+08:00"))
        return Semester(firstMonday: monday, weekCount: 8)
    }
}
