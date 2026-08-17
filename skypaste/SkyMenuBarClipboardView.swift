import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

        static let empty = Presentation(favoriteItems: [], orderedItems: [], daySections: [])
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
    let onOpenEmail: (ClipboardItem) -> Void
    let onOpenPanel: () -> Void
    let onOpenPreferences: () -> Void
    let onQuit: () -> Void

    @State private var selectedID: ClipboardItem.ID?
    @State private var pendingDeleteDay: Date?
    @State private var selectedFilter: ClipboardFilter = .all
    @State private var isSearchVisible = false
    @State private var pendingPrimaryAction: DispatchWorkItem?
    @State private var draggedFilter: ClipboardFilter?
    @State private var displayedFilters = ClipboardFilter.defaultDisplayOrder
    @State private var sourceSelection: ClipboardSourceSelection = .allApps
    @State private var sourceAppIcons: [String: NSImage] = [:]
    @State private var presentation = Presentation.empty
    @State private var rowAnchors: [ClipboardItem.ID: ClipboardRowAnchor] = [:]
    @State private var pendingSourceAppIconLoad: DispatchWorkItem?

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

    private func selectFilter(_ filter: ClipboardFilter) {
        guard selectedFilter != filter else { return }
        selectedFilter = filter
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
            filteredItems: selectedFilter == .favorites
                ? filteredItemsForSelectedScope
                : Array(filteredItemsForSelectedScope.prefix(80)),
            selectedFilter: selectedFilter
        )
    }

    private func delete(_ item: ClipboardItem) {
        pendingPrimaryAction?.cancel()
        store.deleteItem(item.id)
        refreshPresentation()
        selectedID = presentation.orderedItems.first?.id
    }

    private func share(_ item: ClipboardItem) {
        selectedID = item.id
        DispatchQueue.main.async {
            ClipboardSharingService.presentPicker(
                for: store.itemForPreview(item),
                relativeTo: rowAnchors[item.id]?.view
            )
        }
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

        let calendar = Calendar.current
        var daySections: [DaySection] = []
        var currentDay: Date?
        var currentItems: [ClipboardItem] = []

        for item in daySource {
            let day = calendar.startOfDay(for: item.createdAt)
            if let currentDay, currentDay != day {
                daySections.append(DaySection(day: currentDay, items: currentItems))
                currentItems.removeAll(keepingCapacity: true)
            }

            currentDay = day
            currentItems.append(item)
        }

        if let currentDay {
            daySections.append(DaySection(day: currentDay, items: currentItems))
        }

        return Presentation(
            favoriteItems: favoriteItems,
            orderedItems: filteredItems,
            daySections: daySections
        )
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
        "\(selectedFilter.id)|\(store.appliedSearchText)|\(sourceSelection.cacheKey)"
    }

    private var baseItemsForSelectedFilter: [ClipboardItem] {
        store.items(for: selectedFilter)
    }

    private var availableSourceAppOptions: [ClipboardSourceAppOption] {
        store.sourceAppOptions(for: selectedFilter)
    }

    private var hasPhoneSourceItems: Bool {
        baseItemsForSelectedFilter.contains { $0.source.isDeviceSynced }
    }

    private var filteredItemsForSelectedScope: [ClipboardItem] {
        baseItemsForSelectedFilter.filter(sourceSelection.matches)
    }

    private func validateSourceAppSelection() {
        switch sourceSelection {
        case .allApps:
            return
        case .phone:
            if !hasPhoneSourceItems {
                sourceSelection = .allApps
            }
        case .app(let bundleID):
            if !availableSourceAppOptions.contains(where: { $0.bundleID == bundleID }) {
                sourceSelection = .allApps
            }
        }
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
        .overlay {
            if let pendingDeleteDay {
                deleteDayConfirmationOverlay(for: pendingDeleteDay)
            }
        }
        .onAppear {
            displayedFilters = settings.orderedFilters
            refreshPresentation()
            selectedID = presentation.orderedItems.first?.id
            isSearchVisible = !store.appliedSearchText.isEmpty
            loadSourceAppIconsSoon()
        }
        .onReceive(store.$items) { _ in
            validateSourceAppSelection()
            refreshPresentation()
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
        .onChange(of: sourceSelection) { _, _ in
            refreshPresentation()
            selectedID = presentation.orderedItems.first?.id
        }
        .onChange(of: availableSourceAppOptions.map(\.bundleID)) { _, _ in
            loadSourceAppIconsSoon()
        }
    }

    private func deleteDayConfirmationOverlay(for day: Date) -> some View {
        ZStack {
            Color.black
                .opacity(colorScheme == .dark ? 0.32 : 0.14)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissDeleteConfirmation()
                }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("menu.delete_day_title"))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)

                Text(L10n.format("menu.delete_day_message", L10n.sectionTitle(for: day)))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Spacer()
                    confirmationButton(title: L10n.tr("menu.cancel"), role: .cancel) {
                        dismissDeleteConfirmation()
                    }
                    confirmationButton(title: L10n.tr("menu.delete"), role: .destructive) {
                        dismissDeleteConfirmation()
                        DispatchQueue.main.async {
                            store.deleteAllItems(onDay: day)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(width: 336)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(deleteConfirmationCardTint)
                    }
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.40 : 0.14), radius: 22, y: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
            }
        }
        .zIndex(50)
    }

    private func dismissDeleteConfirmation() {
        // Avoid an animated removal here: a fading overlay can keep intercepting clicks in popovers.
        pendingDeleteDay = nil
    }

    private var deleteConfirmationCardTint: Color {
        colorScheme == .dark
            ? Color(nsColor: .controlBackgroundColor).opacity(0.74)
            : Color(nsColor: .windowBackgroundColor).opacity(0.88)
    }

    private func confirmationButton(title: String, role: ButtonRole?, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(role == .destructive ? Color(nsColor: .systemRed) : Color.primary.opacity(0.84))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(role == .destructive ? Color(nsColor: .systemRed).opacity(colorScheme == .dark ? 0.20 : 0.10) : actionButtonFill)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(role == .destructive ? Color(nsColor: .systemRed).opacity(0.18) : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
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

    private var sourceAppFilterTitle: String {
        switch sourceSelection {
        case .allApps:
            return L10n.tr("filter.source_label")
        case .phone:
            return L10n.tr("filter.source_phone")
        case .app(let bundleID):
            return availableSourceAppOptions.first(where: { $0.bundleID == bundleID })?.name
                ?? L10n.tr("filter.source_label")
        }
    }

    private var selectedSourceAppOption: ClipboardSourceAppOption? {
        guard case .app(let bundleID) = sourceSelection else { return nil }
        return availableSourceAppOptions.first(where: { $0.bundleID == bundleID })
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
        HStack(spacing: 8) {
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
            sourceAppMenu
        }
    }

    private var sourceAppMenu: some View {
        let isActive = sourceSelection != .allApps

        return Menu {
            Button {
                withAnimation(.easeOut(duration: 0.1)) {
                    sourceSelection = .allApps
                }
            } label: {
                HStack(spacing: 8) {
                    sourceAppMenuIcon(bundleID: nil, size: 13)
                    Text(L10n.tr("filter.source_all"))
                    if sourceSelection == .allApps {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button {
                withAnimation(.easeOut(duration: 0.1)) {
                    sourceSelection = .phone
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 13, height: 13)
                    Text(L10n.tr("filter.source_phone"))
                    if sourceSelection == .phone {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            .disabled(!hasPhoneSourceItems)

            if !availableSourceAppOptions.isEmpty {
                Divider()

                ForEach(availableSourceAppOptions) { app in
                    Button {
                        withAnimation(.easeOut(duration: 0.1)) {
                            sourceSelection = .app(bundleID: app.bundleID)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            sourceAppMenuIcon(bundleID: app.bundleID, size: 13)
                            Text(app.name)
                            if sourceSelection == .app(bundleID: app.bundleID) {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            sourceAppButtonIcon(size: 15)
            .foregroundStyle(isActive ? selectedFilterChipText : Color.primary.opacity(colorScheme == .dark ? 0.82 : 0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
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
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help(selectedSourceAppOption?.name ?? sourceAppFilterTitle)
    }

    @ViewBuilder
    private func sourceAppButtonIcon(size: CGFloat) -> some View {
        if sourceSelection == .phone {
            Image(systemName: "iphone.gen3")
                .font(.system(size: size - 2, weight: .semibold))
        } else if let selectedSourceAppOption, let icon = sourceAppIcons[selectedSourceAppOption.bundleID] {
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

    private func loadSourceAppIconsSoon() {
        pendingSourceAppIconLoad?.cancel()
        let task = DispatchWorkItem {
            loadSourceAppIconsIfNeeded()
        }
        pendingSourceAppIconLoad = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
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
        ScrollViewReader { proxy in
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
                .id("content-top")
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: contentScrollResetID) { _, _ in
                proxy.scrollTo("content-top", anchor: .top)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(contentAreaFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transaction { transaction in
            transaction.animation = nil
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

            LazyVStack(spacing: 0) {
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
            onAnchorViewChange: { view in
                DispatchQueue.main.async {
                    if let view {
                        rowAnchors[item.id] = ClipboardRowAnchor(view)
                    } else {
                        rowAnchors[item.id] = nil
                    }
                }
            },
            onResolveDragItem: { item in
                store.itemForPreview(item)
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
            Button {
                selectedID = item.id
                copy(item)
            } label: {
                Label(L10n.tr("menu.copy"), systemImage: "doc.on.doc")
            }
            if item.supportsSharing {
                Button {
                    share(item)
                } label: {
                    Label(L10n.tr("menu.share"), systemImage: "square.and.arrow.up")
                }
            }
            if item.isFileCollection {
                Button {
                    selectedID = item.id
                    onOpenFileItem(item)
                } label: {
                    Label(
                        item.openActionTitle,
                        systemImage: item.singleFileSystemItemKind == .folder ? "folder" : "doc"
                    )
                }
            }
            if item.isSingleFile {
                Button {
                    selectedID = item.id
                    onOpenContainingFolder(item)
                } label: {
                    Label(L10n.tr("menu.reveal_in_finder"), systemImage: "folder.badge.gearshape")
                }
            }
            if item.isFileCollection {
                Button {
                    selectedID = item.id
                    onCopyFileSystemPath(item)
                } label: {
                    Label(L10n.tr("menu.copy_path"), systemImage: "text.alignleft")
                }
            }
            if item.isURL {
                Button {
                    selectedID = item.id
                    onOpenURL(item)
                } label: {
                    Label(L10n.tr("menu.open_in_browser"), systemImage: "safari")
                }
            }
            if item.isEmail {
                Button {
                    selectedID = item.id
                    onOpenEmail(item)
                } label: {
                    Label(L10n.tr("menu.open_email"), systemImage: "envelope")
                }
            }
            if item.isImage {
                Button {
                    selectedID = item.id
                    onPreview(item)
                } label: {
                    Label(L10n.tr("preview.open"), systemImage: "photo")
                }
            }
            if item.supportsTextPreview {
                Button {
                    selectedID = item.id
                    onTextPreview(item)
                } label: {
                    Label(L10n.tr("preview.text_open"), systemImage: "text.viewfinder")
                }
            }
            Button {
                selectedID = item.id
                store.toggleFavorite(for: item.id)
                refreshPresentation()
            } label: {
                Label(
                    item.isFavorite ? L10n.tr("menu.unfavorite") : L10n.tr("menu.favorite"),
                    systemImage: item.isFavorite ? "star.slash" : "star"
                )
            }
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label(L10n.tr("menu.delete"), systemImage: "trash")
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
