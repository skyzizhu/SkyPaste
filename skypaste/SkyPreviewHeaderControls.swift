import SwiftUI

struct PreviewHeaderAction: Identifiable {
    let title: String
    let systemImage: String
    let action: () -> Void

    var id: String { "\(systemImage)|\(title)" }
}

@MainActor
final class GlobalToastModel: ObservableObject {
    @Published var message: String = ""
}

struct GlobalToastView: View {
    @ObservedObject var model: GlobalToastModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)

            Text(model.message)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .fixedSize()
        .background(backgroundColor)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.94) : Color.black.opacity(0.86)
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.84) : Color.white.opacity(0.96)
    }

    private var iconColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.72) : Color.white.opacity(0.92)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.08) : Color.white.opacity(0.08)
    }
}

struct PreviewHeaderActionBar: View {
    let actions: [PreviewHeaderAction]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                Button(action: action.action) {
                    Label(action.title, systemImage: action.systemImage)
                }
                .fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

struct PreviewHeaderShareButton: View {
    let item: ClipboardItem

    var body: some View {
        Button {
            ClipboardSharingService.presentPicker(for: item)
        } label: {
            Label(L10n.tr("menu.share"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
