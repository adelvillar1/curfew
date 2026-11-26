import Foundation

/// The write-ahead journal (rule 2): an intent is on disk before the action runs.
///
/// Append-only JSONL. A truncated final line is ignored rather than fatal — a crash mid-write must not
/// make the journal unreadable, and the half-written record must never be mistaken for a completed
/// action. An unreadable journal means *refuse to act*, never guess.
public enum JournalKind: String, Codable, Sendable {
    case intent
    case outcome
}

public struct JournalRecord: Codable, Sendable, Equatable {
    public var v: Int
    public var seq: Int
    public var ts: String
    public var kind: JournalKind
    /// Present on `intent`.
    public var entryId: String?
    public var action: String?
    public var argv: [[String]]?
    /// Present on `outcome`: the `seq` of the intent it answers.
    public var intent: Int?
    public var result: String?
    public var verified: Bool?
    public var error: String?
    /// Set when the service was already in that state before Curfew touched it (rule 6: never
    /// resurrect what we did not stop).
    public var preExisting: String?

    public init(
        v: Int = 1, seq: Int, ts: String, kind: JournalKind,
        entryId: String? = nil, action: String? = nil, argv: [[String]]? = nil,
        intent: Int? = nil, result: String? = nil, verified: Bool? = nil, error: String? = nil,
        preExisting: String? = nil
    ) {
        self.v = v
        self.seq = seq
        self.ts = ts
        self.kind = kind
        self.entryId = entryId
        self.action = action
        self.argv = argv
        self.intent = intent
        self.result = result
        self.verified = verified
        self.error = error
        self.preExisting = preExisting
    }
}

public struct JournalError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

public final class Journal: @unchecked Sendable {
    public let url: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var nextSeq: Int

    public init(url: URL = Journal.defaultURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
        let existing = Self.readAll(at: url)
        self.nextSeq = (existing.map(\.seq).max() ?? 0) + 1
    }

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["CURFEW_JOURNAL"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Curfew/journal.jsonl")
    }

    // MARK: Writing

    /// Write an intent and flush it. Returns the `seq` an outcome must cite.
    ///
    /// If this throws, the caller must not act: the point of the write-ahead journal is that an
    /// action without a durable intent cannot happen (rule 2).
    @discardableResult
    public func appendIntent(
        entryId: String, action: String, argv: [[String]], preExisting: String? = nil
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let seq = nextSeq
        let record = JournalRecord(
            seq: seq, ts: Self.iso(now()), kind: .intent,
            entryId: entryId, action: action, argv: argv, preExisting: preExisting
        )
        try append(record)
        nextSeq += 1
        return seq
    }

    public func appendOutcome(intent: Int, result: String, verified: Bool?, error: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let record = JournalRecord(
            seq: nextSeq, ts: Self.iso(now()), kind: .outcome,
            intent: intent, result: result, verified: verified, error: error
        )
        try append(record)
        nextSeq += 1
    }

    // MARK: Reading

    public func records() -> [JournalRecord] { Self.readAll(at: url) }

    /// Intents with no outcome — what the machine may be left holding.
    public func unresolved() -> [JournalRecord] {
        let all = records()
        let answered = Set(all.compactMap { $0.kind == .outcome ? $0.intent : nil })
        return all.filter { $0.kind == .intent && !answered.contains($0.seq) }
    }

    /// What Curfew is holding right now: intents whose action **succeeded** and that have not been
    /// restored. This is what quiet mode *is*. `unresolved()` answers a different question — a run that
    /// died mid-action — and keying quiet mode off it made a successful apply read as "nothing to
    /// restore" the instant it finished (KI-045).
    public func held() -> [JournalRecord] {
        let all = records()
        let succeeded = Set(all.compactMap { record in
            record.kind == .outcome && record.result == "ok" ? record.intent : nil
        })
        // `resume` closes an intent with a "resumed" outcome; that takes it out of the set.
        let restored = Set(all.compactMap { record in
            record.kind == .outcome && record.result == "resumed" ? record.intent : nil
        })
        return all.filter { record in
            // A `resume` writes its own intent for the undo action. Its "ok" outcome must not make it
            // look like a change Curfew is holding — that would leave a phantom entry after every
            // restore, and quiet mode would never read as off again.
            record.kind == .intent
                && record.action != "resume"
                && succeeded.contains(record.seq)
                && !restored.contains(record.seq)
        }
    }

    /// Everything a resume would put back, newest first: the last thing started is the first to undo.
    ///
    /// The union of two populations, because both may have changed the machine:
    /// - `held()` — the action succeeded and was not undone (normal quiet mode);
    /// - `unresolved()` — the run died between intent and outcome, so the action may have happened
    ///   (crash recovery). Dropping these from the plan would silently strand a half-applied run.
    public func restorePlan() -> [JournalRecord] {
        let both = unresolved() + held()
        var seen = Set<Int>()
        return both
            .filter { seen.insert($0.seq).inserted }
            .sorted { $0.seq > $1.seq }
    }

    public func isReadable() -> Bool {
        !FileManager.default.fileExists(atPath: url.path) || (try? Data(contentsOf: url)) != nil
    }

    // MARK: Plumbing

    private func append(_ record: JournalRecord) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw JournalError(message: "cannot create \(directory.path): \(error)")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0A)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw JournalError(message: "cannot open \(url.path) for writing — refusing to act without a journal")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            // The durability this rule needs: on disk before the runner is called.
            try handle.synchronize()
        } catch {
            throw JournalError(message: "cannot write the journal at \(url.path): \(error)")
        }
    }

    static func readAll(at url: URL) -> [JournalRecord] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        let decoder = JSONDecoder()
        var out: [JournalRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // A truncated final line is a crash, not a record: skip it, keep the rest.
            if let record = try? decoder.decode(JournalRecord.self, from: Data(line.utf8)) {
                out.append(record)
            }
        }
        return out
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Parses a journal timestamp. A fresh formatter per call: `ISO8601DateFormatter` is not
/// `Sendable`, and one read per status run does not need a shared instance.
public func parseJournalTimestamp(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}
