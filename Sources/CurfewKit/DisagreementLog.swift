import Foundation

/// The seven ways launchd and witr can disagree (D8), plus the record that carries the
/// evidence from both sides so the disagreement can be attributed later without re-running.
public enum DisagreementKind: String, Codable, Sendable, CaseIterable {
    case enrichMissing
    case unmanagedProcess
    case identityConflict
    case execPathConflict
    case portOwnerConflict
    case witrinvalid
}

public struct DisagreementTarget: Codable, Sendable, Equatable {
    public var label: String?
    public var pid: Int32?
    public var port: UInt16?

    public init(label: String? = nil, pid: Int32? = nil, port: UInt16? = nil) {
        self.label = label
        self.pid = pid
        self.port = port
    }
}

/// What launchd said. Typed on purpose: there is no field here that could carry argv or an
/// environment value (D18).
public struct LaunchdEvidence: Codable, Sendable, Equatable {
    public var program: String?
    public var state: String?
    public var runs: UInt64?
    public var lastExit: Int32?

    public init(program: String? = nil, state: String? = nil, runs: UInt64? = nil, lastExit: Int32? = nil) {
        self.program = program
        self.state = state
        self.runs = runs
        self.lastExit = lastExit
    }
}

/// What witr said. Also typed, and never populated from its `Env` or `Cmdline` fields.
public struct WitrEvidence: Codable, Sendable, Equatable {
    public var exe: String?
    public var sourceType: String?
    public var pid: Int32?

    public init(exe: String? = nil, sourceType: String? = nil, pid: Int32? = nil) {
        self.exe = exe
        self.sourceType = sourceType
        self.pid = pid
    }
}

public struct Verdict: Codable, Sendable, Equatable {
    public var state: String
    public var enrichment: String
    /// Always `none` in the read-only slice (D1).
    public var action: String

    public init(state: String, enrichment: String, action: String = "none") {
        self.state = state
        self.enrichment = enrichment
        self.action = action
    }
}

public struct DisagreementEvent: Sendable, Equatable {
    public var kind: DisagreementKind
    public var target: DisagreementTarget
    public var launchd: LaunchdEvidence
    public var witr: WitrEvidence
    public var verdict: Verdict
    public var note: String?

    public init(
        kind: DisagreementKind,
        target: DisagreementTarget,
        launchd: LaunchdEvidence,
        witr: WitrEvidence,
        verdict: Verdict,
        note: String? = nil
    ) {
        self.kind = kind
        self.target = target
        self.launchd = launchd
        self.witr = witr
        self.verdict = verdict
        self.note = note
    }
}

/// Append-only JSONL at `~/Library/Logs/Curfew/disagreements.jsonl`.
///
/// Three invariants it owns: a fingerprint is written at most once per window (a persistent
/// mismatch becomes a count, which is the triage signal); the file rotates; and no field can
/// carry argv or an environment value because the API only accepts typed evidence.
public final class DisagreementLog: @unchecked Sendable {
    public struct Options: Sendable {
        public var directory: URL
        public var rateLimit: TimeInterval
        public var maxBytes: Int
        public var keepFiles: Int

        public init(
            directory: URL = DisagreementLog.defaultDirectory,
            rateLimit: TimeInterval = 600,
            maxBytes: Int = 5 * 1024 * 1024,
            keepFiles: Int = 3
        ) {
            self.directory = directory
            self.rateLimit = rateLimit
            self.maxBytes = maxBytes
            self.keepFiles = keepFiles
        }
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Curfew", isDirectory: true)
    }

    private let options: Options
    private let now: @Sendable () -> Date
    private let macos: String
    private let witrVersion: String?
    private let lock = NSLock()
    private var lastWritten: [String: Date] = [:]
    private var suppressed: [String: UInt32] = [:]
    private var inMemorySuggestions: [DisagreementRecord] = []

    public init(
        options: Options = Options(),
        now: @escaping @Sendable () -> Date = { Date() },
        macos: String = SystemVersion.shellVersion().version,
        witrVersion: String? = nil
    ) {
        self.options = options
        self.now = now
        self.macos = macos
        self.witrVersion = witrVersion
    }

    public var fileURL: URL {
        options.directory.appendingPathComponent("disagreements.jsonl")
    }

    /// Record a disagreement. Returns true when a line was written, false when it was
    /// rate-limited into the suppressed count.
    @discardableResult
    public func record(_ event: DisagreementEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let fingerprint = Self.fingerprint(event)
        let timestamp = now()

        if let last = lastWritten[fingerprint], timestamp.timeIntervalSince(last) < options.rateLimit {
            suppressed[fingerprint, default: 0] += 1
            return false
        }

        let suppressedCount = suppressed.removeValue(forKey: fingerprint)
        lastWritten[fingerprint] = timestamp

        let record = DisagreementRecord(
            v: 1,
            ts: Self.isoTimestamp(timestamp),
            curfew: curfewVersion,
            macos: macos,
            witrVersion: witrVersion,
            kind: event.kind,
            fingerprint: fingerprint,
            target: event.target,
            launchd: event.launchd,
            witrEvidence: event.witr,
            verdict: event.verdict,
            suppressed: (suppressedCount ?? 0) > 0 ? suppressedCount : nil,
            note: event.note
        )

        do {
            try append(record)
            return true
        } catch {
            // A log that cannot be written must not take the command down with it.
            inMemorySuggestions.append(record)
            return false
        }
    }

    /// Grouped counts for `curfew doctor --disagreements`, read back from disk.
    public func summarize() -> [DisagreementCount] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var counts: [String: DisagreementCount] = [:]
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            guard let record = try? decoder.decode(DisagreementRecord.self, from: Data(line.utf8)) else { continue }
            var entry = counts[record.fingerprint] ?? DisagreementCount(
                fingerprint: record.fingerprint,
                kind: record.kind,
                count: 0,
                firstSeen: record.ts,
                lastSeen: record.ts
            )
            entry.count += 1 + Int(record.suppressed ?? 0)
            entry.lastSeen = record.ts
            counts[record.fingerprint] = entry
        }
        return counts.values.sorted { $0.count > $1.count }
    }

    // MARK: Plumbing

    private func append(_ record: DisagreementRecord) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: options.directory, withIntermediateDirectories: true)
        try rotateIfNeeded()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0A)

        if fm.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: fileURL, options: .atomic)
        }
    }

    private func rotateIfNeeded() throws {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int, size >= options.maxBytes
        else { return }

        // shift .n → .n+1, dropping the oldest
        for index in stride(from: options.keepFiles - 1, through: 1, by: -1) {
            let from = options.directory.appendingPathComponent("disagreements.jsonl.\(index)")
            let to = options.directory.appendingPathComponent("disagreements.jsonl.\(index + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
        }
        let first = options.directory.appendingPathComponent("disagreements.jsonl.1")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: fileURL, to: first)
    }

    static func fingerprint(_ event: DisagreementEvent) -> String {
        let parts = [
            event.kind.rawValue,
            event.target.label ?? "-",
            event.target.pid.map(String.init) ?? "-",
            event.target.port.map(String.init) ?? "-",
        ]
        return "sha1:" + SHA1.hex(parts.joined(separator: "|")).prefix(16)
    }

    /// A fresh formatter per write: `ISO8601DateFormatter` is not `Sendable`, and one line per
    /// ten minutes does not need a shared instance.
    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// The on-disk shape. Every field is typed; there is nowhere for argv or env to go (D18).
public struct DisagreementRecord: Codable, Sendable, Equatable {
    public var v: Int
    public var ts: String
    public var curfew: String
    public var macos: String
    public var witrVersion: String?
    public var kind: DisagreementKind
    public var fingerprint: String
    public var target: DisagreementTarget
    public var launchd: LaunchdEvidence
    public var witrEvidence: WitrEvidence
    public var verdict: Verdict
    public var suppressed: UInt32?
    public var note: String?

    enum CodingKeys: String, CodingKey {
        case v, ts, curfew, macos
        case witrVersion = "witrVersion"
        case kind, fingerprint, target, launchd, verdict, suppressed, note
        case witrEvidence = "witrEvidence"
    }

    public init(
        v: Int, ts: String, curfew: String, macos: String, witrVersion: String?,
        kind: DisagreementKind, fingerprint: String, target: DisagreementTarget,
        launchd: LaunchdEvidence, witrEvidence: WitrEvidence, verdict: Verdict,
        suppressed: UInt32?, note: String?
    ) {
        self.v = v
        self.ts = ts
        self.curfew = curfew
        self.macos = macos
        self.witrVersion = witrVersion
        self.kind = kind
        self.fingerprint = fingerprint
        self.target = target
        self.launchd = launchd
        self.witrEvidence = witrEvidence
        self.verdict = verdict
        self.suppressed = suppressed
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        ts = try c.decode(String.self, forKey: .ts)
        curfew = try c.decodeIfPresent(String.self, forKey: .curfew) ?? "?"
        macos = try c.decodeIfPresent(String.self, forKey: .macos) ?? "?"
        witrVersion = try c.decodeIfPresent(String.self, forKey: .witrVersion)
        kind = try c.decode(DisagreementKind.self, forKey: .kind)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        target = try c.decode(DisagreementTarget.self, forKey: .target)
        launchd = try c.decode(LaunchdEvidence.self, forKey: .launchd)
        witrEvidence = try c.decode(WitrEvidence.self, forKey: .witrEvidence)
        verdict = try c.decode(Verdict.self, forKey: .verdict)
        suppressed = try c.decodeIfPresent(UInt32.self, forKey: .suppressed)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(ts, forKey: .ts)
        try c.encode(curfew, forKey: .curfew)
        try c.encode(macos, forKey: .macos)
        try c.encodeIfPresent(witrVersion, forKey: .witrVersion)
        try c.encode(kind, forKey: .kind)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(target, forKey: .target)
        try c.encode(launchd, forKey: .launchd)
        try c.encode(witrEvidence, forKey: .witrEvidence)
        try c.encode(verdict, forKey: .verdict)
        try c.encodeIfPresent(suppressed, forKey: .suppressed)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

public struct DisagreementCount: Codable, Sendable, Equatable {
    public var fingerprint: String
    public var kind: DisagreementKind
    public var count: Int
    public var firstSeen: String
    public var lastSeen: String
}

/// A stable, dependency-free digest for fingerprints. Not a security primitive — it only has to
/// make the same disagreement group with itself.
enum SHA1 {
    static func hex(_ string: String) -> String {
        var digest: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var message = Array(string.utf8)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let base = chunk + i * 4
                w[i] = (UInt32(message[base]) << 24) | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8) | UInt32(message[base + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }

            var a = digest[0], b = digest[1], c = digest[2], d = digest[3], e = digest[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = temp
            }
            digest[0] = digest[0] &+ a; digest[1] = digest[1] &+ b; digest[2] = digest[2] &+ c
            digest[3] = digest[3] &+ d; digest[4] = digest[4] &+ e
        }
        return digest.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}
