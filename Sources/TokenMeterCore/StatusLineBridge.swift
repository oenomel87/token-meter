import Foundation

public enum StatusLineBridgeError: LocalizedError {
    case settingsNotAnObject(String)

    public var errorDescription: String? {
        switch self {
        case .settingsNotAnObject(let path):
            "\(path) 파일이 JSON 객체가 아니어서 수정하지 않았습니다."
        }
    }
}

/// Installs and removes the status line hook that feeds subscription rate
/// limits to the menu bar app.
///
/// Claude Code only hands the Claude.ai limits (`rate_limits`) to the status
/// line command — they are not written to the session logs — so this is the
/// one place they can be picked up locally.
public struct StatusLineBridge: Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public var directoryURL: URL {
        homeDirectory.appending(path: ".claude/token-meter", directoryHint: .isDirectory)
    }

    public var scriptURL: URL { directoryURL.appending(path: "statusline-bridge.sh") }
    public var previousCommandURL: URL { directoryURL.appending(path: "previous-statusline.sh") }
    public var snapshotURL: URL { directoryURL.appending(path: "statusline.json") }
    public var settingsURL: URL { homeDirectory.appending(path: ".claude/settings.json") }

    public var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else { return false }
        return (try? loadSettings())
            .flatMap { ($0["statusLine"] as? [String: Any])?["command"] as? String } == scriptURL.path
    }

    /// Writes the bridge script and points `statusLine.command` at it, keeping
    /// any previously configured status line command chained behind it.
    /// Returns the backup copy of `settings.json`, when one was made.
    @discardableResult
    public func install() throws -> URL? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Self.scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var settings = try loadSettings()
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        let existingCommand = statusLine["command"] as? String

        if let existingCommand, existingCommand != scriptURL.path {
            try existingCommand.write(to: previousCommandURL, atomically: true, encoding: .utf8)
        } else if !fileManager.fileExists(atPath: previousCommandURL.path) {
            try "".write(to: previousCommandURL, atomically: true, encoding: .utf8)
        }

        let backup = try backupSettings()
        statusLine["type"] = "command"
        statusLine["command"] = scriptURL.path
        settings["statusLine"] = statusLine
        try writeSettings(settings)
        return backup
    }

    /// Restores the status line command that was in place before installing.
    @discardableResult
    public func uninstall() throws -> URL? {
        var settings = try loadSettings()
        guard
            var statusLine = settings["statusLine"] as? [String: Any],
            statusLine["command"] as? String == scriptURL.path
        else {
            return nil
        }

        let previous = (try? String(contentsOf: previousCommandURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let backup = try backupSettings()

        if previous.isEmpty {
            settings["statusLine"] = nil
        } else {
            statusLine["command"] = previous
            settings["statusLine"] = statusLine
        }
        try writeSettings(settings)
        return backup
    }

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StatusLineBridgeError.settingsNotAnObject(settingsURL.path)
        }
        return object
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private func backupSettings() throws -> URL? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = settingsURL
            .deletingLastPathComponent()
            .appending(path: "settings.json.tokenmeter-\(stamp).bak")
        // Installing and removing within the same second would otherwise
        // collide on the timestamped name.
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: settingsURL, to: backup)
        return backup
    }
}

extension StatusLineBridge {
    static let scriptContents = #"""
    #!/bin/sh
    # Token Meter status line bridge (installed by TokenMeter.app).
    #
    # Claude Code pipes its status line JSON — the only place it exposes the
    # Claude.ai subscription rate limits — into this script on every render. We
    # stash the limits where the menu bar app can read them, then hand the
    # untouched JSON to whatever status line command was configured before.
    set -u

    dir=${TOKEN_METER_DIR:-"$HOME/.claude/token-meter"}
    snapshot="$dir/statusline.json"
    inner="$dir/previous-statusline.sh"

    input=$(cat)

    mkdir -p "$dir" 2>/dev/null || true

    payload=""
    if command -v jq >/dev/null 2>&1; then
        payload=$(printf '%s' "$input" | jq -c 'select(.rate_limits != null) | {captured_at: (now | floor), model: .model.display_name, rate_limits: .rate_limits}' 2>/dev/null)
    else
        case "$input" in
            *'"rate_limits"'*) payload=$input ;;
        esac
    fi

    # Only overwrite when this render actually carried limits. They are absent
    # until the first API response of a session, so a blank write would erase a
    # perfectly good reading.
    if [ -n "$payload" ]; then
        tmp="$snapshot.$$"
        if printf '%s' "$payload" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$snapshot" 2>/dev/null || rm -f "$tmp"
        else
            rm -f "$tmp"
        fi
    fi

    if [ -s "$inner" ]; then
        printf '%s' "$input" | /bin/sh "$inner"
    fi

    """#
}
