import Foundation

/// Leichtgewichtige Server-Vitalwerte, alle 30 s per Exec-Channel gesammelt (Linux-Server;
/// fehlende Werte bleiben nil und werden ausgeblendet).
struct ServerStats: Equatable {
    var load1: Double?
    var cores: Int?
    var memUsedPercent: Int?
    var diskPercent: Int?
    var zombies: Int?
    var date = Date()

    /// Ein einziger Roundtrip; Felder Semikolon-getrennt hinter "H:".
    static let command = #"echo "H:$(cut -d' ' -f1 /proc/loadavg 2>/dev/null);$(nproc 2>/dev/null);$(free 2>/dev/null | awk '/Mem:/{printf "%d", $3*100/$2}');$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","");print $5}');$(ps -eo stat 2>/dev/null | grep -c '^Z')""#

    static func parse(_ output: String) -> ServerStats? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("H:") }) else { return nil }
        let f = line.dropFirst(2).components(separatedBy: ";")
        guard f.count >= 5 else { return nil }
        var s = ServerStats()
        s.load1 = Double(f[0])
        s.cores = Int(f[1])
        s.memUsedPercent = Int(f[2])
        s.diskPercent = Int(f[3])
        s.zombies = Int(f[4])
        return s
    }

    var isCritical: Bool {
        if let d = diskPercent, d >= 90 { return true }
        if let z = zombies, z >= 50 { return true }
        if let m = memUsedPercent, m >= 92 { return true }
        if let l = load1, let c = cores, c > 0, l > Double(c) * 1.5 { return true }
        return false
    }

    var summary: String {
        var parts: [String] = []
        if let l = load1 { parts.append(String(format: "Load %.2f", l)) }
        if let m = memUsedPercent { parts.append("RAM \(m)%") }
        if let d = diskPercent { parts.append("Disk \(d)%") }
        if let z = zombies, z > 0 { parts.append("\(z) Zombies") }
        return parts.joined(separator: " · ")
    }
}
