import ActivityKit
import Foundation

struct CourseActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable { case inClass, onBreak }
        var courseName: String
        var location: String
        var start: Date
        var end: Date
        var colorIndex: Int
        var phase: Phase
        var phaseStart: Date
        var phaseEnd: Date
    }
    var occurrenceID: String
    var courseID: String
    var scheduledStart: Date
}
