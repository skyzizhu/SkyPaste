import SwiftUI

struct MenuBarClipboardView: View {
    @ObservedObject var store: ClipboardStore
    let onCopy: (ClipboardItem) -> Void
    let onOpenPanel: () -> Void
    let onOpenDebug: () -> Void
    let onOpenPreferences: () -> Void
    let onQuit: () -> Void

    @State private var selectedID: ClipboardItem.ID?
    @State private var showToast = false
    @State private var pendingDeleteDay: Date?
    @State private var selectedFilter: ClipboardFilter = .all
    @State private var toastTask: DispatchWorkItem?

    private var displayItems: [ClipboardItem] {
        Array(store.items.filter { selectedFilter.matches($0) }.prefix(50))
    }

    private var orderedDisplayItems: [ClipboardItem] {
        if selectedFilter == .favorites {
            return displayItems
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
        return displayItems.filter(\.isFavorite).sorted { $0.createdAt > $1.createdAt }
    }

    private var nonFavoriteItems: [ClipboardItem] {
        guard selectedFilter != .favorites else { return displayItems }
        return displayItems.filter { !$0.isFavorite }
    }

    private func copyTimeText(_ date: Date) -> String {
        L10n.timeText(date)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(L10n.tr("menu.clipboard"))
                    .font(.system(size: 14, weight: .semibold))
                Button(action: onOpenDebug) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(L10n.tr("menu.debug"))
                Spacer()
                Text(L10n.tr("menu.right_click_to_copy"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClipboardFilter.allCases) { filter in
                        Button {
                            selectedFilter = filter
                        } label: {
                            Text(filter.title)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
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
                .padding(.horizontal, 1)
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

            HStack(spacing: 6) {
                actionButton(
                    title: L10n.tr("menu.copy_selected")
                ) {
                    guard let selected = orderedDisplayItems.first(where: { $0.id == selectedID }) else { return }
                    copy(selected)
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(selectedID == nil)

                actionButton(
                    title: L10n.tr("menu.open_panel")
                ) {
                    onOpenPanel()
                }

                actionButton(title: L10n.tr("menu.preferences")) {
                    onOpenPreferences()
                }

                actionButton(title: L10n.tr("menu.quit")) {
                    onQuit()
                }
            }
        }
        .padding(10)
        .frame(width: 360, height: 460)
        .overlay(alignment: .top) {
            if showToast {
                Text(L10n.tr("menu.copy_success"))
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            selectedID = orderedDisplayItems.first?.id
        }
        .onChange(of: orderedDisplayItems.map(\.id)) { ids in
            if let selectedID, ids.contains(selectedID) {
                return
            }
            self.selectedID = ids.first
        }
        .onChange(of: selectedFilter) { _ in
            selectedID = orderedDisplayItems.first?.id
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

    private func copy(_ item: ClipboardItem) {
        selectedID = item.id
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
                copy(item)
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

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity)
                .frame(height: 27)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}
