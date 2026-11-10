import Foundation
import Security

/// Result of verifying an app bundle.
public struct VerifiedBundle: Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: AppVersion?
    public let teamIdentifier: String
}

public enum VerificationError: LocalizedError, Equatable {
    case notABundle(String)
    case signatureInvalid(String)
    case wrongTeam(String?)
    case wrongBundleIdentifier(String?)
    case wrongVersion(expected: String, found: String?)
    case checksumMismatch(expected: String, found: String)

    public var errorDescription: String? {
        switch self {
        case .notABundle(let p): return "\(p) is not an app bundle."
        case .signatureInvalid(let m): return "Code signature check failed: \(m)"
        case .wrongTeam(let t): return "Signed by unexpected team \(t ?? "none") (expected \(ClaudeConstants.teamIdentifier))."
        case .wrongBundleIdentifier(let b): return "Unexpected bundle identifier \(b ?? "none")."
        case .wrongVersion(let e, let f): return "Expected version \(e) but the bundle says \(f ?? "nothing")."
        case .checksumMismatch(let e, let f): return "Download checksum mismatch (expected \(e), got \(f))."
        }
    }
}

public protocol BundleVerifying: Sendable {
    func verify(appAt url: URL) throws -> VerifiedBundle
}

/// Verifies a bundle is validly signed (deep, strict) by Anthropic's Developer ID team and is Claude.
public struct ClaudeSignatureVerifier: BundleVerifying {
    public let teamIdentifier: String
    public let bundleIdentifier: String

    public init(teamIdentifier: String = ClaudeConstants.teamIdentifier,
                bundleIdentifier: String = ClaudeConstants.bundleIdentifier) {
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
    }

    public func verify(appAt url: URL) throws -> VerifiedBundle {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else {
            throw VerificationError.notABundle(url.path)
        }
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(bundleIdentifier)\""
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard status == errSecSuccess else { throw VerificationError.signatureInvalid("bad requirement (\(status))") }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var cfError: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &cfError)
        guard status == errSecSuccess else {
            let message = (cfError?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(status)"
            throw VerificationError.signatureInvalid(message)
        }

        var infoRef: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        guard status == errSecSuccess, let info = infoRef as? [String: Any] else {
            throw VerificationError.signatureInvalid("no signing information (\(status))")
        }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        guard team == teamIdentifier else { throw VerificationError.wrongTeam(team) }
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        guard identifier == bundleIdentifier else { throw VerificationError.wrongBundleIdentifier(identifier) }
        let plist = info[kSecCodeInfoPList as String] as? [String: Any]
        let version = (plist?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        return VerifiedBundle(bundleIdentifier: bundleIdentifier, version: version, teamIdentifier: teamIdentifier)
    }
}
