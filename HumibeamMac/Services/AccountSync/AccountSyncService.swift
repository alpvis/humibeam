import Foundation
import CryptoKit
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Das Sync-Blob: alle Felder optional — jede Plattform schreibt, was sie kennt; unbekannte
/// Felder werden beim Push vom letzten Server-Stand übernommen (carry-forward), damit z. B.
/// iOS die Mac-Lesezeichen nicht wegradiert.
struct AccountSyncPayload: Codable {
    var schema: Int = 1
    var hosts: [SSHHost]?
    var snippets: [Snippet]?
    var bookmarks: [PathBookmark]?
    var fontName: String?
    var fontSize: Double?
    var themeID: String?
    var updatedAt: Date = Date()
    var device: String = ""

    mutating func carryForward(from previous: AccountSyncPayload?) {
        guard let previous else { return }
        if hosts == nil { hosts = previous.hosts }
        if snippets == nil { snippets = previous.snippets }
        if bookmarks == nil { bookmarks = previous.bookmarks }
        if fontName == nil { fontName = previous.fontName }
        if fontSize == nil { fontSize = previous.fontSize }
        if themeID == nil { themeID = previous.themeID }
    }
}

/// Humibeam-Konto: Anmeldung + Ende-zu-Ende-verschlüsselter Sync über alle Geräte
/// (Macs, iPhones, iPads). Plattformneutral — die App verdrahtet `buildPayload`/`applyPayload`.
/// Secrets (Passwörter, SSH-Keys) bleiben im Geräte-Keychain und syncen NICHT.
@Observable
@MainActor
final class AccountSyncService {
    enum State: Equatable {
        case loggedOut
        case busy(String)
        case loggedIn(email: String)
    }

    private(set) var state: State = .loggedOut
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    /// Liefert den aktuellen lokalen Stand (nil-Felder = kennt diese Plattform nicht).
    @ObservationIgnored var buildPayload: (() -> AccountSyncPayload)?
    /// Wendet einen entschlüsselten Server-Stand lokal an.
    @ObservationIgnored var applyPayload: ((AccountSyncPayload) -> Void)?

    /// Konto-Sync läuft ausschließlich auf humibeam.com (früher alpvis.com).
    static let defaultSyncURL = "https://humibeam.com/humibeam-sync"

    var serverURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "account.url")
            // Einmal-Migration: alte alpvis-URL auf humibeam.com umschreiben.
            if let s = stored, s.contains("alpvis.com") {
                UserDefaults.standard.set(Self.defaultSyncURL, forKey: "account.url")
                return Self.defaultSyncURL
            }
            return stored ?? Self.defaultSyncURL
        }
        set { UserDefaults.standard.set(newValue, forKey: "account.url") }
    }

    private(set) var email: String {
        get { UserDefaults.standard.string(forKey: "account.email") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "account.email") }
    }

    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var rev = 0
    @ObservationIgnored private var lastRemote: AccountSyncPayload?
    @ObservationIgnored private var exportWork: Task<Void, Never>?
    @ObservationIgnored private var periodic: Timer?

    private var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    init() {
        if !email.isEmpty, KeychainService.load(key: .humibeamAccountToken) != nil {
            state = .loggedIn(email: email)
        }
    }

    /// Nach dem Verdrahten der Closures aufrufen: erster Sync + periodischer Abgleich.
    func start() {
        guard case .loggedIn = state else { return }
        Task { await sync() }
        periodic = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
    }

    // MARK: - Konto

    func register(email rawEmail: String, password: String) async {
        await authenticate(email: rawEmail, password: password, register: true)
    }

    func login(email rawEmail: String, password: String) async {
        await authenticate(email: rawEmail, password: password, register: false)
    }

    private func authenticate(email rawEmail: String, password: String, register: Bool) async {
        let mail = rawEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard mail.contains("@"), password.count >= 8 else {
            lastError = "E-Mail prüfen; Passwort braucht mindestens 8 Zeichen."
            return
        }
        state = .busy(register ? "registriere…" : "melde an…")
        lastError = nil
        do {
            let saltHex: String
            if register {
                saltHex = AccountCrypto.randomSaltHex()
            } else {
                let resp: [String: String] = try await request("GET", "/salt?email=\(mail.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? mail)")
                guard let s = resp["kdfSalt"] else { throw AccountError.server("Konto unbekannt") }
                saltHex = s
            }
            // PBKDF2 mit 600k Runden ist bewusst teuer → nicht auf dem Main-Thread.
            let keys = try await Task.detached(priority: .userInitiated) {
                try AccountCrypto.deriveKeys(password: password, kdfSaltHex: saltHex)
            }.value
            let body: [String: String] = register
                ? ["email": mail, "kdfSalt": saltHex, "authKey": keys.authKeyHex]
                : ["email": mail, "authKey": keys.authKeyHex]
            let resp: [String: String] = try await request("POST", register ? "/register" : "/login", body: body)
            guard let token = resp["token"] else { throw AccountError.server("kein Token erhalten") }

            try KeychainService.save(key: .humibeamAccountToken, value: token)
            try KeychainService.save(key: .humibeamAccountEncKey,
                                     value: keys.encKey.withUnsafeBytes { Data($0) }.hexString)
            self.email = mail
            state = .loggedIn(email: mail)
            dirty = true            // lokalen Stand hochladen (bzw. beim Login Server-Stand ziehen)
            start()
        } catch {
            state = .loggedOut
            lastError = friendly(error)
        }
    }

    func logout() {
        Task { try? await requestVoid("POST", "/logout") }
        KeychainService.delete(key: .humibeamAccountToken)
        KeychainService.delete(key: .humibeamAccountEncKey)
        email = ""
        state = .loggedOut
        lastSync = nil
        lastRemote = nil
        rev = 0
        periodic?.invalidate(); periodic = nil
    }

    // MARK: - Sync

    /// Debounced: Stores rufen das bei jeder Änderung auf.
    func scheduleExport() {
        guard case .loggedIn = state, !applyingRemote else { return }
        dirty = true
        exportWork?.cancel()
        exportWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func syncNow() async { dirty = true; await sync() }

    private func sync() async {
        guard case .loggedIn = state,
              let tokenKeyHex = KeychainService.load(key: .humibeamAccountEncKey),
              let encKeyData = Data(hex: tokenKeyHex) else { return }
        let encKey = SymmetricKey(data: encKeyData)
        do {
            // 1) Server-Stand ziehen und ggf. anwenden
            if let blob: BlobResponse = try await requestOptional("GET", "/blob") {
                rev = blob.rev
                let data = try AccountCrypto.decrypt(blob.payload, key: encKey)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let remote = try decoder.decode(AccountSyncPayload.self, from: data)
                let lastApplied = UserDefaults.standard.object(forKey: "account.lastApplied") as? Date ?? .distantPast
                lastRemote = remote
                if remote.updatedAt > lastApplied.addingTimeInterval(1), remote.device != deviceName {
                    applyingRemote = true
                    applyPayload?(remote)
                    applyingRemote = false
                    UserDefaults.standard.set(remote.updatedAt, forKey: "account.lastApplied")
                }
            }
            // 2) lokale Änderungen hochladen
            if dirty, let build = buildPayload {
                var payload = build()
                payload.carryForward(from: lastRemote)
                payload.updatedAt = Date()
                payload.device = deviceName
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let cipher = try AccountCrypto.encrypt(try encoder.encode(payload), key: encKey)
                do {
                    let resp: [String: Int] = try await request("PUT", "/blob",
                        body: PutBlob(rev: rev, payload: cipher, device: deviceName))
                    rev = resp["rev"] ?? rev + 1
                    dirty = false
                    lastRemote = payload
                    UserDefaults.standard.set(payload.updatedAt, forKey: "account.lastApplied")
                } catch AccountError.server(let m) where m.contains("409") {
                    // Konflikt: beim nächsten Durchlauf gewinnt der frischere Stand.
                    await sync()
                    return
                }
            }
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = friendly(error)
        }
    }

    // MARK: - HTTP

    private struct BlobResponse: Codable { let rev: Int; let payload: String }
    private struct PutBlob: Codable { let rev: Int; let payload: String; let device: String }

    private func makeRequest(_ method: String, _ path: String, bodyData: Data?) throws -> URLRequest {
        guard let url = URL(string: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw AccountError.server("ungültige Server-URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = KeychainService.load(key: .humibeamAccountToken) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = bodyData
        return req
    }

    private func perform(_ req: URLRequest) async throws -> (Data, Int) {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 {
            if let dict = try? JSONDecoder().decode([String: String].self, from: data),
               let message = dict["error"] {
                throw AccountError.server(code == 409 ? "409 Konflikt" : message)
            }
            throw AccountError.server("Server antwortete \(code)")
        }
        return (data, code)
    }

    private func request<B: Encodable, R: Decodable>(_ method: String, _ path: String, body: B) async throws -> R {
        let (data, _) = try await perform(try makeRequest(method, path, bodyData: try JSONEncoder().encode(body)))
        return try JSONDecoder().decode(R.self, from: data)
    }

    private func request<R: Decodable>(_ method: String, _ path: String) async throws -> R {
        let (data, _) = try await perform(try makeRequest(method, path, bodyData: nil))
        return try JSONDecoder().decode(R.self, from: data)
    }

    /// GET, das 204 (kein Inhalt) als nil liefert.
    private func requestOptional<R: Decodable>(_ method: String, _ path: String) async throws -> R? {
        let (data, code) = try await perform(try makeRequest(method, path, bodyData: nil))
        if code == 204 || data.isEmpty { return nil }
        return try JSONDecoder().decode(R.self, from: data)
    }

    private func requestVoid(_ method: String, _ path: String) async throws {
        _ = try await perform(try makeRequest(method, path, bodyData: nil))
    }

    private func friendly(_ error: Error) -> String {
        if let e = error as? AccountError { return e.localizedDescription }
        return (error as NSError).localizedDescription
    }
}
