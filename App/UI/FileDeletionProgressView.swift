import SwiftUI

struct FileDeletionProgressView: View {
    let progress: FileDeletionProgress?
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress, progress.totalCount > 0 {
                ProgressView(value: Double(progress.percent), total: 100).tint(.cyan)
                HStack {
                    Text("\(progress.percent)%").font(.headline.monospacedDigit())
                    Spacer()
                    Text("처리 \(progress.processedCount)/\(progress.totalCount)개")
                        .font(.caption.monospacedDigit())
                }
                if let name = progress.currentName, isRunning {
                    Text("삭제 중 · \(name)").font(.caption).lineLimit(2)
                }
                if progress.failedCount > 0 {
                    Text("삭제 실패 \(progress.failedCount)개").font(.caption).foregroundStyle(.red)
                }
            } else if isRunning {
                ProgressView("삭제할 항목 확인 중")
            }
        }
    }
}
