import SwiftUI

enum AppIdentity {
    static let bundleIdentifier = "com.hejong2byte.photolibraryautosender"
}

@main
struct SimpleCameraAutoSenderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: AppDependencies.shared.makeContentViewModel())
        }
    }
}
