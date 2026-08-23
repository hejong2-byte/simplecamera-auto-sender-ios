import UIKit

final class BackgroundSessionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == AppConfiguration.manualBackgroundSessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundSessionCompletionRegistry.shared.store(completionHandler)
        Task {
            await AppDependencies.shared.manualTransferEngine.restore()
        }
    }
}
