import Foundation
import AppKit
import Observation
import SwiftTerm

/// One local shell session (the user's Mac shell), shown in its own window.
/// Mirrors the SSH sessions but runs a local process instead of an SSH PTY.
@Observable
@MainActor
final class LocalSession: Identifiable {
    let id = UUID()
    var title: String = "Lokales Terminal"
    @ObservationIgnored let terminalView: LocalProcessTerminalView
    @ObservationIgnored weak var window: NSWindow?

    init(fontSize: CGFloat, theme: TerminalTheme) {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 820, height: 500))
        tv.configureNativeColors()
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.nativeForegroundColor = theme.foreground
        tv.nativeBackgroundColor = theme.background
        tv.caretColor = theme.caret
        self.terminalView = tv

        // Launch the user's login shell so aliases/PATH match a normal Terminal.app session.
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shellPath as NSString).lastPathComponent
        tv.startProcess(executable: shellPath, args: [], execName: "-\(shellName)") // argv[0] '-zsh' = login shell
    }

    func terminate() {
        terminalView.terminate()
    }
}
