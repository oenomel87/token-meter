import Foundation

public enum Provider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude
    case opencode

    public var id: String { rawValue }
}

public struct TokenUsage: Equatable, Sendable {
    public var input: Int64 = 0
    public var cachedRead: Int64 = 0
    public var cachedWrite: Int64 = 0
    public var output: Int64 = 0
    public var total: Int64 = 0

    public init(
        input: Int64 = 0,
        cachedRead: Int64 = 0,
        cachedWrite: Int64 = 0,
        output: Int64 = 0,
        total: Int64 = 0
    ) {
        self.input = input
        self.cachedRead = cachedRead
        self.cachedWrite = cachedWrite
        self.output = output
        self.total = total
    }

    public static let zero = TokenUsage()

    public mutating func add(_ other: TokenUsage) {
        input += other.input
        cachedRead += other.cachedRead
        cachedWrite += other.cachedWrite
        output += other.output
        total += other.total
    }
}

public struct UsageEvent: Sendable {
    public let provider: Provider
    public let date: Date
    public let usage: TokenUsage
    /// Provider가 기록한 비용(달러). 기록이 없으면 0.
    public let cost: Double

    public init(provider: Provider, date: Date, usage: TokenUsage, cost: Double = 0) {
        self.provider = provider
        self.date = date
        self.usage = usage
        self.cost = cost
    }
}

public struct ProviderSummary: Sendable {
    public let provider: Provider
    public var usage: TokenUsage
    public var eventCount: Int
    public var cost: Double

    public init(provider: Provider, usage: TokenUsage = .zero, eventCount: Int = 0, cost: Double = 0) {
        self.provider = provider
        self.usage = usage
        self.eventCount = eventCount
        self.cost = cost
    }

    public mutating func add(_ event: UsageEvent) {
        usage.add(event.usage)
        eventCount += 1
        cost += event.cost
    }
}

public struct DailyUsage: Identifiable, Sendable {
    public let day: Date
    public let provider: Provider
    public let usage: TokenUsage
    public let eventCount: Int

    public var id: String {
        "\(provider.rawValue)-\(Int(day.timeIntervalSince1970))"
    }
}

public struct UsageReport: Sendable {
    public let events: [UsageEvent]
    public let skippedFileCount: Int
    public let refreshedAt: Date

    public init(events: [UsageEvent], skippedFileCount: Int, refreshedAt: Date = Date()) {
        self.events = events
        self.skippedFileCount = skippedFileCount
        self.refreshedAt = refreshedAt
    }

    public static let empty = UsageReport(events: [], skippedFileCount: 0)

    public func summary(for provider: Provider, since startDate: Date? = nil) -> ProviderSummary {
        var summary = ProviderSummary(provider: provider)
        for event in events where event.provider == provider && (startDate == nil || event.date >= startDate!) {
            summary.add(event)
        }
        return summary
    }

    public func combinedSummary(since startDate: Date? = nil) -> TokenUsage {
        events
            .filter { startDate == nil || $0.date >= startDate! }
            .reduce(into: .zero) { $0.add($1.usage) }
    }

    public func combinedCost(since startDate: Date? = nil) -> Double {
        events
            .filter { startDate == nil || $0.date >= startDate! }
            .reduce(0) { $0 + $1.cost }
    }

    public func dailyUsage(days: Int, calendar: Calendar = .current) -> [DailyUsage] {
        let today = calendar.startOfDay(for: refreshedAt)
        guard let firstDay = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) else {
            return []
        }

        var grouped: [DailyUsageKey: ProviderSummary] = [:]
        for event in events where event.date >= firstDay {
            let key = DailyUsageKey(day: calendar.startOfDay(for: event.date), provider: event.provider)
            var summary = grouped[key] ?? ProviderSummary(provider: event.provider)
            summary.add(event)
            grouped[key] = summary
        }

        return grouped
            .map { DailyUsage(day: $0.key.day, provider: $0.key.provider, usage: $0.value.usage, eventCount: $0.value.eventCount) }
            .sorted { lhs, rhs in
                lhs.day == rhs.day ? lhs.provider.rawValue < rhs.provider.rawValue : lhs.day < rhs.day
            }
    }
}

private struct DailyUsageKey: Hashable {
    let day: Date
    let provider: Provider
}

public struct TokenUsageScanner {
    private let codexRoot: URL
    private let claudeRoot: URL
    private let opencodeReader: OpenCodeUsageReader

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        codexRoot = homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory)
        claudeRoot = homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory)
        opencodeReader = OpenCodeUsageReader(homeDirectory: homeDirectory)
    }

    public func scan() -> UsageReport {
        var events: [UsageEvent] = []
        var skippedFileCount = 0

        let codexResult = scanFiles(at: codexRoot, provider: .codex)
        events += codexResult.events
        skippedFileCount += codexResult.skippedFileCount

        let claudeResult = scanFiles(at: claudeRoot, provider: .claude)
        events += claudeResult.events
        skippedFileCount += claudeResult.skippedFileCount

        let opencodeResult = opencodeReader.read()
        events += opencodeResult.events
        skippedFileCount += opencodeResult.skippedCount

        return UsageReport(events: events, skippedFileCount: skippedFileCount)
    }

    public static func parseCodexLine(_ line: String, fallbackDate: Date) -> UsageEvent? {
        guard
            let object = jsonObject(from: line),
            let payload = object["payload"] as? [String: Any],
            let info = payload["info"] as? [String: Any],
            let usage = info["last_token_usage"] as? [String: Any]
        else {
            return nil
        }

        let input = number(usage["input_tokens"])
        let output = number(usage["output_tokens"])
        let total = number(usage["total_tokens"])
        guard total > 0 || input > 0 || output > 0 else { return nil }

        return UsageEvent(
            provider: .codex,
            date: date(in: object, fallback: fallbackDate),
            usage: TokenUsage(
                input: input,
                cachedRead: number(usage["cached_input_tokens"]),
                output: output,
                total: total > 0 ? total : input + output
            )
        )
    }

    public static func parseClaudeLine(_ line: String, fallbackDate: Date) -> UsageEvent? {
        guard
            let object = jsonObject(from: line),
            object["type"] as? String == "assistant",
            let message = object["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else {
            return nil
        }

        let input = number(usage["input_tokens"])
        let cachedRead = number(usage["cache_read_input_tokens"])
        let cachedWrite = number(usage["cache_creation_input_tokens"])
        let output = number(usage["output_tokens"])
        let total = input + cachedRead + cachedWrite + output
        guard total > 0 else { return nil }

        return UsageEvent(
            provider: .claude,
            date: date(in: object, fallback: fallbackDate),
            usage: TokenUsage(
                input: input,
                cachedRead: cachedRead,
                cachedWrite: cachedWrite,
                output: output,
                total: total
            )
        )
    }

    private func scanFiles(at root: URL, provider: Provider) -> (events: [UsageEvent], skippedFileCount: Int) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], 0)
        }

        var events: [UsageEvent] = []
        var skippedFileCount = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let fallbackDate = modificationDate(for: url) ?? Date.distantPast

            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                for line in contents.split(whereSeparator: \.isNewline) {
                    let event: UsageEvent?
                    switch provider {
                    case .codex:
                        event = Self.parseCodexLine(String(line), fallbackDate: fallbackDate)
                    case .claude:
                        event = Self.parseClaudeLine(String(line), fallbackDate: fallbackDate)
                    case .opencode:
                        event = nil
                    }
                    if let event { events.append(event) }
                }
            } catch {
                skippedFileCount += 1
            }
        }
        return (events, skippedFileCount)
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private extension TokenUsageScanner {
    static func jsonObject(from line: String) -> [String: Any]? {
        guard
            let data = line.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else {
            return nil
        }
        return object
    }

    static func number(_ value: Any?) -> Int64 {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }

    static func date(in object: [String: Any], fallback: Date) -> Date {
        guard let timestamp = object["timestamp"] as? String else { return fallback }
        return ISO8601DateParser.date(from: timestamp) ?? fallback
    }
}

private enum ISO8601DateParser {
    static func date(from value: String) -> Date? {
        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractionalSeconds.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
