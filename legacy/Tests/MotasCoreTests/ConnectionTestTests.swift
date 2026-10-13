import Foundation
import Testing
@testable import MotasCore

@Test("Connection test runner summarizes normalized provider and proxy results")
func connectionTestRunnerSummarizes() async {
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    let provider = MockData.claude(remaining: 0.72, at: date)
    let proxy = MockData.nineRouter(
        health: .unreachable,
        activeTier: .unknown,
        fallbackAvailable: nil,
        at: date
    )
    let results = await ConnectorTestRunner().run([
        StaticConnector(id: "provider", displayName: "Claude Code", result: .provider(provider)),
        StaticConnector(id: "proxy", displayName: "9Router", result: .proxy(proxy)),
    ])

    #expect(results.map(\.id) == ["provider", "proxy"])
    #expect(results.first?.status == .healthy)
    #expect(results.last?.status == .unreachable)
    #expect(results.last?.quality == .fresh)
}

@Test("Connection test result is secret-free and codable")
func connectionTestResultPrivacy() throws {
    let result = ConnectionTestResult(
        id: "proxy",
        name: "Proxy",
        status: .unauthorized,
        quality: .unavailable,
        message: "Credentials were rejected; open Settings."
    )
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self).lowercased()
    #expect(!encoded.contains("token"))
    #expect(!encoded.contains("cookie"))
    #expect(encoded.contains("unauthorized"))
}
