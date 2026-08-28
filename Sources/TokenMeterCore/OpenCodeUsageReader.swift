import Foundation
import SQLite3

/// opencode의 SQLite 저장소에서 어시스턴트 응답별 토큰과 기록 비용을 읽습니다.
///
/// opencode는 `~/.local/share/opencode/opencode.db`(XDG_DATA_HOME 설정 시 그 하위)의
/// `message` 테이블에 응답마다 `tokens`와 `cost`를 JSON으로 기록합니다. 구독 한도가
/// 없으므로 사용량 집계에만 쓰입니다.
public struct OpenCodeUsageReader {
    private let databaseURL: URL?

    public init(
        databaseURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? homeDirectory.appending(path: ".local/share", directoryHint: .isDirectory)
            self.databaseURL = dataHome.appending(path: "opencode/opencode.db", directoryHint: .notDirectory)
        }
    }

    /// 읽기 전용으로 열어 events를 모읍니다. DB가 없으면 빈 결과를 돌려주고,
    /// 읽기에 실패하면 skippedCount를 1로 돌려줍니다.
    public func read() -> (events: [UsageEvent], skippedCount: Int) {
        guard let databaseURL, FileManager.default.fileExists(atPath: databaseURL.path) else {
            return ([], 0)
        }

        var database: OpaquePointer?
        guard
            sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
                nil
            ) == SQLITE_OK,
            let database
        else {
            sqlite3_close(database)
            return ([], 1)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let query = """
        SELECT json_extract(data, '$.tokens.input'),
               json_extract(data, '$.tokens.cache.read'),
               json_extract(data, '$.tokens.cache.write'),
               json_extract(data, '$.tokens.output'),
               json_extract(data, '$.tokens.reasoning'),
               json_extract(data, '$.cost'),
               time_created
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            // opencode 구버전 등 테이블이 아예 없으면 오류가 아니라 빈 값으로 본다.
            let message = String(cString: sqlite3_errmsg(database)).lowercased()
            return ([], Self.isMissingTable(message) ? 0 : 1)
        }
        defer { sqlite3_finalize(statement) }

        var events: [UsageEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let input = columnInt64(statement, 0)
            let cachedRead = columnInt64(statement, 1)
            let cachedWrite = columnInt64(statement, 2)
            let output = columnInt64(statement, 3)
            let reasoning = columnInt64(statement, 4)
            let cost = columnDouble(statement, 5)
            let createdMilliseconds = columnInt64(statement, 6)

            // reasoning과 캐시는 input·output에 포함되지 않는 별도 값이므로 모두 더한다.
            let total = input + cachedRead + cachedWrite + output + reasoning
            guard total > 0 else { continue }

            events.append(UsageEvent(
                provider: .opencode,
                date: Date(timeIntervalSince1970: Double(createdMilliseconds) / 1000),
                usage: TokenUsage(
                    input: input,
                    cachedRead: cachedRead,
                    cachedWrite: cachedWrite,
                    output: output,
                    total: total
                ),
                cost: cost
            ))
        }
        return (events, 0)
    }

    private func columnInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64 {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? 0 : sqlite3_column_int64(statement, index)
    }

    private func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? 0 : sqlite3_column_double(statement, index)
    }

    private static func isMissingTable(_ message: String) -> Bool {
        message.contains("no such table")
    }
}
