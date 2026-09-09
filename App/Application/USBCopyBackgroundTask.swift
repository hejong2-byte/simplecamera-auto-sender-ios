import UIKit

/// A bounded UIKit grace period, not an unlimited background USB transfer.
@MainActor
final class USBCopyBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var previousIdleTimerDisabled: Bool?

    func begin(expiration: @escaping @MainActor () -> Void) {
        end()
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        identifier = UIApplication.shared.beginBackgroundTask(withName: "USB copy") { [weak self] in
            // UIKit delivers the expiration handler on the main thread. Persist
            // the interruption and request cancellation before ending its budget.
            MainActor.assumeIsolated {
                expiration()
                self?.end()
            }
        }
    }

    func end() {
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
    }
}
