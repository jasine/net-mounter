import Foundation

/// Completion is thread-safe and idempotent, just like the mount callback guards.
final class DiagnosticMeasurement {
    private let lock = NSLock()
    private var completed = false
    private let completion: (Error?) -> Void

    init(completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func finish(error: Error? = nil) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        completion(error)
    }
}
