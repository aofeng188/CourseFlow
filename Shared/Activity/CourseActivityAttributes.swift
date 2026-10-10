import ActivityKit
import Foundation

struct CourseActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable { case inClass, onBreak }
        struct Segment: Codable, Hashable, Sendable { var start: Date; var end: Date }
        var courseName: String
        var location: String
        var start: Date
        var end: Date
        var colorIndex: Int
        var phase: Phase
        var phaseStart: Date
        var phaseEnd: Date
        /// Every teaching segment of the lesson, for a bar that spans back-to-back periods.
        /// Optional so content written by an older app version still decodes.
        var segments: [Segment]?
    }
    var occurrenceID: String
    var courseID: String
    var scheduledStart: Date
}
