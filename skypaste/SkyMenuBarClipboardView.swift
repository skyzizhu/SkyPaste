import AppKit
import SwiftUI

struct MenuBarClipboardView: View {
    @Environment(\.colorScheme) private var colorScheme

    private struct DaySection: Identifiable {
        let day: Date
        let items: [ClipboardItem]

        var id: Date { day }
    }

    private struct Presentation {
        let favoriteItems: [ClipboardItem]
        let orderedItems: [ClipboardItem]
        let daySections: [DaySection]
    }

    @ObservedObject var store: ClipboardStore
    @ObservedObject var settings: AppSettings
    let onPick: (ClipboardItem) -> Void
    let onCopy: (ClipboardItem) -> Void
    let onPreview: (ClipboardItem) -> Void
    let onTextPreview: (ClipboardItem) -> Void
    let onFileSystemPreview: (ClipboardItem) -> Void
    let onOpenFileItem: (ClipboardItem) -> Void
    let onOpenContainingFolder: (ClipboardItem) -> Void
    let onCopyFileSystemPath: (ClipboardItem) -> Void
    let onOpenURL: (ClipboardItem) -> Void
    let onOpenPanel: () -> Void
    let onOpenPreferences: () -> Void
    let onQuit: () -> Void

    @State private var selectedID: ClipboardItem.ID?
    @State private var showToast = false
    @State private var pendingDeleteDay: Date?
    @State private var selectedFilter: ClipboardFilter = .all
    @State private var isSearchVisible = false
    @State private var toastTask: DispatchWorkItem?
    @State private var pendingPrimaryAction: DispatchWorkItem?

    private var presentation: Presentation {
        let filteredItems = Array(store.items(for: selectedFilter).prefix(80))
        let favoriteItems: [ClipboardItem]
        let daySource: [ClipboardItem]

        switch selectedFilter {
        case .all:
            favoriteItems = []
            daySource = filteredItems
        case .favorites:
            favoriteItems = filteredItems
            daySource = []
        default:
            favoriteItems = []
            daySource = filteredItems
        }

        let orderedItems = favoriteItems + daySource

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
            favoriteItems: favoriteItems,
            orderedItems: orderedItems,
            daySections: daySections
        )
    }

    private func copyTimeText(_ date: Date) -> String {
        L10n.timeText(date)
    }

    private var popoverGlossGradient: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color.white.opacity(0.08),
                    Color.clear
                ]
                : [
                    Color.white.opacity(0.24),
                    Color.white.opacity(0.08)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var startupNoticeFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.58)
    }

    private var filterChipFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.94)
    }

    private var selectedFilterChipFill: Color {
        colorScheme == .dark ? .white : Color.accentColor.opacity(0.16)
    }

    private var selectedFilterChipText: Color {
        colorScheme == .dark ? .black : Color.accentColor
    }

    private func filterChipTextColor(for filter: ClipboardFilter) -> Color {
        selectedFilter == filter ? selectedFilterChipText : Color.primary.opacity(colorScheme == .dark ? 0.82 : 0.72)
    }

    private func filterChipStrokeColor(for filter: ClipboardFilter) -> Color {
        if selectedFilter == filter {
            return colorScheme == .dark ? Color.primary.opacity(0.24) : Color.accentColor.opacity(0.16)
        }
        return colorScheme == .dark ? Color.primary.opacity(0.08) : Color.black.opacity(0.05)
    }

    private func filterChipShadowColor(for filter: ClipboardFilter) -> Color {
        guard selectedFilter == filter, colorScheme != .dark else { return .clear }
        return Color.accentColor.opacity(0.10)
    }

    private func filterChipHorizontalPadding(for filter: ClipboardFilter) -> CGFloat {
        filter == .favorites ? 9 : 11
    }

    private func separatorInset(after item: ClipboardItem) -> CGFloat {
        item.isImage ? 64 : 12
    }

    private var contentAreaFill: Color {
        colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color.white.opacity(0.72)
    }

    private var sectionCardFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.78)
    }

    private var actionButtonFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.54)
    }

    private var isSearchActive: Bool {
        isSearchVisible || !store.appliedSearchText.isEmpty
    }

    private var contentScrollResetID: String {
        "\(selectedFilter.id)|\(store.appliedSearchText)"
    }

    private var searchButtonFill: Color {
        if isSearchActive {
            return colorScheme == .dark ? Color.white.opacity(0.96) : Color.accentColor.opacity(0.16)
        }
        return colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.82)
    }

    private var searchButtonForeground: Color {
        if isSearchActive {
            return colorScheme == .dark ? .black : Color.accentColor
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.84 : 0.76)
    }

    private var searchButtonStroke: Color {
        if isSearchActive {
            return colorScheme == .dark ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.24)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var searchButtonShadow: Color {
        guard isSearchActive else { return .clear }
        return colorScheme == .dark ? Color.black.opacity(0.18) : Color.accentColor.opacity(0.12)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if let startupNotice = store.startupNotice {
                startupNoticeBanner(startupNotice)
            }
            if isSearchVisible {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
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
                    .fill(popoverGlossGradient)
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
            isSearchVisible = !store.appliedSearchText.isEmpty
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
        .onChange(of: store.appliedSearchText) { _, _ in
            if !store.appliedSearchText.isEmpty {
                isSearchVisible = true
            }
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

    private var searchBar: some View {
        DeferredSearchField(
            placeholder: L10n.tr("panel.search_placeholder"),
            query: store.appliedSearchText,
            font: .system(size: 13, weight: .medium),
            iconFont: .system(size: 12, weight: .semibold),
            clearIconFont: .system(size: 12, weight: .semibold),
            horizontalPadding: 12,
            verticalPadding: 10,
            cornerRadius: 14,
            onQueryChange: store.setSearchQuery,
            onClose: closeSearch
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                appIconBadge(size: 34, cornerRadius: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("app.title"))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(L10n.tr("menu.clipboard_manager"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .offset(y: -2)

            Spacer()

            Button(action: toggleSearch) {
                Image(systemName: isSearchActive ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(searchButtonForeground)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(searchButtonFill)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(searchButtonStroke, lineWidth: colorScheme == .dark ? 1 : 0.9)
                    }
                    .shadow(color: searchButtonShadow, radius: 7, y: 2)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("menu.search"))
        }
    }

    private func appIconBadge(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 5, y: 2)
    }

    private func toggleSearch() {
        if isSearchVisible {
            closeSearch()
            return
        }

        withAnimation(.snappy(duration: 0.18)) {
            isSearchVisible = true
        }
    }

    private func closeSearch() {
        store.setSearchQuery("")
        withAnimation(.snappy(duration: 0.18)) {
            isSearchVisible = false
        }
    }

    private var filterBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClipboardFilter.allCases) { filter in
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            selectedFilter = filter
                        }
                    } label: {
                            HStack(spacing: 5) {
                                if let symbolSystemName = filter.symbolSystemName {
                                    Image(systemName: symbolSystemName)
                                        .font(.system(size: filter == .favorites ? 8 : 10, weight: .semibold))
                                }
                                Text(filter.title)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                            }
                            .foregroundStyle(filterChipTextColor(for: filter))
                            .padding(.horizontal, filterChipHorizontalPadding(for: filter))
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selectedFilter == filter ? selectedFilterChipFill : filterChipFill)
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(
                                        filterChipStrokeColor(for: filter),
                                        lineWidth: colorScheme == .dark ? 1 : 0.75
                                    )
                            }
                            .shadow(color: filterChipShadowColor(for: filter), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .id(filter)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear {
                proxy.scrollTo(selectedFilter, anchor: .center)
            }
            .onChange(of: selectedFilter) { _, filter in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(filter, anchor: .center)
                }
            }
        }
    }

    private func startupNoticeBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(text)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.dismissStartupNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(startupNoticeFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var contentArea: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if presentation.orderedItems.isEmpty {
                    emptyStateCard(
                        title: isSearchActive ? L10n.tr("panel.search_empty_title") : L10n.tr("panel.empty_title"),
                        message: emptyStateMessage,
                        showsClearSearch: isSearchActive
                    )
                } else {
                    if !presentation.favoriteItems.isEmpty {
                        sectionCard(
                            title: L10n.tr("section.favorites"),
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
            }
            .padding(10)
        }
        .id(contentScrollResetID)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(contentAreaFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.03), radius: 14, y: 8)
    }

    private var emptyStateMessage: String {
        if isSearchActive {
            if selectedFilter == .all {
                return L10n.tr("panel.search_empty_message")
            }
            return L10n.format("panel.search_empty_message_scoped", selectedFilter.title)
        }

        if selectedFilter == .all {
            return L10n.tr("panel.empty_message")
        }

        return L10n.format("panel.empty_message_scoped", selectedFilter.title)
    }

    private func emptyStateCard(title: String, message: String, showsClearSearch: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: showsClearSearch ? "magnifyingglass.circle" : "tray")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(colorScheme == .dark ? 0.9 : 0.7))

            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            Text(message)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            if showsClearSearch {
                actionButton(title: L10n.tr("panel.clear_search")) {
                    closeSearch()
                }
                .frame(maxWidth: 160)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(sectionCardFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        }
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

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    rowView(for: item)

                    if index < items.count - 1 {
                        rowSeparator(inset: separatorInset(after: item))
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(sectionCardFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.04), lineWidth: 1)
            }
        }
    }

    private func rowSeparator(inset: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, inset)
            .padding(.trailing, 12)
    }

    private func copy(_ item: ClipboardItem) {
        selectedID = item.id
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

    private func handleRowTap(_ item: ClipboardItem) {
        pendingPrimaryAction?.cancel()
        selectedID = item.id

        guard settings.autoPasteEnabled else { return }

        let task = DispatchWorkItem {
            copy(item)
        }
        pendingPrimaryAction = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private func handleRowDoubleTap(_ item: ClipboardItem) {
        pendingPrimaryAction?.cancel()
        selectedID = item.id
        if item.isFileCollection {
            onFileSystemPreview(item)
            return
        }
        if item.isImage {
            onPreview(item)
            return
        }
        guard item.supportsTextPreview else { return }
        onTextPreview(item)
    }

    private func rowView(for item: ClipboardItem) -> some View {
        ClipboardRowView(
            item: item,
            timeText: copyTimeText(item.createdAt),
            isSelected: selectedID == item.id,
            style: .popover,
            iconSize: 44,
            onPrimaryMouseDown: {
                pendingPrimaryAction?.cancel()
                selectedID = item.id
            },
            onSecondaryMouseDown: {
                pendingPrimaryAction?.cancel()
                selectedID = item.id
            },
            onPreview: item.isImage ? {
                pendingPrimaryAction?.cancel()
                selectedID = item.id
                onPreview(item)
            } : nil,
            onPreviewDoubleTap: item.isImage ? {
                handleRowDoubleTap(item)
            } : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleRowTap(item)
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    handleRowDoubleTap(item)
                }
        )
        .contextMenu {
            Button(L10n.tr("menu.copy")) {
                selectedID = item.id
                copy(item)
            }
            if item.isFileCollection {
                Button(item.openActionTitle) {
                    selectedID = item.id
                    onOpenFileItem(item)
                }
            }
            if item.isSingleFile {
                Button(L10n.tr("menu.reveal_in_finder")) {
                    selectedID = item.id
                    onOpenContainingFolder(item)
                }
            }
            if item.isFileCollection {
                Button(L10n.tr("menu.copy_path")) {
                    selectedID = item.id
                    onCopyFileSystemPath(item)
                    showCopyToast()
                }
            }
            if item.isURL {
                Button(L10n.tr("menu.open_in_browser")) {
                    selectedID = item.id
                    onOpenURL(item)
                }
            }
            if item.isImage {
                Button(L10n.tr("preview.open")) {
                    selectedID = item.id
                    onPreview(item)
                }
            }
            if item.supportsTextPreview {
                Button(L10n.tr("preview.text_open")) {
                    selectedID = item.id
                    onTextPreview(item)
                }
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
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .padding(.horizontal, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(actionButtonFill)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}
