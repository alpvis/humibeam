import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Observation

/// Zustandsmaschine der Kunden-App: Signaling, Berechtigungen, eingehende Anfrage bestätigen,
/// WebRTC-Sitzung. Sichtbarer Hinweis bei aktiver Verbindung (keine stille Fernsteuerung).
@Observable
@MainActor
final class SupportSession {
    enum Phase { case connecting, ready, incoming, connected }

    var phase: Phase = .connecting
    var deviceId = "—"
    var code = "——————"
    var supporter = ""
    var statusText = "Verbinde mit humibeam.com…"
    var screenGranted = false
    var accessibilityGranted = false
    var online = false

    var permissionsOK: Bool { screenGranted && accessibilityGranted }

    private let signal = SupportSignalClient(
        url: URL(string: "wss://humibeam.com/humibeam-support/ws")!)
    private let injector = RemoteInputInjector()
    private var webrtc: ScreenWebRTC?
    private var pendingSessionId: String?
    private var activeSessionId: String?

    init() {
        wire()
        refreshPermissions()
    }

    func start() {
        refreshPermissions()
        signal.connect()
    }

    private func wire() {
        signal.onState = { [weak self] connected in
            guard let self else { return }
            online = connected
            if connected, phase == .connecting { statusText = "Registriere Gerät…" }
            if !connected { statusText = "Keine Verbindung zum Server — versuche erneut…"
                phase = .connecting
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.signal.connect() }
            }
        }
        signal.onRegistered = { [weak self] id, code in
            guard let self else { return }
            deviceId = id; self.code = code; phase = .ready
            statusText = permissionsOK ? "Bereit für Verbindung" : "Berechtigungen fehlen"
        }
        signal.onCode = { [weak self] code in self?.code = code }
        signal.onConnectionRequest = { [weak self] sid, sup in
            guard let self else { return }
            pendingSessionId = sid; supporter = sup; phase = .incoming
            NSApp.requestUserAttention(.criticalRequest)
            NSApp.activate(ignoringOtherApps: true)
        }
        signal.onSessionStart = { [weak self] sid, _, ice in
            guard let self else { return }
            activeSessionId = sid
            let rtc = ScreenWebRTC(injector: injector)
            rtc.onLocalSignal = { [weak self] data in self?.signal.signal(sessionId: sid, data: data) }
            rtc.onClosed = { [weak self] in self?.endLocal("Verbindung verloren") }
            webrtc = rtc
            rtc.start(iceServers: ice)
            phase = .connected
            statusText = "Supporter verbunden — dein Bildschirm wird übertragen"
        }
        signal.onSignal = { [weak self] _, data in self?.webrtc?.handleRemoteSignal(data) }
        signal.onSessionEnd = { [weak self] _, reason in self?.endLocal("Sitzung beendet (\(reason))") }
    }

    // MARK: - Aktionen

    func approve() {
        guard let sid = pendingSessionId else { return }
        signal.accept(sessionId: sid)
        statusText = "Verbindung wird aufgebaut…"
    }

    func deny() {
        if let sid = pendingSessionId { signal.reject(sessionId: sid) }
        pendingSessionId = nil
        phase = .ready
        statusText = "Bereit für Verbindung"
    }

    func hangup() {
        if let sid = activeSessionId { signal.hangup(sessionId: sid) }
        endLocal("Verbindung beendet")
    }

    private func endLocal(_ msg: String) {
        webrtc?.stop(); webrtc = nil
        activeSessionId = nil; pendingSessionId = nil
        statusText = msg
        phase = .ready
    }

    // MARK: - Berechtigungen

    func refreshPermissions() {
        screenGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openSettings("Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        openSettings("Privacy_ListenEvent")
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
