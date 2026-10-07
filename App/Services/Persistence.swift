import Foundation
import SwiftData
import CourseKit

/// One record per domain entity keeps unrelated device edits independent. Tombstones sync deletions.
@Model final class StoredRecord {
    var entityID: String = ""
    var kind: String = ""
    var payload: Data = Data()
    var modifiedAt: Date = Date()
    var isDeleted: Bool = false
    init(entityID: String, kind: String, payload: Data, modifiedAt: Date = .now, isDeleted: Bool = false) {
        self.entityID = entityID; self.kind = kind; self.payload = payload; self.modifiedAt = modifiedAt; self.isDeleted = isDeleted
    }
}

@MainActor final class Persistence {
    let container: ModelContainer
    let cloudEnabled: Bool
    init(inMemory: Bool = false) throws {
        cloudEnabled = !inMemory && !BuildFeatures.isTrial && (Bundle.main.object(forInfoDictionaryKey: "CloudSyncEnabled") as? String == "YES")
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: cloudEnabled ? .private("iCloud.com.courseflow.app") : .none)
        container = try ModelContainer(for: StoredRecord.self, configurations: config)
    }
    private var context: ModelContext { container.mainContext }
    func records() throws -> [StoredRecord] { try context.fetch(FetchDescriptor<StoredRecord>()) }
    func read() throws -> ScheduleSnapshot {
        let newest = Dictionary(grouping: try records(), by: \.entityID).compactMapValues { $0.max { $0.modifiedAt < $1.modifiedAt } }
        let decoder = JSONDecoder()
        func values<T: Decodable>(_ kind: String, _ type: T.Type) throws -> [T] {
            try newest.values.filter { $0.kind == kind && !$0.isDeleted }.sorted { $0.entityID < $1.entityID }.map { try decoder.decode(T.self, from: $0.payload) }
        }
        return try ScheduleSnapshot(semesters: values("semester", Semester.self), bellSchedules: values("bells", BellSchedule.self), courses: values("course", Course.self), rules: values("rule", MeetingRule.self), exceptions: values("exception", LessonException.self), dayOverrides: values("day", DayOverride.self), holidayDecisions: values("holidayDecision", HolidayDecision.self))
    }
    func write(_ snapshot: ScheduleSnapshot) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var incoming: [String: (String, Data)] = [:]
        func add<T: Encodable & Identifiable>(_ values: [T], kind: String) throws where T.ID == UUID {
            for value in values { incoming[value.id.uuidString] = (kind, try encoder.encode(value)) }
        }
        try add(snapshot.semesters, kind: "semester"); try add(snapshot.bellSchedules, kind: "bells")
        try add(snapshot.courses, kind: "course"); try add(snapshot.rules, kind: "rule")
        try add(snapshot.exceptions, kind: "exception"); try add(snapshot.dayOverrides, kind: "day"); try add(snapshot.holidayDecisions, kind: "holidayDecision")
        let existing = Dictionary(grouping: try records(), by: \.entityID).compactMapValues { $0.max { $0.modifiedAt < $1.modifiedAt } }
        for (id, entry) in incoming {
            if let record = existing[id] {
                if record.payload != entry.1 || record.isDeleted {
                    record.payload = entry.1; record.kind = entry.0; record.isDeleted = false; record.modifiedAt = .now
                }
            } else { context.insert(StoredRecord(entityID: id, kind: entry.0, payload: entry.1)) }
        }
        for (id, record) in existing where incoming[id] == nil && !record.isDeleted { record.isDeleted = true; record.modifiedAt = .now }
        do { try context.save() } catch { context.rollback(); throw error }
    }
}
