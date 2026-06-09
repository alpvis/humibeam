import Foundation
import Observation

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

    // Per-tab file browser
    var showFileBrowser = false
    var browserPath = ""
    var browserFiles: [RemoteFile] = []
    var browserBusy = false

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
