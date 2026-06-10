import Foundation
import AppKit
import Observation

/// How a session's detail area is presented: the terminal, the integrated file manager, or split.
enum SessionMode: String, CaseIterable, Identifiable {
    case terminal, files, split
    var id: String { rawValue }
    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .files: return "Dateien"
        case .split: return "Split"
        }
    }
    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .split: return "rectangle.split.2x1"
        }
    }
}

/// Live connection health of a session — drives the sidebar/status dots and the menu-bar icon.
enum SessionHealth {
    case connecting, connected, reconnecting, offline, closed, error

    var color: NSColor {
        switch self {
        case .connected: return .systemGreen
        case .connecting, .reconnecting: return .systemOrange
        case .offline: return .systemYellow
        case .closed: return .systemGray
        case .error: return .systemRed
        }
    }
}

/// One open terminal tab: a connected (or connecting) SSH session plus its file-browser state.
@Observable
@MainActor
final class TerminalTab: Identifiable {
    let id = UUID()
    let host: SSHHost
    let controller: TerminalSessionController

    var title: String
    var status: String = "verbinde…"
    var connected: Bool = false
    /// Which pane the detail view shows (Terminal / Dateien / Split).
    var mode: SessionMode = .terminal
    /// Detailed health for the sidebar dot + menu-bar icon (set by HumibeamShell on state changes).
    var health: SessionHealth = .connecting

    // Per-tab file browser
    var showFileBrowser = false
    var browserPath = ""
    var browserFiles: [RemoteFile] = []
    var browserBusy = false

    /// Borrowed-connection file session backing the integrated "Dateien" mode (created lazily,
    /// reset whenever the terminal (re)connects so it always rides the live connection).
    var fileSession: FileSession?

    // Search
    var searchVisible = false
    var searchTerm = ""

    // Split pane (optional second session, same host)
    var splitController: TerminalSessionController?
    var splitStatus = ""
    var isSplit: Bool { splitController != nil }

    // Claude Code permission prompt → Allow/Deny buttons
    var awaitingApproval = false
    var approvalAllowAlways = false
    /// Structured prompt for the inline approval card (action, command/diff preview).
    var approval: ClaudeApproval?
    // Files Claude recently touched → one-click open in the remote editor
    var recentPaths: [String] = []

    // Stufe 2: reliable working-tree diff (git diff over the exec-channel)
    var showDiff = false
    var diffBusy = false
    var diffResult: GitDiffResult?

    // AI helper
    var claudeDetected = false
    var showAIPanel = false
    var aiBusy = false
    var aiTitle = ""
    var aiResult = ""
    var aiSuggestIntent = ""

    // Port forwarding
    var showForwards = false

    // Remote editor
    var showEditor = false
    var editFileName = ""
    var editPath = ""
    var editContent = ""
    var editBusy = false

    init(host: SSHHost, controller: TerminalSessionController) {
        self.host = host
        self.controller = controller
        self.title = host.displayName
    }
}
