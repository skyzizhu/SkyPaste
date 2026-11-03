import SwiftUI

struct ImageAnnotationToolbarView: View {
    @Binding var color: ImageAnnotationColor
    @Binding var strokeWidth: Double
    let canUndo: Bool
    let onUndo: () -> Void
    let onClear: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Text(L10n.tr("preview.annotation_hint"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)

                ForEach(ImageAnnotationColor.allCases, id: \.self) { option in
                    Button {
                        color = option
                    } label: {
                        Circle()
                            .fill(Color(nsColor: option.nsColor))
                            .frame(width: 17, height: 17)
                            .overlay {
                                Circle()
                                    .stroke(Color.primary.opacity(0.35), lineWidth: 0.8)
                            }
                            .padding(3)
                            .overlay {
                                Circle()
                                    .stroke(color == option ? Color.accentColor : .clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr(option.localizationKey))
                }

                HStack(spacing: 6) {
                    Image(systemName: "lineweight")
                        .foregroundStyle(.secondary)
                    Slider(value: $strokeWidth, in: 2...12, step: 1)
                        .frame(width: 104)
                        .accessibilityLabel(L10n.tr("preview.annotation_width"))
                    Text("\(Int(strokeWidth))")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 18, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)

                Spacer()

                Button(action: onUndo) {
                    Label(L10n.tr("preview.annotation_undo"), systemImage: "arrow.uturn.backward")
                }
                .disabled(!canUndo)

                Button(action: onClear) {
                    Label(L10n.tr("preview.annotation_clear"), systemImage: "trash")
                }
                .disabled(!canUndo)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 26)
        .padding(.vertical, 4)
    }
}
