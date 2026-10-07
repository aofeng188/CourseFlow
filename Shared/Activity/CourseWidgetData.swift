import Foundation
import CourseKit

enum CourseAppGroup {
    static let identifier = "group.com.courseflow.app"
    static let snapshotName = "widget-snapshot.json"

    static var snapshotURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(snapshotName)
    }

    static func readSnapshot() -> WidgetSnapshot {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return WidgetSnapshot(semester: nil, occurrences: [])
        }
        return snapshot
    }
}
