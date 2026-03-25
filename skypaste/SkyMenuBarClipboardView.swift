import SwiftUI

struct MenuBarClipboardView: View {
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

    private var presentation: Presentation {
        let filteredItems = Array(store.items.lazy.filter { selectedFilter.matches($0) }.prefix(80))
        let orderedItems: [ClipboardItem]
        let favoriteItems: [ClipboardItem]
        let daySource: [ClipboardItem]

        if selectedFilter == .favorites {
            orderedItems = filteredItems
            favoriteItems = []
            daySource = filteredItems
        } else {
            favoriteItems = filteredItems
                .lazy
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
        VStack(spacing: 12) {
            header
            filterBar
            contentArea
            footer
        }
        .padding(12)
        .frame(width: 396, height: 520)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
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
                    .padding(.top, 6)
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("menu.clipboard"))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(L10n.tr("menu.right_click_to_copy"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onOpenDebug) {
                Image(systemName: "ladybug")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("menu.debug"))
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
            LazyVStack(alignment: .leading, spacing: 14) {
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
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.03), radius: 14, y: 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            actionButton(title: L10n.tr("menu.copy_selected")) {
                guard let selected = presentation.orderedItems.first(where: { $0.id == selectedID }) else { return }
                copy(selected)
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(selectedID == nil)

            actionButton(title: L10n.tr("menu.open_panel")) {
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

            VStack(spacing: 2) {
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.78))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.04), lineWidth: 1)
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
    }

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .padding(.horizontal, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.54))
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
