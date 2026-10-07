import Foundation
import WidgetKit
import CourseKit

enum WidgetBridge {
    static func write(_ snapshot: WidgetSnapshot) throws {
        guard let url = CourseAppGroup.snapshotURL else { throw WidgetBridgeError.missingAppGroup }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        WidgetCenter.shared.reloadAllTimelines()
    }

    enum WidgetBridgeError: LocalizedError {
        case missingAppGroup
        var errorDescription: String? { "尚未配置共享课表空间，小组件暂时无法读取课表。" }
    }
}
