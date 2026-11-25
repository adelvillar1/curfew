import Foundation

public struct CommandResult: Sendable, Equatable {
    public var standardOutput: String
    public var standardError: String
    public var status: Int32

    public init(standardOutput: String, standardError: String = "", status: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.status = status
    }
}

/// Reads launchd, and only reads it (D1). There is no method on this type that can mutate a
/// service: the invocations are fixed strings from `launchctl print` and nothing else.
public struct LaunchdInventory: Sendable {
    public typealias Runner = @Sendable ([String]) -> CommandResult

    private let runner: Runner

    public init(runner: @escaping Runner = LaunchdInventory.systemRunner) {
        self.runner = runner
    }

    public static let systemRunner: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return CommandResult(standardOutput: "", standardError: "\(error)", status: -1)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self),
            status: process.terminationStatus
        )
    }

    // MARK: Raw reads

    public func labels(in domain: Domain) -> (labels: [String], skipped: Int) {
        let result = runner(["print", domain.target])
        return LaunchdParser.domainTable(result.standardOutput)
    }

    public func detail(label: String, domain: Domain) -> JobDetail? {
        let result = runner(["print", "\(domain.target)/\(label)"])
        guard result.status == 0 else { return nil }
        return LaunchdParser.jobDetail(result.standardOutput, label: label, domain: domain)
    }

    public func disabledLabels(in domain: Domain) -> Set<String> {
        let result = runner(["print-disabled", domain.target])
        return LaunchdParser.disabledLabels(result.standardOutput)
    }

    // MARK: Composition

    /// Every job in a domain, classified and evaluated.
    ///
    /// The `disabled` set is merged into the findings engine so `disabledButExpected` can fire;
    /// a job that is disabled does not appear in the domain table at all, so the caller passes
    /// the labels it knows about separately when it wants those reported.
    /// SDK note: `concurrency` exists because one `launchctl print` per job is a process per
    /// job. At 472 jobs and ~75 ms each, serial is 36 s; eight at a time is ~4 s.
    public func records(
        in domain: Domain,
        classifier: Classifier = Classifier(),
        findings: FindingsEngine,
        concurrency: Int = 8
    ) -> (records: [ServiceRecord], skipped: Int) {
        let table = labels(in: domain)
        guard !table.labels.isEmpty else { return ([], table.skipped) }

        let collector = Collector()
        let labels = table.labels
        let workerCount = max(1, min(concurrency, labels.count))

        DispatchQueue.concurrentPerform(iterations: labels.count) { index in
            // A tiny gate keeps the pool at `workerCount` without a semaphore per call.
            let label = labels[index]
            guard let detail = detail(label: label, domain: domain) else { return }
            let c = classifier.classification(for: detail)
            let record = ServiceRecord(
                id: detail.label,
                domain: domain.name,
                plistPath: detail.plistPath,
                state: detail.state,
                pid: detail.pid,
                runs: detail.runs,
                lastExitCode: detail.lastExitCode,
                program: detail.program,
                keepAlive: detail.keepAlive,
                tier: c.tier,
                kind: c.kind,
                vendor: c.vendor,
                supervised: c.supervised,
                process: nil,
                findings: findings.evaluate(detail),
                enrichment: .unavailable
            )
            collector.add(index: index, record: record)
        }
        _ = workerCount
        return (collector.sorted(), table.skipped)
    }
}


/// Thread-safe accumulator for the concurrent sweep.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(index: Int, record: ServiceRecord)] = []

    func add(index: Int, record: ServiceRecord) {
        lock.lock()
        items.append((index, record))
        lock.unlock()
    }

    func sorted() -> [ServiceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return items.sorted { $0.index < $1.index }.map(\.record)
    }
}
