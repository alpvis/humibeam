import SwiftUI
import AppKit
import SwiftTerm

/// Hosts a SwiftTerm `TerminalView` (owned by a TerminalSessionController) inside SwiftUI.
struct TerminalRepresentable: NSViewRepresentable {
    let controller: TerminalSessionController

    func makeNSView(context: Context) -> TerminalView {
        let view = controller.terminalView
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // The controller owns the view's lifecycle; nothing to push from SwiftUI state.
    }
}
