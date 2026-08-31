import AppIntents
import Foundation

struct SendNewSimpleCameraPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "새 SimpleCamera 사진 전송"
    static let description = IntentDescription(
        "Simple Cam으로 새로 촬영한 업무사진을 모두 전송합니다."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let summary = try await AppDependencies.shared.syncService.run(
                trigger: .automation
            )
            return .result(dialog: "\(summary.automationResultDescription)")
        } catch let error where error is CancellationError
            || (error as NSError).domain == NSURLErrorDomain
                && (error as NSError).code == NSURLErrorCancelled {
            return .result(dialog: "자동전송이 일시중단되었습니다. 남은 사진은 다음 자동실행 때 다시 전송합니다.")
        }
    }
}
