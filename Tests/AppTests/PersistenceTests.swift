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

    @MainActor func testUnreadableRecordIsSkippedButNeverDeleted() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        XCTAssertTrue(store.apply("初始资料") { $0 = SampleData.make(now: .now) })
        let context = persistence.container.mainContext
        let broken = StoredRecord(entityID: UUID().uuidString, kind: "course", payload: Data("{\"future\":true}".utf8))
        let future = StoredRecord(entityID: UUID().uuidString, kind: "exam", payload: Data("{}".utf8))
        context.insert(broken); context.insert(future); try context.save()

        let snapshot = try persistence.read()
        XCTAssertEqual(snapshot, store.snapshot, "无法解码的记录不应阻止读取其余课表")
        XCTAssertEqual(persistence.unreadableRecordCount, 2)
        XCTAssertTrue(store.apply("本机编辑") { $0.semesters[0].name = "继续可编辑" })
        let records = try persistence.records()
        XCTAssertFalse(try XCTUnwrap(records.first { $0.entityID == broken.entityID }).isDeleted, "保存时不能把读不出的记录当作删除")
        XCTAssertFalse(try XCTUnwrap(records.first { $0.entityID == future.entityID }).isDeleted, "新版本的记录类型必须原样保留")
        store.reload()
        XCTAssertNotNil(store.errorMessage, "应提示有记录暂时无法读取")
    }

    @MainActor func testOrphanedChildWaitsForParentInsteadOfBlockingEdits() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        let data = SampleData.make(now: .now)
        XCTAssertTrue(store.apply("初始资料") { $0 = data })
        // Models a sync that delivered a rule before its course.
        let lateCourse = Course(semesterID: data.semesters[0].id, name: "尚未同步到达的课程")
        let rule = MeetingRule(courseID: lateCourse.id, weekday: 3, weeks: [1, 2], periodNumbers: [1, 2])
        let context = persistence.container.mainContext
        context.insert(StoredRecord(entityID: rule.id.uuidString, kind: "rule", payload: try JSONEncoder().encode(rule)))
        try context.save()

        XCTAssertFalse(try persistence.read().rules.contains { $0.id == rule.id })
        XCTAssertEqual(persistence.unreadableRecordCount, 0, "暂缺父记录不是解码错误，不应提示用户")
        XCTAssertTrue(store.apply("本机编辑") { $0.semesters[0].name = "同步中仍可编辑" })
        XCTAssertFalse(try XCTUnwrap(try persistence.records().first { $0.entityID == rule.id.uuidString }).isDeleted)

        context.insert(StoredRecord(entityID: lateCourse.id.uuidString, kind: "course", payload: try JSONEncoder().encode(lateCourse)))
        try context.save()
        XCTAssertTrue(try persistence.read().rules.contains { $0.id == rule.id }, "父记录到达后子记录应恢复显示")
    }

    @MainActor func testOldTombstonesArePurgedWithTheirDuplicates() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        XCTAssertTrue(store.apply("初始资料") { $0 = SampleData.make(now: .now) })
        let context = persistence.container.mainContext
        let old = Date.now.addingTimeInterval(-Persistence.tombstoneRetention - 86400)
        let staleID = UUID().uuidString, recentID = UUID().uuidString
        context.insert(StoredRecord(entityID: staleID, kind: "course", payload: Data(), modifiedAt: old.addingTimeInterval(-60)))
        context.insert(StoredRecord(entityID: staleID, kind: "course", payload: Data(), modifiedAt: old, isDeleted: true))
        context.insert(StoredRecord(entityID: recentID, kind: "course", payload: Data(), modifiedAt: .now, isDeleted: true))
        try context.save()

        XCTAssertTrue(store.apply("本机编辑") { $0.semesters[0].name = "触发保存" })
        let ids = try persistence.records().map(\.entityID)
        XCTAssertFalse(ids.contains(staleID), "过期删除标记及其旧副本都应清理，避免旧副本复活")
        XCTAssertTrue(ids.contains(recentID), "近期删除标记需保留以同步到其他设备")
    }

    @MainActor func testUndoStepsBackThroughSeveralEdits() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        XCTAssertTrue(store.apply("初始资料") { $0 = SampleData.make(now: .now) })
        XCTAssertTrue(store.apply("第一次改名") { $0.semesters[0].name = "A" })
        XCTAssertTrue(store.apply("第二次改名") { $0.semesters[0].name = "B" })
        XCTAssertEqual(store.undoLabel, "第二次改名")
        store.undo()
        XCTAssertEqual(try persistence.read().semesters[0].name, "A")
        XCTAssertEqual(store.undoLabel, "第一次改名")
        store.undo()
        XCTAssertEqual(try persistence.read().semesters[0].name, SampleData.make(now: .now).semesters[0].name)
        XCTAssertEqual(store.undoLabel, "初始资料")
        store.undo()
        XCTAssertTrue(try persistence.read().semesters.isEmpty)
        XCTAssertFalse(store.canUndo)
    }

    @MainActor func testReloadRebuildsSystemContentOnlyWhenNeeded() throws {
        let persistence = try Persistence(inMemory: true)
        let store = try AppStore(persistence: persistence, systemIntegrationsEnabled: false)
        XCTAssertTrue(store.apply("初始资料") { $0 = SampleData.make(now: .now) })
        let revision = store.revision
        store.reload()
        XCTAssertEqual(store.revision, revision, "资料未变化时，保存后的回读不应再次重建提醒和小组件")
        store.reload(forceRefresh: true)
        XCTAssertEqual(store.revision, revision + 1, "回到前台时需要重新核对提醒队列")
        var remote = try persistence.read()
        remote.semesters[0].name = "其他设备改名"
        try persistence.write(remote)
        store.reload()
        XCTAssertEqual(store.revision, revision + 2)
        XCTAssertEqual(store.snapshot.semesters[0].name, "其他设备改名")
    }
}
