import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PanelView: View {
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

        static let empty = Presentation(favoriteItems: [], orderedItems: [], daySections: [])
    }

    private struct SourceAppFilterOption: Identifiable, Hashable {
        let bundleID: String
        let name: String

        var id: String { bundleID }
    }

    @ObservedObject var store: ClipboardStore
    @ObservedObject var settings: AppSettings
    let onPick: (ClipboardItem) -> Void
    let onCopy: (ClipboardItem) -> Void
    let onCopyPlainText: (ClipboardItem) -> Void
    let onPastePlainText: (ClipboardItem) -> Void
    let onPreview: (ClipboardItem) -> Void
    let onTextPreview: (ClipboardItem) -> Void
    let onFileSystemPreview: (ClipboardItem) -> Void
    let onOpenFileItem: (ClipboardItem) -> Void
    let onOpenContainingFolder: (ClipboardItem) -> Void
    let onCopyFileSystemPath: (ClipboardItem) -> Void
    let onOpenURL: (ClipboardItem) -> Void
    let onClose: () -> Void

    @State private var selectedID: ClipboardItem.ID?
    @State private var pendingDeleteDay: Date?
    @State private var selectedFilter: ClipboardFilter = .all
    @State private var isSearchVisible = false
    @State private var pendingPrimaryAction: DispatchWorkItem?
    @State private var draggedFilter: ClipboardFilter?
    @State private var displayedFilters = ClipboardFilter.defaultDisplayOrder
    @State private var selectedSourceAppBundleID: String?
    @State private var sourceAppIcons: [String: NSImage] = [:]
    @State private var presentation = Presentation.empty

    private func copyTimeText(_ date: Date) -> String {
        L10n.timeText(date)
    }

    private var startupNoticeFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.6)
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

    private func selectFilter(_ filter: ClipboardFilter) {
        withAnimation(.easeOut(duration: 0.1)) {
            selectedFilter = filter
        }
    }

    private func persistDisplayedFilterOrder() {
        settings.saveFilterOrder(displayedFilters.filter(\.isUserReorderable))
    }

    private func moveFilterToFront(_ filter: ClipboardFilter) {
        guard filter.isUserReorderable else { return }
        var reorderable = displayedFilters.filter(\.isUserReorderable)
        reorderable.removeAll { $0 == filter }
        reorderable.insert(filter, at: 0)
        displayedFilters = ClipboardFilter.displayOrder(from: reorderable)
        persistDisplayedFilterOrder()
    }

    private func moveFilterToBack(_ filter: ClipboardFilter) {
        guard filter.isUserReorderable else { return }
        var reorderable = displayedFilters.filter(\.isUserReorderable)
        reorderable.removeAll { $0 == filter }
        reorderable.append(filter)
        displayedFilters = ClipboardFilter.displayOrder(from: reorderable)
        persistDisplayedFilterOrder()
    }

    private func resetDisplayedFilterOrder() {
        displayedFilters = ClipboardFilter.defaultDisplayOrder
        persistDisplayedFilterOrder()
    }

    private func refreshPresentation() {
        presentation = Self.makePresentation(
            filteredItems: filteredItemsForSelectedScope,
            selectedFilter: selectedFilter
        )
    }

    private func delete(_ item: ClipboardItem) {
        pendingPrimaryAction?.cancel()
        store.deleteItem(item.id)
        refreshPresentation()
        selectedID = presentation.orderedItems.first?.id
    }

    private static func makePresentation(filteredItems: [ClipboardItem], selectedFilter: ClipboardFilter) -> Presentation {
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

    private func separatorInset(after item: ClipboardItem) -> CGFloat {
        item.isImage ? 64 : 12
    }

    private var contentAreaFill: Color {
        colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color.white.opacity(0.76)
    }

    private var sectionCardFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.84)
    }

    private var actionButtonFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.56)
    }

    private var isSearchActive: Bool {
        isSearchVisible || !store.appliedSearchText.isEmpty
    }

    private var contentScrollResetID: String {
        "\(selectedFilter.id)|\(store.appliedSearchText)|\(selectedSourceAppBundleID ?? "all-apps")"
    }

    private var baseItemsForSelectedFilter: [ClipboardItem] {
        store.items(for: selectedFilter)
    }

    private var availableSourceAppOptions: [SourceAppFilterOption] {
        var seen = Set<String>()
        return baseItemsForSelectedFilter
            .compactMap(\.sourceApp)
            .compactMap { app in
                guard seen.insert(app.bundleID).inserted else { return nil }
                return SourceAppFilterOption(bundleID: app.bundleID, name: app.name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredItemsForSelectedScope: [ClipboardItem] {
        let items = baseItemsForSelectedFilter
        guard let selectedSourceAppBundleID else { return items }
        return items.filter { $0.sourceApp?.bundleID == selectedSourceAppBundleID }
    }

    private func validateSourceAppSelection() {
        guard let selectedSourceAppBundleID else { return }
        guard availableSourceAppOptions.contains(where: { $0.bundleID == selectedSourceAppBundleID }) else {
            self.selectedSourceAppBundleID = nil
            return
        }
    }

    private var searchButtonFill: Color {
        if isSearchActive {
            return colorScheme == .dark ? Color.white.opacity(0.96) : Color.accentColor.opacity(0.16)
        }
        return colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.white.opacity(0.84)
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
        VStack(spacing: 14) {
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

            QuickPasteShortcuts(onCopyAtIndex: copyItemAtIndex)
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
        .onAppear {
            displayedFilters = settings.orderedFilters
            loadSourceAppIconsIfNeeded()
            refreshPresentation()
            selectedID = presentation.orderedItems.first?.id
            isSearchVisible = !store.appliedSearchText.isEmpty
        }
        .onReceive(store.$filteredItemsByFilter) { _ in
            validateSourceAppSelection()
            refreshPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .filterOrderSettingsChanged)) { _ in
            guard draggedFilter == nil else { return }
            displayedFilters = settings.orderedFilters
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
            validateSourceAppSelection()
            refreshPresentation()
            selectedID = presentation.orderedItems.first?.id
        }
        .onChange(of: store.appliedSearchText) { _, _ in
            if !store.appliedSearchText.isEmpty {
                isSearchVisible = true
            }
            validateSourceAppSelection()
            refreshPresentation()
            selectedID = presentation.orderedItems.first?.id
        }
        .onChange(of: selectedSourceAppBundleID) { _, _ in
            refreshPresentation()
            selectedID = presentation.orderedItems.first?.id
        }
        .onChange(of: availableSourceAppOptions.map(\.bundleID)) { _, _ in
            loadSourceAppIconsIfNeeded()
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
            HStack(alignment: .top, spacing: 12) {
                appIconBadge(size: 44, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("app.title"))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(settings.autoPasteEnabled ? L10n.tr("panel.shortcut_hint") : L10n.tr("panel.shortcut_hint_copy_only"))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .offset(y: -2)

            Spacer()

            Button {
                toggleSearch()
            } label: {
                Image(systemName: isSearchActive ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
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

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func appIconBadge(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 6, y: 2)
    }

    private var searchBar: some View {
        DeferredSearchField(
            placeholder: L10n.tr("panel.search_placeholder"),
            query: store.appliedSearchText,
            font: .system(size: 15, weight: .medium),
            iconFont: .system(size: 14, weight: .medium),
            clearIconFont: .system(size: 13, weight: .semibold),
            horizontalPadding: 14,
            verticalPadding: 12,
            cornerRadius: 16,
            onQueryChange: store.setSearchQuery,
            onClose: closeSearch
        )
    }

    private var sourceAppFilterTitle: String {
        guard let selectedSourceAppBundleID,
              let app = availableSourceAppOptions.first(where: { $0.bundleID == selectedSourceAppBundleID }) else {
            return L10n.tr("filter.source_label")
        }
        return app.name
    }

    private var selectedSourceAppOption: SourceAppFilterOption? {
        guard let selectedSourceAppBundleID else { return nil }
        return availableSourceAppOptions.first(where: { $0.bundleID == selectedSourceAppBundleID })
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

    private func startupNoticeBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(startupNoticeFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(displayedFilters) { filter in
                            filterChip(for: filter)
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
            if !availableSourceAppOptions.isEmpty {
                sourceAppMenu
            }
        }
    }

    private var sourceAppMenu: some View {
        let isActive = selectedSourceAppBundleID != nil

        return Menu {
            Button {
                withAnimation(.easeOut(duration: 0.1)) {
                    selectedSourceAppBundleID = nil
                }
            } label: {
                HStack(spacing: 8) {
                    sourceAppMenuIcon(bundleID: nil, size: 14)
                    Text(L10n.tr("filter.source_all"))
                    if selectedSourceAppBundleID == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(availableSourceAppOptions) { app in
                Button {
                    withAnimation(.easeOut(duration: 0.1)) {
                        selectedSourceAppBundleID = app.bundleID
                    }
                } label: {
                    HStack(spacing: 8) {
                        sourceAppMenuIcon(bundleID: app.bundleID, size: 14)
                        Text(app.name)
                        if selectedSourceAppBundleID == app.bundleID {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            sourceAppButtonIcon(size: 16)
            .foregroundStyle(isActive ? selectedFilterChipText : Color.primary.opacity(colorScheme == .dark ? 0.82 : 0.72))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? selectedFilterChipFill : filterChipFill)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        isActive
                            ? (colorScheme == .dark ? Color.primary.opacity(0.24) : Color.accentColor.opacity(0.16))
                            : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05),
                        lineWidth: 1
                    )
            }
            .shadow(color: isActive ? filterChipShadowColor(for: .all) : .clear, radius: 6, y: 2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help(selectedSourceAppOption?.name ?? sourceAppFilterTitle)
    }

    @ViewBuilder
    private func sourceAppButtonIcon(size: CGFloat) -> some View {
        if let selectedSourceAppOption, let icon = sourceAppIcons[selectedSourceAppOption.bundleID] {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: size - 2, weight: .semibold))
        }
    }

    @ViewBuilder
    private func sourceAppMenuIcon(bundleID: String?, size: CGFloat) -> some View {
        if let bundleID, let icon = sourceAppIcons[bundleID] {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: size - 2, weight: .semibold))
                .frame(width: size, height: size)
        }
    }

    private func loadSourceAppIconsIfNeeded() {
        for app in availableSourceAppOptions where sourceAppIcons[app.bundleID] == nil {
            ClipboardSourceAppIconProvider.shared.loadIcon(
                for: ClipboardSourceApp(bundleID: app.bundleID, name: app.name)
            ) { icon in
                guard let icon else { return }
                sourceAppIcons[app.bundleID] = icon
            }
        }
    }

    @ViewBuilder
    private func filterChip(for filter: ClipboardFilter) -> some View {
        let chip = Button {
            selectFilter(filter)
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
        .contextMenu {
            if filter.isUserReorderable {
                Button(L10n.tr("filter.move_first")) {
                    moveFilterToFront(filter)
                }
                Button(L10n.tr("filter.move_last")) {
                    moveFilterToBack(filter)
                }
                Divider()
            }
            Button(L10n.tr("filter.reset_order")) {
                resetDisplayedFilterOrder()
            }
        }

        if filter.isUserReorderable {
            chip
                .opacity(draggedFilter == filter ? 0.78 : 1)
                .onDrag {
                    draggedFilter = filter
                    return NSItemProvider(object: filter.rawValue as NSString)
                }
                .onDrop(
                    of: [UTType.plainText.identifier],
                    delegate: ClipboardFilterDropDelegate(
                        destinationFilter: filter,
                        displayedFilters: $displayedFilters,
                        draggedFilter: $draggedFilter,
                        onCommit: { _ in
                            persistDisplayedFilterOrder()
                        }
                    )
                )
        } else {
            chip
        }
    }

    private var contentArea: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
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
            .padding(12)
        }
        .id(contentScrollResetID)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(contentAreaFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
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
        VStack(spacing: 12) {
            Image(systemName: showsClearSearch ? "magnifyingglass.circle" : "tray")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(colorScheme == .dark ? 0.9 : 0.7))

            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            Text(message)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if showsClearSearch {
                actionButton(title: L10n.tr("panel.clear_search")) {
                    closeSearch()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 260)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(sectionCardFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
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

            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    rowView(for: item)

                    if index < items.count - 1 {
                        rowSeparator(inset: separatorInset(after: item))
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(sectionCardFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
    }

    private func copyItemAtIndex(_ index: Int) {
        guard index >= 0, index < presentation.orderedItems.count else { return }
        let item = presentation.orderedItems[index]
        selectedID = item.id
        onCopy(item)
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
                    copySelected(item)
                }
            if item.supportsPlainTextActions {
                Button(L10n.tr("menu.copy_plain_text")) {
                    selectedID = item.id
                    onCopyPlainText(item)
                }
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
            if item.supportsPlainTextActions {
                Button(L10n.tr("menu.paste_plain_text")) {
                    selectedID = item.id
                    onPastePlainText(item)
                }
            }
            Button(item.isFavorite ? L10n.tr("menu.unfavorite") : L10n.tr("menu.favorite")) {
                selectedID = item.id
                store.toggleFavorite(for: item.id)
            }
            Button(L10n.tr("menu.delete"), role: .destructive) {
                delete(item)
            }
        }
    }

    private func copySelected(_ item: ClipboardItem) {
        onCopy(item)
    }

    private func handleRowTap(_ item: ClipboardItem) {
        pendingPrimaryAction?.cancel()
        selectedID = item.id

        guard settings.autoPasteEnabled else { return }

        let task = DispatchWorkItem {
            copySelected(item)
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

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.84))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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

private struct QuickPasteShortcuts: View {
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

private struct CopySelectionShortcut: View {
    let onCopySelected: () -> Void

    var body: some View {
        Button("") {
            onCopySelected()
        }
        .keyboardShortcut("c", modifiers: .command)
    }
}
