import AppIntents

struct SendNewSimpleCameraPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "새 SimpleCamera 사진 전송"
    static let description = IntentDescription(
        "Simple Cam으로 새로 촬영한 업무사진을 모두 전송합니다."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = try await AppDependencies.shared.syncService.run(
            trigger: .automation
        )
        return .result(dialog: "\(summary.automationResultDescription)")
    }
}
