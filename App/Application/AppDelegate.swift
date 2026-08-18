import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == AppConfiguration.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundUploadCoordinator.shared.handleEvents(
            completionHandler: completionHandler
        )
    }
}
