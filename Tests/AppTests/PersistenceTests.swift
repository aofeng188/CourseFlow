import XCTest
import CourseKit
@testable import CourseFlow

final class PersistenceTests: XCTestCase {
    @MainActor func testAtomicSaveUndoAndReadback() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        let data = SampleData.make(now: .now)
        XCTAssertTrue(store.apply("测试导入") { $0 = data })
        let saved = try persistence.read()
        XCTAssertEqual(Set(saved.courses.map(\.id)), Set(data.courses.map(\.id)))
        let id = try XCTUnwrap(saved.courses.first?.id)
        XCTAssertTrue(store.apply("更名") { snapshot in
            let index = snapshot.courses.firstIndex { $0.id == id }!
            snapshot.courses[index].name = "持久化验证课程"
        })
        XCTAssertEqual(try persistence.read().courses.first { $0.id == id }?.name, "持久化验证课程")
        store.undo()
        XCTAssertEqual(try persistence.read().courses.first { $0.id == id }?.name, data.courses.first { $0.id == id }?.name)
        XCTAssertFalse(store.apply("无效数据") { $0.rules[0].weeks = [999] })
        XCTAssertEqual(try persistence.read().rules, store.snapshot.rules)
    }

    @MainActor func testRemoteRecordsAreNotDeletedByStaleEditor() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        let data = SampleData.make(now: .now)
        XCTAssertTrue(store.apply("初始资料") { $0 = data })
        var remote = try persistence.read()
        let course = Course(semesterID: data.semesters[0].id, name: "另一台设备添加的课程")
        remote.courses.append(course)
        try persistence.write(remote)
        XCTAssertTrue(store.apply("本机编辑") { $0.semesters[0].name = "同步学期" })
        XCTAssertTrue(try persistence.read().courses.contains { $0.id == course.id })
    }

    @MainActor func testInvalidImportDoesNotPartiallyCommit() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        store.loadExample()
        let before = store.snapshot
        let invalid = ImportDraft(lessons: [DraftLesson(name: "缺少时间", weekday: 1, weeks: [1])])
        XCTAssertFalse(store.commitImport(invalid, replaceDuplicates: false))
        XCTAssertEqual(store.snapshot, before)
    }

    @MainActor func testUndoDoesNotOverwriteNewlySyncedRecords() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        XCTAssertTrue(store.apply("初始资料") { $0 = SampleData.make(now: .now) })
        XCTAssertTrue(store.apply("本机编辑") { $0.semesters[0].name = "本机学期" })
        var remote = try persistence.read()
        let remoteCourse = Course(semesterID: remote.semesters[0].id, name: "同步到达的课程")
        remote.courses.append(remoteCourse)
        try persistence.write(remote)
        store.undo()
        XCTAssertTrue(try persistence.read().courses.contains { $0.id == remoteCourse.id })
        XCTAssertEqual(store.snapshot.semesters[0].name, "本机学期")
        XCTAssertFalse(store.canUndo)
        XCTAssertNotNil(store.errorMessage)
    }
}
