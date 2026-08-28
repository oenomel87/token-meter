import Foundation

/// One live Codex usage window returned by the locally installed Codex CLI.
public struct CodexRateLimitWindow: Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: Date?
    public let durationMinutes: Int?

    public init(usedPercentage: Double, resetsAt: Date?, durationMinutes: Int?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }

    public var remainingPercentage: Double {
        min(max(100 - usedPercentage, 0), 100)
    }

    public var fraction: Double {
        min(max(usedPercentage / 100, 0), 1)
    }

    public func hasReset(asOf now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// The primary and secondary windows for the signed-in Codex account.
public struct CodexRateLimitBucket: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?

    public init(
        id: String,
        name: String?,
        primary: CodexRateLimitWindow?,
        secondary: CodexRateLimitWindow?
    ) {
        self.id = id
        self.name = name
        self.primary = primary
        self.secondary = secondary
    }

    public var isEmpty: Bool {
        primary == nil && secondary == nil
    }

    /// Codex Spark has a separate metered bucket, but Token Meter intentionally
    /// excludes that product-specific quota from its user-facing usage meter.
    public var isCodexSpark: Bool {
        if id.caseInsensitiveCompare("codex_bengalfox") == .orderedSame {
            return true
        }

        guard let name else { return false }
        let normalizedName = name
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        return normalizedName.contains("codexspark")
    }
}

/// Every metered Codex bucket returned for the signed-in account.
public struct CodexRateLimitSnapshot: Equatable, Sendable {
    public let buckets: [CodexRateLimitBucket]
    public let capturedAt: Date

    public init(buckets: [CodexRateLimitBucket], capturedAt: Date) {
        self.buckets = buckets
        self.capturedAt = capturedAt
    }

    /// Compatibility accessors for the historical single-bucket UI.
    public var primary: CodexRateLimitWindow? { defaultBucket?.primary }
    public var secondary: CodexRateLimitWindow? { defaultBucket?.secondary }

    public var defaultBucket: CodexRateLimitBucket? {
        buckets.first(where: { $0.id == "codex" }) ?? buckets.first
    }

    public var isEmpty: Bool {
        buckets.allSatisfy(\.isEmpty)
    }
}

public enum CodexRateLimitReadFailure: String, Error, Equatable, Sendable {
    case executableNotFound
    case cliLaunchFailed
    case initializationFailed
    case rateLimitRequestFailed
    case invalidResponse
}

public enum CodexRateLimitReadResult: Equatable, Sendable {
    case success(CodexRateLimitSnapshot)
    case failure(CodexRateLimitReadFailure)
}

/// Queries the installed `codex` CLI over its local app-server protocol.
///
/// The CLI uses its own signed-in session. This reader neither inspects nor
/// copies credentials, and it intentionally returns no value if the protocol
/// is unavailable instead of presenting a stale estimate as a live limit.
public struct CodexRateLimitReader: Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func read() -> CodexRateLimitSnapshot? {
        guard case let .success(snapshot) = readResult() else { return nil }
        return snapshot
    }

    public func readResult() -> CodexRateLimitReadResult {
        guard let executable = Self.findExecutable(homeDirectory: homeDirectory) else {
            return .failure(.executableNotFound)
        }

        switch Self.requestRateLimits(using: executable) {
        case let .success(response):
            guard let snapshot = Self.parse(response, capturedAt: Date()) else {
                return .failure(.invalidResponse)
            }
            return .success(snapshot)
        case let .failure(failure):
            return .failure(failure)
        }
    }

    public static func parse(_ data: Data, capturedAt: Date) -> CodexRateLimitSnapshot? {
        guard
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any],
            let result = object["result"] as? [String: Any]
        else {
            return nil
        }

        // Prefer the multi-bucket view. The single `rateLimits` object exists
        // only for backward compatibility with older clients.
        let byLimitID = result["rateLimitsByLimitId"] as? [String: Any]
        var buckets = (byLimitID ?? [:]).compactMap { key, value -> CodexRateLimitBucket? in
            guard let object = value as? [String: Any] else { return nil }
            return bucket(from: object, fallbackID: key)
        }

        if buckets.isEmpty,
           let legacy = result["rateLimits"] as? [String: Any],
           let bucket = bucket(from: legacy, fallbackID: "codex") {
            buckets = [bucket]
        }

        buckets.sort { left, right in
            if left.id == "codex" { return true }
            if right.id == "codex" { return false }
            return (left.name ?? left.id).localizedCaseInsensitiveCompare(right.name ?? right.id) == .orderedAscending
        }

        let snapshot = CodexRateLimitSnapshot(buckets: buckets, capturedAt: capturedAt)
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func bucket(from object: [String: Any], fallbackID: String) -> CodexRateLimitBucket? {
        let bucket = CodexRateLimitBucket(
            id: (object["limitId"] as? String) ?? fallbackID,
            name: object["limitName"] as? String,
            primary: window(from: object["primary"]),
            secondary: window(from: object["secondary"])
        )
        return bucket.isEmpty ? nil : bucket
    }

    private static func window(from value: Any?) -> CodexRateLimitWindow? {
        guard
            let object = value as? [String: Any],
            let used = number(object["usedPercent"])
        else {
            return nil
        }

        let resetDate = number(object["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        return CodexRateLimitWindow(
            usedPercentage: used,
            resetsAt: resetDate,
            durationMinutes: number(object["windowDurationMins"]).map(Int.init)
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func findExecutable(homeDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let configuredPath = ProcessInfo.processInfo.environment["TOKEN_METER_CODEX_PATH"] {
            candidates.append(URL(fileURLWithPath: configuredPath))
        }

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex") }
        candidates += pathEntries
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            homeDirectory.appending(path: ".local/bin/codex"),
            homeDirectory.appending(path: ".npm/bin/codex"),
            homeDirectory.appending(path: ".volta/bin/codex")
        ]

        // fnm gives each shell an isolated bin directory, which is not usually
        // present in the PATH inherited by a Finder-launched menu bar app.
        let fnmDirectory = homeDirectory.appending(path: ".local/state/fnm_multishells", directoryHint: .isDirectory)
        if let directories = try? fileManager.contentsOfDirectory(
            at: fnmDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates += directories
                .sorted {
                    let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return left > right
                }
                .map { $0.appending(path: "bin/codex") }
        }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func processEnvironment(
        for executable: URL,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inheritedEnvironment
        let executableDirectory = executable.deletingLastPathComponent().standardizedFileURL.path
        let fallbackPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        var pathEntries = (environment["PATH"] ?? fallbackPath)
            .split(separator: ":")
            .map(String.init)

        if !pathEntries.contains(executableDirectory) {
            pathEntries.insert(executableDirectory, at: 0)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        return environment
    }

    private static func requestRateLimits(
        using executable: URL
    ) -> Result<Data, CodexRateLimitReadFailure> {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = AppServerResponseCollector()

        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = processEnvironment(for: executable)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let outputHandle = output.fileHandleForReading
        outputHandle.readabilityHandler = { [collector] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            collector.append(data)
        }

        defer {
            outputHandle.readabilityHandler = nil
            input.fileHandleForWriting.closeFile()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        do {
            try process.run()
            try sendRequest(
                id: 1,
                method: "initialize",
                parameters: [
                    "clientInfo": [
                        "name": "token_meter",
                        "title": "Token Meter",
                        "version": "1.0"
                    ]
                ],
                to: input.fileHandleForWriting
            )
            guard let initializeResponse = collector.wait(for: 1, timeout: 3) else {
                return .failure(process.isRunning ? .initializationFailed : .cliLaunchFailed)
            }
            guard !isErrorResponse(initializeResponse) else {
                return .failure(.initializationFailed)
            }

            try sendNotification(method: "initialized", to: input.fileHandleForWriting)

            try sendRequest(
                id: 2,
                method: "account/rateLimits/read",
                parameters: nil,
                to: input.fileHandleForWriting
            )
            guard let response = collector.wait(for: 2, timeout: 5) else {
                return .failure(.rateLimitRequestFailed)
            }
            guard !isErrorResponse(response) else {
                return .failure(.rateLimitRequestFailed)
            }
            return .success(response)
        } catch {
            return .failure(.cliLaunchFailed)
        }
    }

    private static func isErrorResponse(_ data: Data) -> Bool {
        guard
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else {
            return true
        }
        return object["error"] != nil
    }

    private static func sendRequest(
        id: Int,
        method: String,
        parameters: [String: Any]?,
        to handle: FileHandle
    ) throws {
        var request: [String: Any] = ["id": id, "method": method]
        if let parameters { request["params"] = parameters }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func sendNotification(method: String, to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: ["method": method])
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

private final class AppServerResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let initializeSignal = DispatchSemaphore(value: 0)
    private let rateLimitSignal = DispatchSemaphore(value: 0)
    private var bufferedData = Data()
    private var responses: [Int: Data] = [:]

    func append(_ data: Data) {
        lock.lock()
        bufferedData.append(data)

        while let newline = bufferedData.firstIndex(of: 0x0A) {
            let line = Data(bufferedData[..<newline])
            bufferedData.removeSubrange(...newline)
            guard
                let value = try? JSONSerialization.jsonObject(with: line),
                let object = value as? [String: Any],
                let identifier = object["id"] as? NSNumber
            else {
                continue
            }

            let id = identifier.intValue
            responses[id] = line
            switch id {
            case 1: initializeSignal.signal()
            case 2: rateLimitSignal.signal()
            default: break
            }
        }
        lock.unlock()
    }

    func wait(for id: Int, timeout: TimeInterval) -> Data? {
        lock.lock()
        if let response = responses[id] {
            lock.unlock()
            return response
        }
        lock.unlock()

        let signal = id == 1 ? initializeSignal : rateLimitSignal
        guard signal.wait(timeout: .now() + timeout) == .success else { return nil }

        lock.lock()
        defer { lock.unlock() }
        return responses[id]
    }
}
