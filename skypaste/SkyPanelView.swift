import SwiftUI

struct PanelView: View {
    private struct DaySection: Identifiable {
        let day: Date
        let items: [ClipboardItem]

        var id: Date { day }
    }

    private struct Presentation {
        let orderedItems: [ClipboardItem]
        let favoriteItems: [ClipboardItem]
        let daySections: [DaySection]
    }

    @ObservedObject var store: ClipboardStore
    @ObservedObject var settings: AppSettings
    let onPick: (ClipboardItem) -> Void
    let onCopy: (ClipboardItem) -> Void
    let onClose: () -> Void

    @State private var selectedID: ClipboardItem.ID?
    @State private var pendingDeleteDay: Date?
    @State private var selectedFilter: ClipboardFilter = .all
    @State private var showToast = false
    @State private var toastTask: DispatchWorkItem?

    private var presentation: Presentation {
        let filteredItems = store.filteredItems.filter { selectedFilter.matches($0) }
        let orderedItems: [ClipboardItem]
        let favoriteItems: [ClipboardItem]
        let daySource: [ClipboardItem]

        if selectedFilter == .favorites {
            orderedItems = filteredItems
            favoriteItems = []
            daySource = filteredItems
        } else {
            favoriteItems = filteredItems
                .filter(\.isFavorite)
                .sorted { $0.createdAt > $1.createdAt }
            daySource = filteredItems.filter { !$0.isFavorite }
            orderedItems = favoriteItems + daySource
        }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: daySource) { item in
            calendar.startOfDay(for: item.createdAt)
        }

        let daySections = grouped.keys.sorted(by: >).map { day in
            DaySection(
                day: day,
                items: (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            )
        }

        return Presentation(
            orderedItems: orderedItems,
            favoriteItems: favoriteItems,
            daySections: daySections
        )
    }

    private func copyTimeText(_ date: Date) -> String {
        L10n.timeText(date)
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            searchBar
            filterBar
            contentArea
            footer

            QuickPasteShortcuts(onPickAtIndex: pasteItemAtIndex)
                .frame(width: 0, height: 0)
                .opacity(0.01)
                .allowsHitTesting(false)

            CopySelectionShortcut {
                copySelected()
            }
            .frame(width: 0, height: 0)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 620)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.08),
                        Color.clear,
                        Color.primary.opacity(0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .overlay(alignment: .top) {
            if showToast {
                Text(L10n.tr("menu.copy_success"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            selectedID = presentation.orderedItems.first?.id
        }
        .onChange(of: presentation.orderedItems.map(\.id)) { _, ids in
            guard let selectedID else {
                self.selectedID = ids.first
                return
            }

            if !ids.contains(selectedID) {
                self.selectedID = ids.first
            }
        }
        .onChange(of: selectedFilter) { _, _ in
            selectedID = presentation.orderedItems.first?.id
        }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand {
            onClose()
        }
        .alert(
            L10n.tr("menu.delete_day_title"),
            isPresented: Binding(
                get: { pendingDeleteDay != nil },
                set: { if !$0 { pendingDeleteDay = nil } }
            )
        ) {
            Button(L10n.tr("menu.delete"), role: .destructive) {
                if let day = pendingDeleteDay {
                    store.deleteAllItems(onDay: day)
                }
                pendingDeleteDay = nil
            }
            Button(L10n.tr("menu.cancel"), role: .cancel) {
                pendingDeleteDay = nil
            }
        } message: {
            if let day = pendingDeleteDay {
                Text(L10n.format("menu.delete_day_message", L10n.sectionTitle(for: day)))
            } else {
                Text("")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("app.title"))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(settings.autoPasteEnabled ? L10n.tr("panel.shortcut_hint") : L10n.tr("panel.shortcut_hint_copy_only"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L10n.tr("panel.search_placeholder"), text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ClipboardFilter.allCases) { filter in
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            selectedFilter = filter
                        }
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(selectedFilter == filter ? Color.accentColor : Color.primary.opacity(0.82))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selectedFilter == filter ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.54))
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(
                                        selectedFilter == filter ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.08),
                                        lineWidth: 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var contentArea: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !presentation.favoriteItems.isEmpty {
                    sectionCard(
                        title: L10n.tr("filter.favorites"),
                        items: presentation.favoriteItems,
                        allowDeleteDay: false
                    )
                }

                ForEach(presentation.daySections) { section in
                    sectionCard(
                        title: L10n.sectionTitle(for: section.day),
                        items: section.items,
                        allowDeleteDay: true,
                        onDeleteDay: {
                            pendingDeleteDay = section.day
                        }
                    )
                }
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.76))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            actionButton(title: settings.autoPasteEnabled ? L10n.tr("panel.paste_selected") : L10n.tr("menu.copy_selected")) {
                performPrimaryAction()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(selectedID == nil)

            actionButton(title: L10n.tr("menu.copy")) {
                copySelected()
            }
            .disabled(selectedID == nil)

            Spacer(minLength: 0)
        }
    }

    private func sectionCard(
        title: String,
        items: [ClipboardItem],
        allowDeleteDay: Bool,
        onDeleteDay: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()

                if allowDeleteDay, let onDeleteDay {
                    Button(action: onDeleteDay) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    rowView(for: item)

                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, item.isImage ? 64 : 12)
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.84))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.04), lineWidth: 1)
            }
        }
    }

    private func performPrimaryAction() {
        guard let selected = presentation.orderedItems.first(where: { $0.id == selectedID }) else { return }
        if settings.autoPasteEnabled {
            onPick(selected)
        } else {
            onCopy(selected)
            onClose()
        }
    }

    private func copySelected() {
        guard let selected = presentation.orderedItems.first(where: { $0.id == selectedID }) else { return }
        onCopy(selected)
        showCopyToast()
    }

    private func pasteItemAtIndex(_ index: Int) {
        guard index >= 0, index < presentation.orderedItems.count else { return }
        onPick(presentation.orderedItems[index])
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !presentation.orderedItems.isEmpty else {
            selectedID = nil
            return
        }

        guard let selectedID, let currentIndex = presentation.orderedItems.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = presentation.orderedItems.first?.id
            return
        }

        switch direction {
        case .up:
            self.selectedID = presentation.orderedItems[max(0, currentIndex - 1)].id
        case .down:
            self.selectedID = presentation.orderedItems[min(presentation.orderedItems.count - 1, currentIndex + 1)].id
        default:
            break
        }
    }

    private func rowView(for item: ClipboardItem) -> some View {
        ClipboardRowView(
            item: item,
            timeText: copyTimeText(item.createdAt),
            isSelected: selectedID == item.id,
            style: .popover,
            iconSize: 44
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedID = item.id
        }
        .contextMenu {
            Button(L10n.tr("menu.copy")) {
                selectedID = item.id
                copySelected(item)
            }
            Button(item.isFavorite ? L10n.tr("menu.unfavorite") : L10n.tr("menu.favorite")) {
                selectedID = item.id
                store.toggleFavorite(for: item.id)
            }
            Button(L10n.tr("menu.delete"), role: .destructive) {
                store.deleteItem(item.id)
            }
        }
    }

    private func copySelected(_ item: ClipboardItem) {
        onCopy(item)
        showCopyToast()
    }

    private func showCopyToast() {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            showToast = true
        }

        let dismissTask = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.2)) {
                showToast = false
            }
        }
        toastTask = dismissTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: dismissTask)
    }

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.84))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.56))
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct QuickPasteShortcuts: View {
    let onPickAtIndex: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button("") { onPickAtIndex(0) }.keyboardShortcut("1", modifiers: .command)
            Button("") { onPickAtIndex(1) }.keyboardShortcut("2", modifiers: .command)
            Button("") { onPickAtIndex(2) }.keyboardShortcut("3", modifiers: .command)
            Button("") { onPickAtIndex(3) }.keyboardShortcut("4", modifiers: .command)
            Button("") { onPickAtIndex(4) }.keyboardShortcut("5", modifiers: .command)
            Button("") { onPickAtIndex(5) }.keyboardShortcut("6", modifiers: .command)
            Button("") { onPickAtIndex(6) }.keyboardShortcut("7", modifiers: .command)
            Button("") { onPickAtIndex(7) }.keyboardShortcut("8", modifiers: .command)
            Button("") { onPickAtIndex(8) }.keyboardShortcut("9", modifiers: .command)
        }
    }
}

private struct CopySelectionShortcut: View {
    let onCopySelected: () -> Void

    var body: some View {
        Button("") {
            onCopySelected()
        }
        .keyboardShortcut("c", modifiers: .command)
    }
}
