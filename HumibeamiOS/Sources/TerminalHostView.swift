import SwiftUI
import UIKit
import SwiftTerm

/// Hosts the controller's SwiftTerm `TerminalView` inside SwiftUI and attaches the key toolbar.
struct TerminalHostView: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> BeamTerminalView {
        let view = controller.terminalView
        if !(view.inputAccessoryView is TerminalKeyAccessory) {
            view.inputAccessoryView = TerminalKeyAccessory(controller: controller)
        }
        return view
    }

    func updateUIView(_ uiView: BeamTerminalView, context: Context) {
        // The controller owns the view's lifecycle; nothing to push from SwiftUI state.
    }
}

/// Tasten-Leiste über der iOS-Tastatur: Esc, Tab, ⇧Tab (Claude-Modus), Ctrl-C, Pfeile, Sonderzeichen.
final class TerminalKeyAccessory: UIInputView {
    private weak var controller: TerminalController?
    private var ctrlActive = false
    private var ctrlButton: UIButton?
    private var micButton: UIButton?

    init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        buildButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    private struct Key {
        let label: String
        let isSymbol: Bool
        let action: (TerminalKeyAccessory) -> Void
    }

    private func buildButtons() {
        let keys: [Key] = [
            Key(label: "mic.fill", isSymbol: true) { $0.toggleDictation() },
            Key(label: "esc", isSymbol: false) { $0.send([0x1b]) },
            Key(label: "arrow.right.to.line", isSymbol: true) { $0.send([0x09]) },                 // Tab
            Key(label: "arrow.left.to.line", isSymbol: true) { $0.send([0x1b, 0x5b, 0x5a]) },     // ⇧Tab (CSI Z)
            Key(label: "ctrl", isSymbol: false) { $0.toggleCtrl() },
            Key(label: "^C", isSymbol: false) { $0.send([0x03]) },
            Key(label: "arrowtriangle.up", isSymbol: true) { $0.sendEscape("[A") },
            Key(label: "arrowtriangle.down", isSymbol: true) { $0.sendEscape("[B") },
            Key(label: "arrowtriangle.left", isSymbol: true) { $0.sendEscape("[D") },
            Key(label: "arrowtriangle.right", isSymbol: true) { $0.sendEscape("[C") },
            Key(label: "-", isSymbol: false) { $0.type("-") },
            Key(label: "/", isSymbol: false) { $0.type("/") },
            Key(label: "|", isSymbol: false) { $0.type("|") },
            Key(label: "~", isSymbol: false) { $0.type("~") },
            Key(label: "keyboard.chevron.compact.down", isSymbol: true) { $0.dismissKeyboard() },
        ]

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center

        for (i, key) in keys.enumerated() {
            var config = UIButton.Configuration.gray()
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
            if key.isSymbol {
                config.image = UIImage(systemName: key.label,
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            } else {
                config.attributedTitle = AttributedString(
                    key.label,
                    attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)]))
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                key.action(self)
            })
            if i == 0 { micButton = button }
            if i == 4 { ctrlButton = button }
            stack.addArrangedSubview(button)
        }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    // MARK: - Key actions

    private func send(_ bytes: [UInt8]) { controller?.sendToShell(bytes) }
    private func sendEscape(_ suffix: String) { controller?.sendToShell([0x1b] + Array(suffix.utf8)) }

    /// Mit aktivem Ctrl wird der nächste getippte Buchstabe als Control-Code gesendet (a→0x01 …).
    private func type(_ s: String) {
        if ctrlActive, let scalar = s.lowercased().unicodeScalars.first,
           scalar.value >= 97, scalar.value <= 122 {
            send([UInt8(scalar.value - 96)])
            toggleCtrl()
        } else {
            controller?.sendToShell(s)
        }
    }

    private func toggleCtrl() {
        ctrlActive.toggle()
        ctrlButton?.configuration = ctrlActive ? .filled() : .gray()
        var config = ctrlButton?.configuration ?? .gray()
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
        config.attributedTitle = AttributedString(
            "ctrl",
            attributes: AttributeContainer([.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)]))
        ctrlButton?.configuration = config
    }

    private func dismissKeyboard() {
        controller?.terminalView.resignFirstResponder()
    }

    /// Sprach-Diktat: Tap startet die Aufnahme (Button wird rot), zweiter Tap stoppt,
    /// transkribiert via Whisper und tippt den Text ins Terminal.
    private func toggleDictation() {
        DictationService.shared.onStateChange = { [weak self] recording in
            var config: UIButton.Configuration = recording ? .filled() : .gray()
            if recording { config.baseBackgroundColor = .systemRed }
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 9, bottom: 6, trailing: 9)
            config.image = UIImage(systemName: recording ? "stop.fill" : "mic.fill",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            self?.micButton?.configuration = config
        }
        DictationService.shared.toggle { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let text) where !text.isEmpty:
                    self?.controller?.sendToShell(text)
                case .success:
                    break
                case .failure(let error):
                    NotificationCenter.default.post(name: .dictationFailed, object: nil,
                                                    userInfo: ["message": error.localizedDescription])
                }
            }
        }
    }

    /// Externe Tasten (z. B. aus der Terminal-Ansicht): Ctrl-Status für getippten Text anwenden.
    func interceptTyped(_ text: String) -> Bool {
        guard ctrlActive else { return false }
        type(text)
        return true
    }
}
