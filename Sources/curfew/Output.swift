import Foundation
import CurfewKit

// MARK: - Exit codes (contract C7 — normative, documented, and tested)

enum ExitCode: Int32 {
    case clean = 0
    case warnings = 1
    case notFound = 2
    case dependencyMissing = 3
    case badInput = 4
    case internalError = 5
    case readOnlyViolated = 6
}

// MARK: - Text rendering

enum Render {

    static func table(_ rows: [[String]], headers: [String]) -> String {
        guard !rows.isEmpty else { return headers.joined(separator: "  ") }
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        var out = [line(headers)]
        out.append(contentsOf: rows.map(line))
        return out.joined(separator: "\n")
    }

    static func state(_ record: ServiceRecord) -> String {
        switch record.state {
        case .running: return "running" + (record.pid.map { " (\($0))" } ?? "")
        case .spawnScheduled: return "spawn scheduled"
        case .notLoaded: return "not loaded"
        case .disabled: return "disabled"
        case .unknown: return "unknown"
        }
    }

    static func findings(_ reports: [FindingReport]) -> String {
        guard !reports.isEmpty else { return "no findings" }
        return reports.map { report in
            let where_ = report.label ?? "(machine)"
            return "  \(report.severity.uppercased())  \(where_): \(report.summary)\n         ↳ \(report.evidence)"
        }.joined(separator: "\n")
    }
}
