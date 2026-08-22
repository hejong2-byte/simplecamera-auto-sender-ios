import SwiftUI

enum AppIdentity {
    static let bundleIdentifier = "com.hejong2byte.simplecameraautosender"
}

@main
struct SimpleCameraAutoSenderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(model: AppDependencies.shared.makeContentViewModel())
        }
    }
}
