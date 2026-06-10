import Foundation

/// Stufe 3 of the agent cockpit: the opt-in structured bridge. Installs a Claude Code `PreToolUse`
/// hook on the server that writes each tool-call as JSON to `~/.humibeam/events.jsonl`. humibeam
/// reads the latest line over the existing exec-channel and renders a 100%-exact approval card
/// (real tool name, command, and a true diff from old/new strings) instead of scraping the TUI.
///
/// Stays opt-in so the zero-install promise holds for everyone who doesn't want it. The hook never
/// blocks Claude's own prompt (exit 0, no decision) — humibeam's buttons still drive 1/2/Esc; the
/// bridge only supplies exact display data. See docs/AGENT-COCKPIT.md.
@MainActor
enum ClaudeBridge {

    struct Status: Equatable {
        var hookInstalled: Bool
        var settingsConfigured: Bool
        var home: String
        var active: Bool { hookInstalled && settingsConfigured }
    }

    /// The hook script (kept in sync with tools/humibeam-hook.sh). Dependency-free: bash + coreutils.
    static let hookScript = """
    #!/usr/bin/env bash
    # humibeam Claude-Code bridge (PreToolUse). Writes each tool-call as one JSON line and exits 0
    # (no decision) so Claude Code still shows its normal prompt. Dependency-free, zero-install.
    dir="$HOME/.humibeam"
    mkdir -p "$dir"
    payload="$(cat | tr '\\n' ' ')"
    printf '%s\\n' "$payload" >> "$dir/events.jsonl"
    tail -n 200 "$dir/events.jsonl" > "$dir/events.jsonl.tmp" 2>/dev/null && mv "$dir/events.jsonl.tmp" "$dir/events.jsonl"
    exit 0
    """

    // MARK: - Status

    static func status(connection: SSHConnection?) async -> Status? {
        guard let conn = connection else { return nil }
        let cmd = """
        echo "$HOME"
        [ -x "$HOME/.humibeam/hook.sh" ] && echo HOOK=1 || echo HOOK=0
        grep -q 'humibeam/hook.sh' "$HOME/.claude/settings.json" 2>/dev/null && echo CFG=1 || echo CFG=0
        """
        guard let (_, out, _) = try? await conn.exec(cmd) else { return nil }
        let text = String(decoding: out, as: UTF8.self)
        let home = text.split(separator: "\n").first.map(String.init) ?? "$HOME"
        return Status(hookInstalled: text.contains("HOOK=1"),
                      settingsConfigured: text.contains("CFG=1"),
                      home: home)
    }

    // MARK: - Install / Remove

    /// Installs the hook script and merges the PreToolUse entry into ~/.claude/settings.json.
    static func install(connection: SSHConnection?) async -> Result<Void, BridgeError> {
        guard let conn = connection else { return .failure(.notConnected) }
        guard let st = await status(connection: conn) else { return .failure(.notConnected) }
        let home = st.home

        // 1) Write the hook script (base64 to avoid all quoting pitfalls) and make it executable.
        let hookB64 = Data(hookScript.utf8).base64EncodedString()
        let writeHook = """
        mkdir -p "$HOME/.humibeam" && printf '%s' '\(hookB64)' | base64 -d > "$HOME/.humibeam/hook.sh" && chmod +x "$HOME/.humibeam/hook.sh"
        """
        guard let (code, _, err) = try? await conn.exec(writeHook), code == 0 else {
            return .failure(.exec("Hook konnte nicht geschrieben werden"))
        }
        _ = err

        // 2) Read existing settings.json (may be absent), merge our entry, write back with a backup.
        let existing = (try? await conn.exec("cat \"$HOME/.claude/settings.json\" 2>/dev/null"))
            .map { String(decoding: $0.1, as: UTF8.self) } ?? ""
        let merged: Data
        do {
            merged = try mergedSettings(existing: existing, home: home)
        } catch {
            return .failure(.malformedSettings)
        }
        let cfgB64 = merged.base64EncodedString()
        let writeCfg = """
        mkdir -p "$HOME/.claude"
        [ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.humibeam-bak"
        printf '%s' '\(cfgB64)' | base64 -d > "$HOME/.claude/settings.json"
        """
        guard let (code2, _, _) = try? await conn.exec(writeCfg), code2 == 0 else {
            return .failure(.exec("settings.json konnte nicht geschrieben werden"))
        }
        return .success(())
    }

    /// Removes the PreToolUse entry from settings.json (restoring the backup if present) and deletes the hook.
    static func remove(connection: SSHConnection?) async -> Result<Void, BridgeError> {
        guard let conn = connection else { return .failure(.notConnected) }
        let existing = (try? await conn.exec("cat \"$HOME/.claude/settings.json\" 2>/dev/null"))
            .map { String(decoding: $0.1, as: UTF8.self) } ?? ""
        if let cleaned = try? settingsWithoutBridge(existing: existing) {
            let b64 = cleaned.base64EncodedString()
            _ = try? await conn.exec("printf '%s' '\(b64)' | base64 -d > \"$HOME/.claude/settings.json\"")
        }
        _ = try? await conn.exec("rm -f \"$HOME/.humibeam/hook.sh\"")
        return .success(())
    }

    // MARK: - Reading the latest event

    /// Reads the newest tool-call from the bridge log and builds an exact approval, or nil when the
    /// bridge is inactive / the last event is stale (older than 5 min).
    static func latestApproval(connection: SSHConnection?) async -> ClaudeApproval? {
        guard let conn = connection else { return nil }
        let cmd = """
        f="$HOME/.humibeam/events.jsonl"
        if [ -f "$f" ]; then date +%s; stat -c %Y "$f" 2>/dev/null || stat -f %m "$f"; tail -n 1 "$f"; fi
        """
        guard let (_, out, _) = try? await conn.exec(cmd) else { return nil }
        let text = String(decoding: out, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, let now = Double(lines[0].trimmingCharacters(in: .whitespaces)),
              let mtime = Double(lines[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        guard now - mtime < 300 else { return nil }   // bridge idle → trust the scraped card instead
        let eventLine = lines[2...].joined(separator: " ")
        guard let data = eventLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = obj["tool_name"] as? String,
              let input = obj["tool_input"] as? [String: Any] else { return nil }
        return ClaudeApproval.fromTool(name: tool, input: input)
    }

    // MARK: - settings.json merge (done in Swift so we don't need jq on the server)

    private static let hookMarker = "humibeam/hook.sh"

    static func mergedSettings(existing: String, home: String) throws -> Data {
        var root = parseObject(existing)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []

        let alreadyThere = pre.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains(hookMarker) == true
            } == true
        }
        if !alreadyThere {
            let entry: [String: Any] = [
                "matcher": "Bash|Edit|Write|MultiEdit",
                "hooks": [[
                    "type": "command",
                    "command": "\(home)/.humibeam/hook.sh",
                    "timeout": 120
                ]]
            ]
            pre.append(entry)
            hooks["PreToolUse"] = pre
            root["hooks"] = hooks
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func settingsWithoutBridge(existing: String) throws -> Data {
        var root = parseObject(existing)
        guard var hooks = root["hooks"] as? [String: Any],
              var pre = hooks["PreToolUse"] as? [[String: Any]] else {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        }
        pre.removeAll { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains(hookMarker) == true
            } == true
        }
        if pre.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = pre }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func parseObject(_ s: String) -> [String: Any] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    enum BridgeError: Error, LocalizedError {
        case notConnected, exec(String), malformedSettings
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Keine Verbindung."
            case .exec(let m): return m
            case .malformedSettings: return "~/.claude/settings.json ist kein gültiges JSON – nicht angetastet."
            }
        }
    }
}
