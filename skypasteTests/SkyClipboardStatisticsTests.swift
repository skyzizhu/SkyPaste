import Foundation
import Testing
@testable import SkyPaste

@Suite("Clipboard statistics")
struct ClipboardStatisticsTests {
    @Test func trendAxisUsesReadableIntegerTicks() {
        #expect(ClipboardTrendChart.axisMaximum(for: 0) == 1)
        #expect(ClipboardTrendChart.axisMaximum(for: 1) == 1)
        #expect(ClipboardTrendChart.axisMaximum(for: 3) == 4)
        #expect(ClipboardTrendChart.axisMaximum(for: 11) == 20)
        #expect(ClipboardTrendChart.axisMaximum(for: 72) == 100)
    }

    @Test func categoriesAreExclusive() {
        let imageFile = ClipboardItem(
            content: .fileURLs(urls: [URL(fileURLWithPath: "/tmp/sky-statistics-image.png")], pasteboardPayload: nil),
            fingerprint: "image-file"
        )
        let image = ClipboardItem(content: .image(data: Data([1]), name: nil, originalByteCount: 1, previewOnly: false), fingerprint: "image")
        let email = ClipboardItem(content: .text("hello@example.com"), fingerprint: "email")

        #expect(ClipboardStatisticsCategory(item: imageFile) == .file)
        #expect(ClipboardStatisticsCategory(item: image) == .image)
        #expect(ClipboardStatisticsCategory(item: email) == .email)
    }

    @Test func countsSurviveReopeningAndUseDayAndHourBuckets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkyPasteStats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("statistics.sqlite")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = calendar.startOfDay(for: Date()).addingTimeInterval(10 * 3_600)
        let second = first.addingTimeInterval(3_600)
        let items = [first, second].enumerated().map { index, date in
            ClipboardItem(id: UUID(), createdAt: date, content: .text("item \(index)"), fingerprint: "item-\(index)")
        }

        do {
            let statistics = try ClipboardStatisticsStore(fileURL: url)
            for item in items { try statistics.record(item, calendar: calendar) }
        }

        let reopened = try ClipboardStatisticsStore(fileURL: url)
        let day = calendar.startOfDay(for: first)
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        let daily = try reopened.dailyEntries(from: day, to: end)
        let hourly = try reopened.hourlyEntries(from: day, to: end)

        #expect(daily.reduce(0) { $0 + $1.count } == 2)
        #expect(hourly.reduce(0) { $0 + $1.count } == 2)
        #expect(Set(hourly.map(\.bucket)).count == 2)
    }

    @Test func retainedHistorySeedsAnEmptyStatisticsDatabaseOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkyPasteStats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let statistics = try ClipboardStatisticsStore(fileURL: directory.appendingPathComponent("statistics.sqlite"))
        let item = ClipboardItem(content: .text("retained"), fingerprint: "retained")
        try statistics.seedRetainedHistoryIfNeeded([item])
        try statistics.seedRetainedHistoryIfNeeded([item])

        let day = Calendar.current.startOfDay(for: item.createdAt)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        #expect(try statistics.dailyEntries(from: day, to: end).reduce(0) { $0 + $1.count } == 1)
    }

    @Test func existingCountsOnlyBackfillEarlierDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkyPasteStats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let statistics = try ClipboardStatisticsStore(fileURL: directory.appendingPathComponent("statistics.sqlite"))
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let recent = ClipboardItem(id: UUID(), createdAt: today, content: .text("new"), fingerprint: "new")
        let retained = ClipboardItem(id: UUID(), createdAt: yesterday, content: .text("old"), fingerprint: "old")
        try statistics.record(recent)
        try statistics.seedRetainedHistoryIfNeeded([recent, retained])

        let end = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        #expect(try statistics.dailyEntries(from: yesterday, to: end).reduce(0) { $0 + $1.count } == 2)
    }

    @Test func backgroundReadOnlyConnectionSeesCommittedCounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkyPasteStats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("statistics.sqlite")
        let writer = try ClipboardStatisticsStore(fileURL: url)
        let item = ClipboardItem(content: .text("async read"), fingerprint: "async-read")
        try writer.record(item)

        let day = Calendar.current.startOfDay(for: item.createdAt)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let count = try await Task.detached {
            let reader = try ClipboardStatisticsStore(fileURL: url, readOnly: true)
            return try reader.dailyEntries(from: day, to: end).reduce(0) { $0 + $1.count }
        }.value

        #expect(count == 1)
    }

    @Test func sourceAppsAggregateByBundleIDWithinSelectedDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkyPasteStats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let statistics = try ClipboardStatisticsStore(fileURL: directory.appendingPathComponent("statistics.sqlite"))
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let appA = ClipboardSourceApp(bundleID: "test.app.a", name: "App A")
        let appB = ClipboardSourceApp(bundleID: "test.app.b", name: "App B")
        func item(_ date: Date, _ app: ClipboardSourceApp?, source: ClipboardSource = .local) -> ClipboardItem {
            ClipboardItem(id: UUID(), createdAt: date, content: .text(UUID().uuidString), fingerprint: UUID().uuidString, source: source, sourceApp: app)
        }
        try statistics.record(item(yesterday, appA))
        try statistics.record(item(today, appA))
        try statistics.record(item(today, appB))
        try statistics.record(item(today, nil))
        try statistics.record(item(today, appA, source: .cloudKit))

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let todayApps = try statistics.appEntries(from: today, to: tomorrow)
        #expect(todayApps.map(\.bundleID) == [appA.bundleID, appB.bundleID])
        #expect(todayApps.map(\.count) == [1, 1])
        let twoDayApps = try statistics.appEntries(from: yesterday, to: tomorrow)
        #expect(twoDayApps.map(\.count) == [2, 1])
    }

    @Test func retainedSourceAppsSeedOnceWithoutDuplicatingExistingCounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SkyPasteStats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let statistics = try ClipboardStatisticsStore(fileURL: directory.appendingPathComponent("statistics.sqlite"))
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let app = ClipboardSourceApp(bundleID: "test.app", name: "Test App")
        let recent = ClipboardItem(id: UUID(), createdAt: today, content: .text("recent"), fingerprint: "recent", sourceApp: app)
        let retained = ClipboardItem(id: UUID(), createdAt: yesterday, content: .text("retained"), fingerprint: "retained", sourceApp: app)
        try statistics.record(recent)
        try statistics.seedRetainedHistoryIfNeeded([recent, retained])
        try statistics.seedRetainedHistoryIfNeeded([recent, retained])

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        #expect(try statistics.appEntries(from: yesterday, to: tomorrow).first?.count == 2)
    }
}
