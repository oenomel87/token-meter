import Foundation

/// One Claude.ai subscription usage window as Claude Code reports it to the status line.
public struct RateLimitWindow: Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var remainingPercentage: Double {
        min(max(100 - usedPercentage, 0), 100)
    }

    public var fraction: Double {
        min(max(usedPercentage / 100, 0), 1)
    }

    /// The reported percentage only describes the window that was open when it
    /// was captured. Once that window rolls over the number says nothing.
    public func hasReset(asOf now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// The 5-hour and 7-day limits captured from a Claude Code status line render.
public struct RateLimitSnapshot: Equatable, Sendable {
    public let fiveHour: RateLimitWindow?
    public let sevenDay: RateLimitWindow?
    public let model: String?
    public let capturedAt: Date

    public init(
        fiveHour: RateLimitWindow?,
        sevenDay: RateLimitWindow?,
        model: String?,
        capturedAt: Date
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.model = model
        self.capturedAt = capturedAt
    }

    public var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil
    }
}

/// Reads the snapshot the status line bridge leaves behind.
public struct RateLimitReader: Sendable {
    public let fileURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(fileURL: StatusLineBridge(homeDirectory: homeDirectory).snapshotURL)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func read() -> RateLimitSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let modifiedAt = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return Self.parse(data, fallbackDate: modifiedAt ?? Date())
    }

    public static func parse(_ data: Data, fallbackDate: Date) -> RateLimitSnapshot? {
        guard
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else {
            return nil
        }

        let limits = object["rate_limits"] as? [String: Any]
        let snapshot = RateLimitSnapshot(
            fiveHour: window(from: limits?["five_hour"]),
            sevenDay: window(from: limits?["seven_day"]),
            model: modelName(in: object),
            capturedAt: capturedDate(in: object) ?? fallbackDate
        )
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func window(from value: Any?) -> RateLimitWindow? {
        guard
            let object = value as? [String: Any],
            let used = object["used_percentage"] as? NSNumber
        else {
            return nil
        }

        let resetsAt = (object["resets_at"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return RateLimitWindow(usedPercentage: used.doubleValue, resetsAt: resetsAt)
    }

    private static func modelName(in object: [String: Any]) -> String? {
        if let name = object["model"] as? String { return name }
        if let model = object["model"] as? [String: Any] {
            return model["display_name"] as? String
        }
        return nil
    }

    private static func capturedDate(in object: [String: Any]) -> Date? {
        guard let seconds = object["captured_at"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }
}
