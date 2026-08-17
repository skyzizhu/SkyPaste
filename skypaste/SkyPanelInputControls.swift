import SwiftUI

struct DeferredSearchField: View {
    let placeholder: String
    let query: String
    let font: Font
    let iconFont: Font
    let clearIconFont: Font
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
    let onQueryChange: (String) -> Void
    let onClose: () -> Void

    @FocusState private var isFocused: Bool
    @State private var draft: String
    @State private var pendingUpdate: DispatchWorkItem?

    init(
        placeholder: String,
        query: String,
        font: Font,
        iconFont: Font,
        clearIconFont: Font,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        cornerRadius: CGFloat,
        onQueryChange: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.placeholder = placeholder
        self.query = query
        self.font = font
        self.iconFont = iconFont
        self.clearIconFont = clearIconFont
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.cornerRadius = cornerRadius
        self.onQueryChange = onQueryChange
        self.onClose = onClose
        _draft = State(initialValue: query)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(iconFont)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .focused($isFocused)

            Button {
                pendingUpdate?.cancel()
                draft = ""
                onQueryChange("")
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(clearIconFont)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .onAppear {
            draft = query
            DispatchQueue.main.async {
                isFocused = true
            }
        }
        .onChange(of: query) { _, newValue in
            if newValue != draft {
                draft = newValue
            }
        }
        .onChange(of: draft) { _, newValue in
            scheduleQueryUpdate(for: newValue)
        }
        .onDisappear {
            pendingUpdate?.cancel()
        }
    }

    private func scheduleQueryUpdate(for value: String) {
        pendingUpdate?.cancel()

        let task = DispatchWorkItem {
            onQueryChange(value)
        }
        pendingUpdate = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: task)
    }
}

struct QuickPasteShortcuts: View {
    let onCopyAtIndex: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button("") { onCopyAtIndex(0) }.keyboardShortcut("1", modifiers: .command)
            Button("") { onCopyAtIndex(1) }.keyboardShortcut("2", modifiers: .command)
            Button("") { onCopyAtIndex(2) }.keyboardShortcut("3", modifiers: .command)
            Button("") { onCopyAtIndex(3) }.keyboardShortcut("4", modifiers: .command)
            Button("") { onCopyAtIndex(4) }.keyboardShortcut("5", modifiers: .command)
            Button("") { onCopyAtIndex(5) }.keyboardShortcut("6", modifiers: .command)
            Button("") { onCopyAtIndex(6) }.keyboardShortcut("7", modifiers: .command)
            Button("") { onCopyAtIndex(7) }.keyboardShortcut("8", modifiers: .command)
            Button("") { onCopyAtIndex(8) }.keyboardShortcut("9", modifiers: .command)
        }
    }
}

struct CopySelectionShortcut: View {
    let onCopySelected: () -> Void

    var body: some View {
        Button("") {
            onCopySelected()
        }
        .keyboardShortcut("c", modifiers: .command)
    }
}
