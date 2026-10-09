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
    /// Records that could not be decoded in the latest read, e.g. written by a newer app version.
    private(set) var unreadableRecordCount = 0
    /// Stored entities left out of the latest snapshot: undecodable records and children whose
    /// parent is missing (often a sync still in flight). `write` must never tombstone them.
    private var withheldEntityIDs: Set<String> = []
    /// Long enough for every device to have received a deletion before its tombstone is purged.
    static let tombstoneRetention: TimeInterval = 180 * 86400
    private static let knownKinds: Set<String> = ["semester", "bells", "course", "rule", "exception", "day", "holidayDecision"]
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
        var unreadable = Set<String>()
        func values<T: Decodable>(_ kind: String, _ type: T.Type) -> [T] {
            newest.values.filter { $0.kind == kind && !$0.isDeleted }.sorted { $0.entityID < $1.entityID }.compactMap { record in
                do { return try decoder.decode(T.self, from: record.payload) }
                catch { unreadable.insert(record.entityID); return nil }
            }
        }
        var snapshot = ScheduleSnapshot(semesters: values("semester", Semester.self), bellSchedules: values("bells", BellSchedule.self), courses: values("course", Course.self), rules: values("rule", MeetingRule.self), exceptions: values("exception", LessonException.self), dayOverrides: values("day", DayOverride.self), holidayDecisions: values("holidayDecision", HolidayDecision.self))
        // A kind this version does not know comes from a newer app; keep it intact.
        for record in newest.values where !record.isDeleted && !Self.knownKinds.contains(record.kind) { unreadable.insert(record.entityID) }
        let orphans = Self.removeOrphans(from: &snapshot)
        unreadableRecordCount = unreadable.count
        withheldEntityIDs = unreadable.union(orphans)
        return snapshot
    }
    /// Drops children whose parent is absent so one missing record cannot fail validation of every edit.
    private static func removeOrphans(from snapshot: inout ScheduleSnapshot) -> Set<String> {
        var removed = Set<String>()
        func keep<T: Identifiable>(_ values: inout [T], where isValid: (T) -> Bool) where T.ID == UUID {
            values.removeAll { value in
                guard !isValid(value) else { return false }
                removed.insert(value.id.uuidString); return true
            }
        }
        let semesterIDs = Set(snapshot.semesters.map(\.id))
        keep(&snapshot.bellSchedules) { semesterIDs.contains($0.semesterID) }
        keep(&snapshot.courses) { semesterIDs.contains($0.semesterID) }
        keep(&snapshot.dayOverrides) { semesterIDs.contains($0.semesterID) }
        keep(&snapshot.holidayDecisions) { semesterIDs.contains($0.semesterID) }
        let courseIDs = Set(snapshot.courses.map(\.id))
        keep(&snapshot.rules) { courseIDs.contains($0.courseID) }
        let ruleIDs = Set(snapshot.rules.map(\.id))
        keep(&snapshot.exceptions) { ruleIDs.contains($0.ruleID) }
        return removed
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
        let grouped = Dictionary(grouping: try records(), by: \.entityID)
        let existing = grouped.compactMapValues { $0.max { $0.modifiedAt < $1.modifiedAt } }
        for (id, entry) in incoming {
            if let record = existing[id] {
                if record.payload != entry.1 || record.isDeleted {
                    record.payload = entry.1; record.kind = entry.0; record.isDeleted = false; record.modifiedAt = .now
                }
            } else { context.insert(StoredRecord(entityID: id, kind: entry.0, payload: entry.1)) }
        }
        for (id, record) in existing where incoming[id] == nil && !record.isDeleted && !withheldEntityIDs.contains(id) { record.isDeleted = true; record.modifiedAt = .now }
        // Purge an entity only when its newest record is an old tombstone; deleting just that
        // record could otherwise resurrect an older duplicate.
        let cutoff = Date.now.addingTimeInterval(-Self.tombstoneRetention)
        for (id, record) in existing where record.isDeleted && record.modifiedAt < cutoff && incoming[id] == nil {
            for duplicate in grouped[id] ?? [] { context.delete(duplicate) }
        }
        do { try context.save() } catch { context.rollback(); throw error }
    }
}
