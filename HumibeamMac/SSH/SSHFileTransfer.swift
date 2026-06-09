import Foundation

struct RemoteFile: Identifiable, Hashable {
    var name: String
    var isDirectory: Bool
    var id: String { name }
}

/// A richer directory entry for the file manager (size, permissions, modified date, symlink).
struct RemoteEntry: Identifiable, Hashable {
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool = false
    var size: Int64 = 0
    var permissions: String = ""
    var modified: String = ""
    var id: String { name }

    var displaySize: String {
        if isDirectory { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(size); var i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        return i == 0 ? "\(size) B" : String(format: "%.1f %@", value, units[i])
    }
}

/// File transfer over exec channels — no SFTP subsystem required (works on stock Ubuntu).
/// (M1 proved `cat`-based upload is bit-identical; download + listing use the same approach.)
extension SSHConnection {

    /// Resolves the remote home directory.
    func remoteHome() async throws -> String {
        let (_, out, _) = try await exec("printf %s \"$HOME\"")
        let home = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return home.isEmpty ? "/" : home
    }

    /// Lists a directory. Names ending in `/` are directories (`ls -1Ap`).
    func listDirectory(_ path: String) async throws -> [RemoteFile] {
        let quoted = Self.shellQuote(path)
        let (status, out, err) = try await exec("ls -1Ap \(quoted)")
        guard status == 0 else {
            throw SSHError.commandFailed(status, String(decoding: err, as: UTF8.self))
        }
        let lines = String(decoding: out, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        return lines.map { line in
            if line.hasSuffix("/") {
                return RemoteFile(name: String(line.dropLast()), isDirectory: true)
            }
            return RemoteFile(name: line, isDirectory: false)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    /// Detailed listing (size, permissions, modified date) for the file manager, via `ls -lAp`.
    func listDetailed(_ path: String) async throws -> [RemoteEntry] {
        let quoted = Self.shellQuote(path)
        let (status, out, err) = try await exec("LC_ALL=C ls -lApL --time-style=long-iso \(quoted)")
        guard status == 0 else {
            throw SSHError.commandFailed(status, String(decoding: err, as: UTF8.self))
        }
        var result: [RemoteEntry] = []
        for raw in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            let line = String(raw)
            if line.isEmpty || line.hasPrefix("total ") { continue }
            guard line.count > 11 else { continue }

            let typeChar = line.first!
            let permsStart = line.index(line.startIndex, offsetBy: 1)
            let permsEnd = line.index(line.startIndex, offsetBy: 10)
            let perms = String(line[permsStart..<permsEnd])

            // perms+type | links | owner | group | size | date | time | name…
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 8 else { continue }
            let size = Int64(fields[4]) ?? 0
            let modified = "\(fields[5]) \(fields[6])"
            var name = fields[7...].joined(separator: " ")

            let isSymlink = typeChar == "l"
            if isSymlink, let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            var isDir = typeChar == "d"
            if name.hasSuffix("/") { name = String(name.dropLast()); isDir = true }
            if name == "." || name == ".." || name.isEmpty { continue }

            result.append(RemoteEntry(name: name, isDirectory: isDir, isSymlink: isSymlink,
                                      size: size, permissions: perms, modified: modified))
        }
        return result.sorted {
            ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased())
        }
    }

    /// Downloads a remote file's bytes (`cat`). Binary-safe (collected as Data).
    func download(_ remotePath: String) async throws -> Data {
        let quoted = Self.shellQuote(remotePath)
        let (status, out, err) = try await exec("cat \(quoted)")
        guard status == 0 else {
            throw SSHError.commandFailed(status, String(decoding: err, as: UTF8.self))
        }
        return out
    }

    func makeDirectory(_ path: String) async throws { try await run("mkdir -p \(Self.shellQuote(path))") }

    func remove(_ path: String, recursive: Bool) async throws {
        try await run("rm -\(recursive ? "rf" : "f") \(Self.shellQuote(path))")
    }

    func rename(_ from: String, to dest: String) async throws {
        try await run("mv \(Self.shellQuote(from)) \(Self.shellQuote(dest))")
    }

    func chmod(_ path: String, mode: String) async throws {
        try await run("chmod \(Self.shellQuote(mode)) \(Self.shellQuote(path))")
    }

    /// Downloads a remote directory as a gzip tarball (recursive). Streamed via `tar … | stdout`.
    func downloadFolderTarGz(_ path: String) async throws -> Data {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let (status, out, err) = try await exec("tar -czf - -C \(Self.shellQuote(parent)) \(Self.shellQuote(name))")
        guard status == 0 else { throw SSHError.commandFailed(status, String(decoding: err, as: UTF8.self)) }
        return out
    }

    private func run(_ command: String) async throws {
        let (status, _, err) = try await exec(command)
        guard status == 0 else { throw SSHError.commandFailed(status, String(decoding: err, as: UTF8.self)) }
    }
}
