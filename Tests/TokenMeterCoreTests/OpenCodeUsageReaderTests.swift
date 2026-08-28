import XCTest
@testable import TokenMeterCore

final class OpenCodeUsageReaderTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "token-meter-tests-\(UUID().uuidString).db")
        try createFixtureDatabase(at: databaseURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: databaseURL)
    }

    func testReadsAssistantTokenUsageAndCost() throws {
        let (events, skippedCount) = OpenCodeUsageReader(databaseURL: databaseURL).read()

        XCTAssertEqual(skippedCount, 0)
        XCTAssertEqual(events.count, 2)

        let first = try XCTUnwrap(events.first { $0.usage.input == 3_828 })
        XCTAssertEqual(first.provider, .opencode)
        XCTAssertEqual(first.usage.output, 73)
        XCTAssertEqual(first.usage.cachedRead, 9_216)
        XCTAssertEqual(first.usage.cachedWrite, 0)
        // reasoning(87)은 input·output에 포함되지 않으므로 total에 더해진다.
        XCTAssertEqual(first.usage.total, 3_828 + 73 + 87 + 9_216)
        XCTAssertEqual(first.cost, 0.0006542, accuracy: 1e-12)
        XCTAssertEqual(
            Int64(first.date.timeIntervalSince1970 * 1000),
            1_787_817_540_263
        )

        let second = try XCTUnwrap(events.first { $0.usage.input == 100 })
        XCTAssertEqual(second.usage.total, 100 + 25)
        XCTAssertEqual(second.cost, 0, accuracy: 1e-12)
    }

    func testSkipsZeroUsageAssistantMessages() throws {
        let (events, _) = OpenCodeUsageReader(databaseURL: databaseURL).read()
        // data에 tokens가 전부 0인 응답과 user 메시지는 세지 않는다.
        XCTAssertFalse(events.contains { $0.usage.total == 0 })
        XCTAssertEqual(events.count, 2)
    }

    func testReturnsEmptyWhenDatabaseIsMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "token-meter-missing-\(UUID().uuidString).db")
        let (events, skippedCount) = OpenCodeUsageReader(databaseURL: missing).read()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(skippedCount, 0)
    }

    func testReportAggregatesCostPerProvider() {
        let date = Date(timeIntervalSince1970: 1_787_817_540)
        let report = UsageReport(events: [
            UsageEvent(
                provider: .opencode,
                date: date,
                usage: TokenUsage(input: 10, output: 5, total: 15),
                cost: 0.25
            ),
            UsageEvent(
                provider: .codex,
                date: date,
                usage: TokenUsage(input: 10, output: 5, total: 15)
            ),
        ])

        let summary = report.summary(for: .opencode)
        XCTAssertEqual(summary.cost, 0.25, accuracy: 1e-12)
        XCTAssertEqual(report.summary(for: .codex).cost, 0, accuracy: 1e-12)
        XCTAssertEqual(report.combinedCost(), 0.25, accuracy: 1e-12)
    }

    private func createFixtureDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            XCTFail("fixture DB를 만들지 못했습니다")
            return
        }
        defer { sqlite3_close(database) }

        let schema = """
        CREATE TABLE message (
            id text PRIMARY KEY,
            session_id text NOT NULL,
            time_created integer NOT NULL,
            time_updated integer NOT NULL,
            data text NOT NULL
        );
        """
        exec(database, schema)

        func insert(_ id: String, _ timeCreated: Int64, _ data: String) {
            var statement: OpaquePointer?
            let sql = "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, 's1', ?, ?, ?)"
            sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 2, timeCreated)
            sqlite3_bind_int64(statement, 3, timeCreated)
            sqlite3_bind_text(statement, 4, data, -1, SQLITE_TRANSIENT)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        insert(
            "m1", 1_787_817_540_263,
            #"{"role":"assistant","providerID":"baseten","modelID":"zai-org/GLM-5.3-Flash","cost":0.0006542,"tokens":{"input":3828,"output":73,"reasoning":87,"cache":{"read":9216,"write":0}},"time":{"created":1787817540263}}"#
        )
        insert(
            "m2", 1_787_817_541_000,
            #"{"role":"assistant","providerID":"openrouter","modelID":"stealth/ox-alpha","cost":0,"tokens":{"input":100,"output":25,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1787817541000}}"#
        )
        insert(
            "m3", 1_787_817_542_000,
            #"{"role":"assistant","providerID":"baseten","modelID":"zai-org/GLM-5.3-Flash","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1787817542000}}"#
        )
        insert(
            "m4", 1_787_817_543_000,
            #"{"role":"user","providerID":"baseten","modelID":"zai-org/GLM-5.3-Flash","cost":0,"tokens":{"input":99999,"output":99999,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1787817543000}}"#
        )
        insert(
            "m5", 1_787_817_544_000,
            #"{"role":"assistant","providerID":"baseten","modelID":"zai-org/GLM-5.3-Flash","cost":0.5,"time":{"created":1787817544000}}"#
        )
    }

    private func exec(_ database: OpaquePointer?, _ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            XCTFail("SQL 실행 실패: \(error.map { String(cString: $0) } ?? "?")")
            if let error { sqlite3_free(error) }
            return
        }
    }
}
