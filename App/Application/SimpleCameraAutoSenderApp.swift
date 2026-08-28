import SwiftUI

enum AppIdentity {
    static let bundleIdentifier = "com.hejong2byte.simplecameraautosender"
}

@main
struct SimpleCameraAutoSenderApp: App {
    @UIApplicationDelegateAdaptor(BackgroundSessionAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if let simulation = ForegroundReceiveSimulation.current {
                ContentView(model: simulation.content, receiverModel: simulation.receiver, incomingModel: simulation.incoming)
            } else {
                liveContent
            }
            #else
            liveContent
            #endif
        }
    }

    private var liveContent: some View {
        ContentView(
            model: AppDependencies.shared.makeContentViewModel(),
            receiverModel: USBReceiverDependencies.shared.makeViewModel(),
            incomingModel: USBReceiverDependencies.shared.makeIncomingFilesViewModel()
        )
    }
}
