import SwiftUI

private enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case halfYear
    case year

    var id: String { rawValue }
    var title: String { L10n.tr("stats.period.\(rawValue)") }
    var isHourly: Bool { self == .today }

    func start(for now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .halfYear: return calendar.date(byAdding: .month, value: -6, to: today) ?? today
        case .year: return calendar.date(byAdding: .year, value: -1, to: today) ?? today
        }
    }

    func bucketStart(for date: Date, calendar: Calendar) -> Date {
        switch self {
        case .today:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .week, .month:
            return calendar.startOfDay(for: date)
        case .halfYear:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        case .year:
            return calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
    }

    func nextBucket(after date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .today: return calendar.date(byAdding: .hour, value: 1, to: date)
        case .week, .month: return calendar.date(byAdding: .day, value: 1, to: date)
        case .halfYear: return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .year: return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }
}

struct StatisticsTrendPoint: Identifiable, Sendable {
    let date: Date
    let count: Int
    var id: Date { date }
}

private struct StatisticsSnapshot: Sendable {
    let total: Int
    let categoryCounts: [ClipboardStatisticsCategory: Int]
    let trend: [StatisticsTrendPoint]
    let appCounts: [ClipboardStatisticsAppEntry]

    var leadingCategory: ClipboardStatisticsCategory? {
        ClipboardStatisticsCategory.allCases.max {
            (categoryCounts[$0] ?? 0) < (categoryCounts[$1] ?? 0)
        }.flatMap { (categoryCounts[$0] ?? 0) > 0 ? $0 : nil }
    }

    static func loadAll(from fileURL: URL) throws -> [StatisticsPeriod: StatisticsSnapshot] {
        let database = try ClipboardStatisticsStore(fileURL: fileURL, readOnly: true)
        let now = Date()
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let daily = try database.dailyEntries(from: StatisticsPeriod.year.start(for: now, calendar: calendar), to: end)
        let hourly = try database.hourlyEntries(from: StatisticsPeriod.today.start(for: now, calendar: calendar), to: end)

        return try Dictionary(uniqueKeysWithValues: StatisticsPeriod.allCases.map { period in
            let entries = period.isHourly ? hourly : daily
            let apps = try database.appEntries(from: period.start(for: now, calendar: calendar), to: end)
            return (period, make(entries: entries, appCounts: apps, period: period, now: now, calendar: calendar))
        })
    }

    private static func make(entries: [ClipboardStatisticsEntry], appCounts: [ClipboardStatisticsAppEntry], period: StatisticsPeriod, now: Date, calendar: Calendar) -> Self {
        let start = period.start(for: now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let trendEnd = period.isHourly ? now.addingTimeInterval(1) : end
        let includedEntries = entries.filter { $0.bucket >= start && $0.bucket < end }
        var categoryCounts: [ClipboardStatisticsCategory: Int] = [:]
        var bucketCounts: [Date: Int] = [:]

        for entry in includedEntries {
            categoryCounts[entry.category, default: 0] += entry.count
            bucketCounts[period.bucketStart(for: entry.bucket, calendar: calendar), default: 0] += entry.count
        }

        var trend: [StatisticsTrendPoint] = []
        var cursor = period.bucketStart(for: start, calendar: calendar)
        while cursor < trendEnd, trend.count < 60 {
            trend.append(StatisticsTrendPoint(date: cursor, count: bucketCounts[cursor] ?? 0))
            guard let next = period.nextBucket(after: cursor, calendar: calendar), next > cursor else { break }
            cursor = next
        }

        return StatisticsSnapshot(
            total: includedEntries.reduce(0) { $0 + $1.count },
            categoryCounts: categoryCounts,
            trend: trend,
            appCounts: appCounts
        )
    }
}

struct ClipboardStatisticsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: ClipboardStore
    @State private var period: StatisticsPeriod = .week
    @State private var snapshots: [StatisticsPeriod: StatisticsSnapshot] = [:]
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var reloadGeneration = 0
    @State private var dayClockRevision = 0

    private let accent = Color(red: 0.08, green: 0.42, blue: 0.94)
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading
                periodPicker

                if let snapshot = snapshots[period] {
                    overview(snapshot)
                    trendCard(snapshot)
                    categorySection(snapshot)
                    appSection(snapshot)
                } else if isLoading {
                    ProgressView(L10n.tr("stats.loading"))
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if loadFailed {
                    Text(L10n.tr("stats.load_failed"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220)
                }

                Text(L10n.tr("stats.note"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(nsColor: .windowBackgroundColor), Color(red: 0.09, green: 0.12, blue: 0.18)]
                    : [Color(red: 0.97, green: 0.98, blue: 1), Color(red: 0.93, green: 0.96, blue: 1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .task(id: store.statisticsRevision) { await reload() }
        .task(id: dayClockRevision) { await refreshAtDayBoundaries() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            dayClockRevision &+= 1
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
            dayClockRevision &+= 1
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            dayClockRevision &+= 1
            Task { await reload() }
        }
    }

    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr("stats.title"))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(L10n.tr("stats.subtitle"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 52, height: 52)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 17))
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 5) {
            ForEach(StatisticsPeriod.allCases) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { period = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: period == option ? .semibold : .medium))
                        .foregroundStyle(period == option ? Color.white : Color.primary.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(period == option ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14))
    }

    private func overview(_ snapshot: StatisticsSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("stats.total"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                Text(snapshot.total.formatted())
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                Text(period.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
            }
            .padding(23)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 156, alignment: .topLeading)
            .background(
                LinearGradient(colors: [Color(red: 0.06, green: 0.20, blue: 0.42), accent], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20)
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("stats.top_category"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let category = snapshot.leadingCategory {
                    Image(systemName: category.filter.symbolSystemName ?? "doc")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(category.filter.title)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text((snapshot.categoryCounts[category] ?? 0).formatted())
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("stats.no_data"))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(23)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 156, alignment: .topLeading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func trendCard(_ snapshot: StatisticsSnapshot) -> some View {
        ClipboardTrendChart(points: snapshot.trend, isHourly: period.isHourly, periodTitle: period.title, accent: accent)
            .padding(20)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 20))
    }

    private func categorySection(_ snapshot: StatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("stats.breakdown"))
                .font(.system(size: 16, weight: .semibold))

            ClipboardCategoryDonut(counts: snapshot.categoryCounts, total: snapshot.total)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ClipboardStatisticsCategory.allCases) { category in
                    let count = snapshot.categoryCounts[category] ?? 0
                    HStack(spacing: 12) {
                        Image(systemName: category.filter.symbolSystemName ?? "doc")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(category.statisticsColor)
                            .frame(width: 36, height: 36)
                            .background(category.statisticsColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(category.filter.title)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(count.formatted())
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(category.statisticsColor.opacity(0.12))
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(category.statisticsColor)
                                            .frame(width: snapshot.total == 0 ? 0 : geometry.size.width * CGFloat(count) / CGFloat(snapshot.total))
                                    }
                            }
                            .frame(height: 4)
                        }
                    }
                    .padding(14)
                    .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private func appSection(_ snapshot: StatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr("stats.apps.title"))
                    .font(.system(size: 16, weight: .semibold))
                Text(L10n.tr("stats.apps.note"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if snapshot.appCounts.isEmpty {
                Text(L10n.tr("stats.apps.empty"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
            } else {
                let appTotal = snapshot.appCounts.reduce(0) { $0 + $1.count }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(snapshot.appCounts, id: \.bundleID) { app in
                        HStack(spacing: 12) {
                            StatisticsAppIcon(bundleID: app.bundleID, name: app.name)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("\(Int((Double(app.count) / Double(appTotal) * 100).rounded()))%")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(app.count.formatted())
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }

        }
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : .white
    }

    @MainActor
    private func refreshAtDayBoundaries() async {
        while !Task.isCancelled {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { return }
            do {
                try await Task.sleep(for: .seconds(max(1, nextDay.timeIntervalSinceNow + 0.5)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        guard let fileURL = store.statisticsDatabaseURL else {
            isLoading = false
            loadFailed = true
            return
        }

        isLoading = snapshots.isEmpty
        loadFailed = false
        let query = Task.detached(priority: .userInitiated) {
            try StatisticsSnapshot.loadAll(from: fileURL)
        }
        let result = await withTaskCancellationHandler {
            await query.result
        } onCancel: {
            query.cancel()
        }
        guard !Task.isCancelled, generation == reloadGeneration else { return }

        switch result {
        case .success(let loaded):
            snapshots = loaded
            isLoading = false
        case .failure(let error):
            print("[ClipboardStatisticsView] Failed to load statistics: \(error)")
            isLoading = false
            loadFailed = true
        }
    }
}

private struct StatisticsAppIcon: View {
    let bundleID: String
    let name: String
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
                    .padding(5)
            }
        }
        .frame(width: 28, height: 28)
        .task(id: bundleID) {
            icon = nil
            ClipboardSourceAppIconProvider.shared.loadIcon(for: ClipboardSourceApp(bundleID: bundleID, name: name)) { loaded in
                icon = loaded
            }
        }
    }
}
