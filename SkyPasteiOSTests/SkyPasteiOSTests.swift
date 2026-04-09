//
//  SkyPasteiOSTests.swift
//  SkyPasteiOSTests
//
//  Created by fushan on 2026/4/8.
//

import Testing
@testable import SkyPasteiOS

struct SkyPasteiOSTests {
    @Test func cloudClipboardRecordNameIsStablePerFingerprint() {
        let first = CloudClipboardSchema.recordName(for: "txt:https://example.com")
        let second = CloudClipboardSchema.recordName(for: "txt:https://example.com")
        let different = CloudClipboardSchema.recordName(for: "txt:https://openai.com")

        #expect(first == second)
        #expect(first != different)
        #expect(first.hasPrefix("clip-"))
    }
}
