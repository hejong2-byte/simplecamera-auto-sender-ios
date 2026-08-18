import AppIntents

struct SimpleCameraAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendNewSimpleCameraPhotosIntent(),
            phrases: [
                "\(.applicationName) 새 사진 전송"
            ],
            shortTitle: "새 사진 전송",
            systemImageName: "paperplane.fill"
        )
    }
}
