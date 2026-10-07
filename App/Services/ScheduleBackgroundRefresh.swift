import Foundation
@preconcurrency import BackgroundTasks

/// Opportunistic replenishment only; notification coverage must never depend on a timely launch.
enum ScheduleBackgroundRefresh {
    static let identifier = "com.courseflow.app.refresh"

    /// Register from application launch, before launch finishes.
    @discardableResult
    static func register(handler: @escaping @Sendable () async -> Bool) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let operation = Task {
                try? schedule()
                let success = await handler()
                task.setTaskCompleted(success: success && !Task.isCancelled)
            }
            task.expirationHandler = { operation.cancel() }
        }
    }

    /// iOS chooses the actual execution time and may decline the request.
    static func schedule() throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 60 * 60)
        try BGTaskScheduler.shared.submit(request)
    }
}
