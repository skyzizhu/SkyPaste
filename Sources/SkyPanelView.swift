import SwiftUI

struct PanelView: View {
    @ObservedObject var store: ClipboardStore
    let onPick: (ClipboardItem) -> Void
    let onCopy: (ClipboardItem) -> Void
    let onClose: () -> Void

    @State private var selectedID: ClipboardItem.ID?
    @State private var pendingDeleteDay: Date?
    @State private var selectedFilter: ClipboardFilter = .all
    @State private var showToast = false
    @State private var toastTask: DispatchWorkItem?

    private var filteredItems: [ClipboardItem] {
        store.filteredItems.filter { selectedFilter.matches($0) }
    }

    private var orderedFilteredItems: [ClipboardItem] {
        if selectedFilter == .favorites {
            return filteredItems
        }
        return favoriteItems + nonFavoriteItems
    }

    private struct DaySection: Identifiable {
        let day: Date
        let items: [ClipboardItem]

        var id: Date { day }
    }

    private var daySections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: nonFavoriteItems) { item in
            calendar.startOfDay(for: item.createdAt)
        }

        let sortedDays = grouped.keys.sorted(by: >)
        return sortedDays.map { day in
            let items = (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            return DaySection(day: day, items: items)
        }
    }

    private var favoriteItems: [ClipboardItem] {
        guard selectedFilter != .favorites else { return [] }
        return filteredItems.filter(\.isFavorite).sorted { $0.createdAt > $1.createdAt }
    }

    private var nonFavoriteItems: [ClipboardItem] {
        guard selectedFilter != .favorites else { return filteredItems }
        return filteredItems.filter { !$0.isFavorite }
    }

    private var filteredIDs: [ClipboardItem.ID] {
        orderedFilteredItems.map(\.id)
    }

    private func copyTimeText(_ date: Date) -> String {
        L10n.timeText(date)
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField(L10n.tr("panel.search_placeholder"), text: $store.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.top, 10)
                .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClipboardFilter.allCases) { filter in
                        Button {
                            selectedFilter = filter
                        } label: {
                            Text(filter.title)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(selectedFilter == filter ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1))
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(selectedFilter == filter ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }

            List {
                if !favoriteItems.isEmpty {
                    Section(L10n.tr("filter.favorites")) {
                        ForEach(Array(favoriteItems.enumerated()), id: \.element.id) { index, item in
                            rowView(for: item, hidesBottomSeparator: index == favoriteItems.count - 1)
                        }
                    }
                }

                ForEach(daySections) { section in
                    Section {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            rowView(for: item, hidesBottomSeparator: index == section.items.count - 1)
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Text(L10n.sectionTitle(for: section.day))
                            Spacer()
                            Button {
                                pendingDeleteDay = section.day
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onMoveCommand(perform: moveSelection)

            HStack {
                Text(L10n.tr("panel.shortcut_hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("panel.paste_selected")) {
                    pasteSelected()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selectedID == nil)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

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
        .frame(minWidth: 560, minHeight: 480)
        .overlay(alignment: .top) {
            if showToast {
                Text(L10n.tr("menu.copy_success"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            selectedID = orderedFilteredItems.first?.id
        }
        .onChange(of: filteredIDs) { ids in
            if let selectedID, ids.contains(selectedID) {
                return
            }
            self.selectedID = ids.first
        }
        .onChange(of: selectedFilter) { _ in
            selectedID = orderedFilteredItems.first?.id
        }
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

    private func pasteSelected() {
        guard let selected = orderedFilteredItems.first(where: { $0.id == selectedID }) else { return }
        onPick(selected)
    }

    private func copySelected() {
        guard let selected = orderedFilteredItems.first(where: { $0.id == selectedID }) else { return }
        onCopy(selected)
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

    private func pasteItemAtIndex(_ index: Int) {
        guard index >= 0, index < orderedFilteredItems.count else { return }
        onPick(orderedFilteredItems[index])
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !orderedFilteredItems.isEmpty else {
            selectedID = nil
            return
        }

        guard let selectedID, let currentIndex = orderedFilteredItems.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = orderedFilteredItems.first?.id
            return
        }

        switch direction {
        case .up:
            self.selectedID = orderedFilteredItems[max(0, currentIndex - 1)].id
        case .down:
            self.selectedID = orderedFilteredItems[min(orderedFilteredItems.count - 1, currentIndex + 1)].id
        default:
            break
        }
    }

    private func rowView(for item: ClipboardItem, hidesBottomSeparator: Bool = false) -> some View {
        ClipboardRowView(
            item: item,
            timeText: copyTimeText(item.createdAt),
            isSelected: selectedID == item.id
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
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(hidesBottomSeparator ? .hidden : .visible, edges: .bottom)
    }

    private func copySelected(_ item: ClipboardItem) {
        onCopy(item)
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
