import SwiftUI

extension ClipboardStatisticsCategory {
    var statisticsColor: Color {
        switch self {
        case .text: Color(red: 0.10, green: 0.42, blue: 0.91)
        case .image: Color(red: 0.95, green: 0.48, blue: 0.26)
        case .file: Color(red: 0.12, green: 0.62, blue: 0.55)
        case .folder: Color(red: 0.88, green: 0.64, blue: 0.16)
        case .code: Color(red: 0.53, green: 0.39, blue: 0.79)
        case .url: Color(red: 0.12, green: 0.64, blue: 0.82)
        case .email: Color(red: 0.80, green: 0.34, blue: 0.45)
        }
    }
}

struct ClipboardTrendChart: View {
    let points: [StatisticsTrendPoint]
    let isHourly: Bool
    let periodTitle: String
    let accent: Color

    @State private var hoveredDate: Date?

    private let plotHeight: CGFloat = 136

    private var hoveredPoint: StatisticsTrendPoint? {
        points.first { $0.date == hoveredDate }
    }

    private var axisMaximum: Int {
        Self.axisMaximum(for: points.map(\.count).max() ?? 0)
    }

    static func axisMaximum(for value: Int) -> Int {
        guard value > 1 else { return 1 }
        var magnitude = 1
        while value > magnitude * 10, magnitude <= Int.max / 10 {
            magnitude *= 10
        }
        return [2, 4, 10].map { $0 * magnitude }.first { $0 >= value } ?? value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 8) {
                Text(L10n.tr("stats.trend"))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if let hoveredPoint {
                    Text(dateLabel(for: hoveredPoint.date))
                        .foregroundStyle(.secondary)
                    Text(hoveredPoint.count.formatted())
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(accent)
                } else {
                    Text(periodTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .frame(height: 20)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(axisMaximum.formatted())
                    Spacer(minLength: 0)
                    if axisMaximum > 1 {
                        Text((axisMaximum / 2).formatted())
                        Spacer(minLength: 0)
                    }
                    Text("0")
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, height: plotHeight)

                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        gridLine
                        Spacer(minLength: 0)
                        if axisMaximum > 1 {
                            gridLine
                            Spacer(minLength: 0)
                        }
                        gridLine
                    }

                    HStack(alignment: .bottom, spacing: points.count > 35 ? 3 : 6) {
                        ForEach(points) { point in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: points.count > 35 ? 2 : 4)
                                    .fill(point.count == 0 ? accent.opacity(0.12) : accent.opacity(hoveredDate == point.date ? 1 : 0.78))
                                    .frame(height: max(3, plotHeight * CGFloat(point.count) / CGFloat(axisMaximum)))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredDate = point.date
                                } else if hoveredDate == point.date {
                                    hoveredDate = nil
                                }
                            }
                            .help("\(dateLabel(for: point.date)) · \(point.count.formatted())")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: plotHeight)
            }

            HStack {
                Text(points.first.map { dateLabel(for: $0.date) } ?? "")
                Spacer()
                Text(points.last.map { dateLabel(for: $0.date) } ?? "")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.leading, 44)
        }
        .onChange(of: periodTitle) { _, _ in hoveredDate = nil }
    }

    private var gridLine: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 1)
    }

    private func dateLabel(for date: Date) -> String {
        date.formatted(date: isHourly ? .omitted : .abbreviated, time: isHourly ? .shortened : .omitted)
    }
}

private struct StatisticsDonutSegment: Identifiable {
    let category: ClipboardStatisticsCategory
    let count: Int
    let start: Double
    let end: Double

    var id: ClipboardStatisticsCategory { category }
}

struct ClipboardCategoryDonut: View {
    @Environment(\.colorScheme) private var colorScheme

    let counts: [ClipboardStatisticsCategory: Int]
    let total: Int

    private var segments: [StatisticsDonutSegment] {
        guard total > 0 else { return [] }
        let categories = ClipboardStatisticsCategory.allCases
            .filter { (counts[$0] ?? 0) > 0 }
            .sorted { (counts[$0] ?? 0) == (counts[$1] ?? 0) ? $0.rawValue < $1.rawValue : (counts[$0] ?? 0) > (counts[$1] ?? 0) }
        var start = 0.0
        return categories.map { category in
            let count = counts[category] ?? 0
            let end = start + Double(count) / Double(total)
            defer { start = end }
            return StatisticsDonutSegment(category: category, count: count, start: start, end: end)
        }
    }

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.09), lineWidth: 25)
                ForEach(segments) { segment in
                    Circle()
                        .trim(from: segment.start, to: segment.end)
                        .stroke(segment.category.statisticsColor, style: StrokeStyle(lineWidth: 25, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 3) {
                    Text(total.formatted())
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(L10n.tr("stats.total"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 166, height: 166)
            .padding(12)
            .accessibilityLabel(L10n.tr("stats.breakdown"))
            .accessibilityValue(total.formatted())

            VStack(alignment: .leading, spacing: 8) {
                if segments.isEmpty {
                    Text(L10n.tr("stats.no_data"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(segments) { segment in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(segment.category.statisticsColor)
                                .frame(width: 9, height: 9)
                            Text(segment.category.filter.title)
                            Spacer(minLength: 10)
                            Text((Double(segment.count) / Double(total)).formatted(.percent.precision(.fractionLength(1))))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : .white, in: RoundedRectangle(cornerRadius: 20))
    }
}
