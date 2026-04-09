import SwiftUI

@MainActor
final class ClipboardSyncViewModel: ObservableObject {
    @Published var isSyncing = false
    @Published var message = "复制文本后，点下面按钮同步到 Mac。"
    @Published var isError = false

    private let uploader = CloudClipboardUploader()

    func syncCurrentPasteboard() {
        guard !isSyncing else { return }
        isSyncing = true
        isError = false
        message = "正在同步..."

        Task {
            do {
                try await uploader.uploadCurrentTextPasteboard()
                message = "同步成功，Mac 端稍后会自动出现在 SkyPaste 列表里。"
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
            isSyncing = false
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ClipboardSyncViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 62, weight: .semibold))
                    .foregroundStyle(.blue)
                    .padding(24)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                VStack(spacing: 10) {
                    Text("SkyPaste")
                        .font(.system(size: 34, weight: .bold, design: .rounded))

                    Text("将 iPhone 当前剪贴板同步到 Mac。")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text(model.message)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(model.isError ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .padding(.top, 4)

                Button {
                    model.syncCurrentPasteboard()
                } label: {
                    HStack {
                        if model.isSyncing {
                            ProgressView()
                        }
                        Text(model.isSyncing ? "同步中" : "同步当前剪贴板")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isSyncing)
                .padding(.horizontal, 28)
                .padding(.top, 8)

                Spacer()
            }
            .padding(24)
            .navigationTitle("SkyPaste")
            .background(Color(.systemGroupedBackground))
        }
    }
}
