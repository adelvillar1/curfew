import Foundation

// The privileged boundary (L4). The single design rule: the helper is a **catalog executor**, not a
// command executor (D20). It accepts an entry id and an action — never argv — loads the catalog
// itself, resolves the recipe, and refuses anything that is not a verified, root-requiring entry.
//
// A compromised or buggy client can therefore only ask for operations that were already reviewed,
// dated and recorded. That property is what this file exists to make testable without a signed
// helper, a Team ID, or root.

public enum HelperAction: String, Codable, Sendable {
    case stop
    case start
}

public struct HelperRequest: Codable, Sendable, Equatable {
    public var entryId: String
    public var action: HelperAction
    /// The journal sequence the caller believes this action belongs to, echoed back so a result can
    /// never be attributed to the wrong intent.
    public var intentSeq: Int

    public init(entryId: String, action: HelperAction, intentSeq: Int) {
        self.entryId = entryId
        self.action = action
        self.intentSeq = intentSeq
    }
}

public struct HelperResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var verified: Bool?
    public var status: Int32?
    public var standardOutput: String
    public var standardError: String
    public var refusal: String?
    public var intentSeq: Int

    public init(
        ok: Bool, verified: Bool?, status: Int32?, standardOutput: String = "",
        standardError: String = "", refusal: String? = nil, intentSeq: Int
    ) {
        self.ok = ok
        self.verified = verified
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.refusal = refusal
        self.intentSeq = intentSeq
    }

    public static func refused(_ reason: String, for request: HelperRequest) -> HelperResponse {
        HelperResponse(ok: false, verified: nil, status: nil, refusal: reason, intentSeq: request.intentSeq)
    }
}

/// Who is asking. Filled by the helper from the peer's audit token — never by the client.
public struct HelperCaller: Sendable, Equatable {
    public var pid: Int32
    /// Team identifier from the peer's code signature, when one could be read.
    public var teamIdentifier: String?
    /// True only when the peer's signature satisfied the requirement the helper checks.
    public var signatureValid: Bool

    public init(pid: Int32, teamIdentifier: String?, signatureValid: Bool) {
        self.pid = pid
        self.teamIdentifier = teamIdentifier
        self.signatureValid = signatureValid
    }
}

public enum HelperDecision: Sendable, Equatable {
    case allow(argv: [[String]], verify: Verification?)
    case refuse(String)
}

/// Every rule the privileged boundary applies, in one place, with no I/O.
public enum HelperPolicy {

    /// Decide a request. `argv` comes from the catalog the helper loaded itself — never from the
    /// caller.
    public static func decide(
        _ request: HelperRequest,
        caller: HelperCaller,
        catalog: Catalog,
        expectedTeamIdentifier: String?
    ) -> HelperDecision {
        guard caller.signatureValid else {
            return .refuse("caller signature could not be validated")
        }
        // A team identifier is required when the helper was built with one; a build without signing
        // (development) has none, and saying so is better than pretending the check happened.
        if let expected = expectedTeamIdentifier, caller.teamIdentifier != expected {
            return .refuse("caller team \(caller.teamIdentifier ?? "none") does not match \(expected)")
        }
        guard let entry = catalog.entry(request.entryId) else {
            return .refuse("no catalog entry '\(request.entryId)'")
        }
        if NeverList.isProtected(label: entry.id) {
            return .refuse("'\(entry.id)' is on the never-list")
        }
        guard entry.status == .verified else {
            return .refuse("'\(entry.id)' is \(entry.status.rawValue) — only verified recipes cross this boundary")
        }
        let recipe: Recipe? = request.action == .stop ? entry.stop : entry.start
        guard let recipe else {
            return .refuse("'\(entry.id)' has no \(request.action.rawValue) recipe")
        }
        // The other half of D20: work the unprivileged executor can do never crosses this boundary.
        guard recipe.needsRoot else {
            return .refuse("'\(entry.id)' does not require root — run it in the unprivileged executor")
        }
        return .allow(argv: recipe.run, verify: recipe.verify)
    }
}
