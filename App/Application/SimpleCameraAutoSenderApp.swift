import SwiftUI

enum AppIdentity {
    static let bundleIdentifier = "com.hejong2byte.simplecameraautosender"
}

@main
struct SimpleCameraAutoSenderApp: App {
    @UIApplicationDelegateAdaptor(BackgroundSessionAppDelegate.self) private var appDelegate

    #if targetEnvironment(simulator)
    init() {
        LiveStateCorruptionSimulation.seedIfRequested()
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(simulator)
            if let simulation = ForegroundReceiveSimulation.current {
                ContentView(
                    model: simulation.content,
                    receiverModel: simulation.receiver,
                    incomingModel: simulation.incoming,
                    filePickerModel: simulation.filePicker,
                    textModel: simulation.text
                )
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
            incomingModel: USBReceiverDependencies.shared.makeIncomingFilesViewModel(),
            filePickerModel: KakaoFilePickerModel(store: AppDependencies.shared.kakaoFolderStore),
            textModel: TextTransferDependencies.shared.makeViewModel()
        )
    }
}
