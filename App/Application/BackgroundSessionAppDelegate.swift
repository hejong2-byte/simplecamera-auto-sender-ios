import UIKit

final class BackgroundSessionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == AppConfiguration.manualBackgroundSessionIdentifier
                || identifier == AppConfiguration.receiverBackgroundSessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundSessionCompletionRegistry.shared.store(
            identifier: identifier,
            handler: completionHandler
        )
        if identifier == AppConfiguration.manualBackgroundSessionIdentifier {
            Task {
                await AppDependencies.shared.manualTransferEngine.restore()
            }
        } else {
            _ = BackgroundIPhoneReceiveSession.shared
        }
    }
}
