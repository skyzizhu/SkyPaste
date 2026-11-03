import AppKit
import SwiftUI

struct ImageFilePreviewWorkspace: View {
    let item: ClipboardItem
    let image: NSImage

    @State private var zoomScale: CGFloat = 1
    @State private var zoomAnimationNonce = 0
    @State private var isAnnotating = false
    @State private var annotationColor: ImageAnnotationColor = .red
    @State private var annotationStrokeWidth = 4.0
    @State private var annotationStrokes: [ImageAnnotationStroke] = []
    @State private var annotatedPNG: Data?
    @State private var annotationRenderTask: Task<Data?, Never>?
    @State private var annotationExportID = UUID()
    @State private var annotationExportFailed = false

    var body: some View {
        VStack(spacing: 0) {
            controls

            Divider()

            if isAnnotating {
                ImageAnnotationToolbarView(
                    color: $annotationColor,
                    strokeWidth: $annotationStrokeWidth,
                    canUndo: !annotationStrokes.isEmpty,
                    onUndo: {
                        _ = annotationStrokes.popLast()
                        prepareAnnotationExport()
                    },
                    onClear: {
                        annotationStrokes.removeAll()
                        prepareAnnotationExport()
                    }
                )
                Divider()
            }

            GeometryReader { proxy in
                let viewport = CGSize(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))

                MagnifiableImagePreviewRepresentable(
                    image: image,
                    annotationStrokes: annotationStrokes,
                    isAnnotating: isAnnotating,
                    annotationColor: annotationColor,
                    annotationStrokeWidth: CGFloat(annotationStrokeWidth),
                    onStrokeCompleted: addAnnotationStroke,
                    onResolveDragItem: dragItem,
                    zoomScale: $zoomScale,
                    zoomAnimationNonce: zoomAnimationNonce,
                    availableSize: viewport
                )
                .frame(width: viewport.width, height: viewport.height)
                .overlay(alignment: .bottomTrailing) {
                    if isAnnotating {
                        annotationDoneButton
                            .padding(20)
                    } else {
                        dragHint
                            .padding(20)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { annotationRenderTask?.cancel() }
        .alert(L10n.tr("preview.annotation_export_error_title"), isPresented: $annotationExportFailed) {
            Button(L10n.tr("menu.ok"), role: .cancel) {}
        } message: {
            Text(L10n.tr("preview.annotation_export_error_message"))
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                isAnnotating.toggle()
            } label: {
                Label(
                    L10n.tr(isAnnotating ? "preview.annotation_done" : "preview.annotate"),
                    systemImage: "pencil.tip"
                )
            }

            Spacer(minLength: 12)

            Button {
                updateZoomScale(zoomScale - 0.2)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }

            Button {
                updateZoomScale(1)
            } label: {
                Text(abs(zoomScale - 1) < 0.01 ? L10n.tr("preview.fit") : "\(Int(zoomScale * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 52)
            }

            Button {
                updateZoomScale(zoomScale + 0.2)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var dragHint: some View {
        Label(
            L10n.tr(!annotationStrokes.isEmpty && annotatedPNG == nil
                ? "preview.annotation_preparing"
                : zoomScale > 1.01 ? "preview.drag_zoomed_hint" : "preview.drag_hint"),
            systemImage: "hand.point.up.left"
        )
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1) }
    }

    private var annotationDoneButton: some View {
        Button {
            isAnnotating = false
        } label: {
            Label(L10n.tr("preview.annotation_done"), systemImage: "checkmark")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func updateZoomScale(_ value: CGFloat) {
        let clamped = min(max(value, 0.4), 5)
        guard abs(zoomScale - clamped) > 0.001 else { return }
        zoomScale = clamped
        zoomAnimationNonce += 1
    }

    private func addAnnotationStroke(_ stroke: ImageAnnotationStroke) {
        annotationStrokes.append(stroke)
        prepareAnnotationExport()
    }

    private func prepareAnnotationExport() {
        annotationRenderTask?.cancel()
        annotatedPNG = nil
        annotationExportID = UUID()
        guard !annotationStrokes.isEmpty, let url = item.singleFileURL else {
            annotationRenderTask = nil
            return
        }

        let strokes = annotationStrokes
        let task = Task.detached(priority: .userInitiated) {
            ImageAnnotationRenderer.pngData(for: url, strokes: strokes)
        }
        annotationRenderTask = task
        Task {
            let data = await task.value
            guard annotationStrokes == strokes else { return }
            annotatedPNG = data
            if data == nil, !task.isCancelled {
                annotationExportFailed = true
            }
        }
    }

    private func dragItem() -> ClipboardItem? {
        guard !annotationStrokes.isEmpty else { return item }
        guard let annotatedPNG else { return nil }
        let name = item.singleFileURL?.deletingPathExtension().lastPathComponent ?? "SkyPaste Image"
        return ClipboardItem(
            id: annotationExportID,
            createdAt: item.createdAt,
            content: .image(data: annotatedPNG, name: "\(name)-annotated.png", originalByteCount: annotatedPNG.count, previewOnly: false),
            fingerprint: annotationExportID.uuidString
        )
    }
}
