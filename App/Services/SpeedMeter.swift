import CoreLocation
import Observation

/// Speed over ground for the dashboard's speedometer, from live location updates while it runs.
/// Fixes stay in memory on the device: only this run's current speed, top speed and distance are
/// kept, and nothing is saved or sent when it stops.
@MainActor @Observable final class SpeedMeter {
    enum State: Equatable {
        case off
        /// Waiting for permission or a first fix that carries a speed.
        case locating
        case measuring
        /// Location access is off for the app, or for the whole device.
        case denied
        /// Precise Location is off, so fixes carry no speed.
        case approximate
        /// No fix right now, such as indoors; updates resume on their own.
        case unavailable
    }
    private(set) var state = State.off
    /// km/h, nil before the first usable fix.
    private(set) var speed: Double?
    /// km/h, the highest speed since this run started.
    private(set) var topSpeed = 0.0
    /// Meters travelled since this run started.
    private(set) var distance = 0.0
    private var task: Task<Void, Never>?
    @ObservationIgnored private var session: CLServiceSession?
    @ObservationIgnored private var lastFix: CLLocation?
    var isOn: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        speed = nil; topSpeed = 0; distance = 0; lastFix = nil
        state = .locating
        // Holding a session asks for When In Use access the first time, and keeps it while measuring.
        session = CLServiceSession(authorization: .whenInUse)
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                    guard let self, !Task.isCancelled else { return }
                    self.receive(update)
                }
            } catch {
                if !Task.isCancelled { self?.state = .unavailable }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        session?.invalidate(); session = nil
        speed = nil; lastFix = nil
        state = .off
    }

    private func receive(_ update: CLLocationUpdate) {
        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
            state = .denied; speed = nil; return
        }
        if update.accuracyLimited { state = .approximate; speed = nil; return }
        // Updates pause while the phone stays put, so show standing still rather than the last speed.
        if update.stationary { speed = 0; state = .measuring; return }
        guard let fix = update.location else {
            if update.locationUnavailable { state = .unavailable; speed = nil }
            return
        }
        guard fix.speed >= 0 else { if speed == nil { state = .locating }; return }
        // GPS reports a little speed while standing still; below a slow walk counts as stopped.
        let kmh = fix.speed < 0.3 ? 0 : fix.speed * 3.6
        speed = kmh
        topSpeed = max(topSpeed, kmh)
        state = .measuring
        // Only confident fixes count toward distance, and only while moving, so drift while waiting adds nothing.
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 25 else { return }
        if let lastFix, kmh > 0 { distance += fix.distance(from: lastFix) }
        lastFix = fix
    }
}
