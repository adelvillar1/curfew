import Foundation

/// A deliberately tiny YAML subset: block maps, block lists, inline scalar lists, comments.
///
/// Why not a dependency: this parser reads **stop recipes**, so the failure mode of a permissive
/// parser is executing the wrong command. This one accepts only what the catalog documents and
/// throws on everything else — block scalars, anchors, tabs, multi-document files, quoted keys.
/// A strict parser that refuses is safer than a clever one that guesses.
public enum YAMLValue: Equatable, Sendable {
    case scalar(String)
    case list([YAMLValue])
    case map([(String, YAMLValue)])

    /// Tuple arrays are not `Equatable` for free; keys are unique and order-preserving, so a
    /// positional compare is exact.
    public static func == (lhs: YAMLValue, rhs: YAMLValue) -> Bool {
        switch (lhs, rhs) {
        case (.scalar(let a), .scalar(let b)):
            return a == b
        case (.list(let a), .list(let b)):
            return a == b
        case (.map(let a), .map(let b)):
            guard a.count == b.count else { return false }
            for (index, pair) in a.enumerated() where b[index].0 != pair.0 || b[index].1 != pair.1 {
                return false
            }
            return true
        default:
            return false
        }
    }

    public subscript(key: String) -> YAMLValue? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }
}

public struct YAMLError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "line \(line): \(message)" }
}

public enum MiniYAML {

    public static func parse(_ text: String) throws -> YAMLValue {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines: [(indent: Int, content: String, number: Int)] = []
        for (index, raw) in rawLines.enumerated() {
            let number = index + 1
            if raw.contains("\t") {
                throw YAMLError(line: number, message: "tab indentation is not allowed — use two spaces")
            }
            let stripped = stripComment(raw)
            if stripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indent = stripped.prefix { $0 == " " }.count
            if indent % 2 != 0 {
                throw YAMLError(line: number, message: "indentation must be a multiple of two spaces")
            }
            lines.append((indent, stripped.trimmingCharacters(in: .whitespaces), number))
        }
        guard !lines.isEmpty else { return .map([]) }
        if lines[0].content == "---" || lines[0].content == "..." {
            throw YAMLError(line: 1, message: "multi-document files are not supported")
        }
        var cursor = 0
        let value = try parseBlock(lines, &cursor, indent: lines[0].indent)
        if cursor < lines.count {
            throw YAMLError(line: lines[cursor].number, message: "unexpected content after the document")
        }
        return value
    }

    // MARK: Block

    private static func parseBlock(
        _ lines: [(indent: Int, content: String, number: Int)],
        _ cursor: inout Int,
        indent: Int
    ) throws -> YAMLValue {
        guard cursor < lines.count else { return .map([]) }
        if lines[cursor].content.hasPrefix("- ") || lines[cursor].content == "-" {
            return try parseList(lines, &cursor, indent: indent)
        }
        return try parseMap(lines, &cursor, indent: indent)
    }

    private static func parseList(
        _ lines: [(indent: Int, content: String, number: Int)],
        _ cursor: inout Int,
        indent: Int
    ) throws -> YAMLValue {
        var items: [YAMLValue] = []
        while cursor < lines.count, lines[cursor].indent == indent,
              lines[cursor].content.hasPrefix("-") {
            let line = lines[cursor]
            let rest = line.content.dropFirst().trimmingCharacters(in: .whitespaces)
            cursor += 1
            if rest.isEmpty {
                guard cursor < lines.count, lines[cursor].indent > indent else {
                    throw YAMLError(line: line.number, message: "list item has no value")
                }
                items.append(try parseBlock(lines, &cursor, indent: lines[cursor].indent))
            } else if rest.hasPrefix("[") {
                items.append(try parseScalar(rest, line: line.number))
            } else if rest.contains(": "), !rest.hasPrefix("[") {
                // `- id: x` starts a map whose remaining keys are indented further
                var pairs: [(String, YAMLValue)] = []
                let (key, value) = try splitKeyValue(rest, line: line.number)
                pairs.append((key, value))
                if cursor < lines.count, lines[cursor].indent > indent {
                    let childIndent = lines[cursor].indent
                    let nested = try parseMap(lines, &cursor, indent: childIndent)
                    if case .map(let more) = nested { pairs.append(contentsOf: more) }
                }
                items.append(.map(pairs))
            } else {
                items.append(.scalar(rest))
            }
        }
        return .list(items)
    }

    private static func parseMap(
        _ lines: [(indent: Int, content: String, number: Int)],
        _ cursor: inout Int,
        indent: Int
    ) throws -> YAMLValue {
        var pairs: [(String, YAMLValue)] = []
        var seen: Set<String> = []

        while cursor < lines.count, lines[cursor].indent == indent {
            let line = lines[cursor]
            guard !line.content.hasPrefix("-") else { break }
            let (key, inline) = try splitKeyValue(line.content, line: line.number)
            if seen.contains(key) {
                throw YAMLError(line: line.number, message: "duplicate key '\(key)'")
            }
            seen.insert(key)
            cursor += 1

            if case .scalar(let text) = inline, text.isEmpty {
                // nested block
                if cursor < lines.count, lines[cursor].indent > indent {
                    pairs.append((key, try parseBlock(lines, &cursor, indent: lines[cursor].indent)))
                } else {
                    pairs.append((key, .scalar("")))
                }
            } else {
                pairs.append((key, inline))
            }
        }
        return .map(pairs)
    }

    // MARK: Scalars

    private static func splitKeyValue(_ content: String, line: Int) throws -> (String, YAMLValue) {
        guard let colon = content.firstIndex(of: ":") else {
            throw YAMLError(line: line, message: "expected 'key: value'")
        }
        let key = String(content[content.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw YAMLError(line: line, message: "empty key") }
        guard !key.hasPrefix("\"") && !key.hasPrefix("'") else {
            throw YAMLError(line: line, message: "quoted keys are not supported")
        }
        let raw = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, try parseScalar(raw, line: line))
    }

    private static func parseScalar(_ raw: String, line: Int) throws -> YAMLValue {
        if raw.isEmpty { return .scalar("") }
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]") else {
                throw YAMLError(line: line, message: "unterminated inline list")
            }
            let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .list([]) }
            let parts = inner.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return .list(parts.map { .scalar(unquote($0)) })
        }
        if raw.hasPrefix("|") || raw.hasPrefix(">") || raw.hasPrefix("&") || raw.hasPrefix("*") {
            throw YAMLError(line: line, message: "block scalars, anchors and aliases are not supported")
        }
        if raw.hasPrefix("{") {
            throw YAMLError(line: line, message: "inline maps are not supported — use an indented block")
        }
        return .scalar(unquote(raw))
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if text.hasPrefix("\""), text.hasSuffix("\"") {
            return String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func stripComment(_ raw: String) -> String {
        var inSingle = false, inDouble = false
        var out = ""
        for character in raw {
            if character == "'" && !inDouble { inSingle.toggle() }
            if character == "\"" && !inSingle { inDouble.toggle() }
            if character == "#" && !inSingle && !inDouble { break }
            out.append(character)
        }
        return out
    }
}
