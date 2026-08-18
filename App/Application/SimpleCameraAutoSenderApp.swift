import SwiftUI

enum AppIdentity {
    static let bundleIdentifier = "com.hejong2byte.simplecameraautosender"
}

@main
struct SimpleCameraAutoSenderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Text("SimpleCamera 업무사진 전송")
        }
    }
}
