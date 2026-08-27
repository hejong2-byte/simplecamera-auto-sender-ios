import SwiftUI

enum AppIdentity {
    static let bundleIdentifier = "com.hejong2byte.simplecameraautosender"
}

@main
struct SimpleCameraAutoSenderApp: App {
    @UIApplicationDelegateAdaptor(BackgroundSessionAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: AppDependencies.shared.makeContentViewModel(),
                receiverModel: USBReceiverDependencies.shared.makeViewModel()
            )
        }
    }
}
