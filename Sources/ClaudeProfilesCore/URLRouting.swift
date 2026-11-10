import AppKit
import Carbon
import Foundation

/// Decides which running Claude instance should receive a `claude://` link (e.g. a sign-in callback).
///
/// Why this exists: with several Claude instances running, macOS (LaunchServices) delivers a
/// `claude://` URL to the *oldest* running instance, not the one the user is signing in to.
/// Claude Profiles makes itself the `claude://` handler and forwards each URL as a `GURL` Apple Event
/// addressed to one specific PID.
public enum URLRoutingPolicy {
    public struct Candidate: Equatable, Sendable {
        public let pid: pid_t
        public let profileID: String?
        public let lastActivated: Date?
        public let startTime: Date
        public init(pid: pid_t, profileID: String?, lastActivated: Date?, startTime: Date) {
            self.pid = pid; self.profileID = profileID; self.lastActivated = lastActivated; self.startTime = startTime
        }
    }

    public enum Decision: Equatable, Sendable {
        case forward(pid_t)
        /// No suitable instance is running: launch this profile with the URL.
        case launch(profileID: String)
    }

    /// - Parameters:
    ///   - signingInProfileID: profile explicitly marked "Signing in" (wins while it's running).
    ///   - candidates: running instances.
    public static func decide(signingInProfileID: String?, candidates: [Candidate]) -> Decision {
        if let target = signingInProfileID,
           let inst = candidates.filter({ $0.profileID == target }).max(by: { $0.startTime < $1.startTime }) {
            return .forward(inst.pid)
        }
        // Most recently activated instance (the window the user was just looking at).
        let ranked = candidates.sorted {
            ($0.lastActivated ?? $0.startTime) > ($1.lastActivated ?? $1.startTime)
        }
        if let best = ranked.first { return .forward(best.pid) }
        return .launch(profileID: signingInProfileID ?? Profile.defaultProfileID)
    }
}

public enum URLForwarder {
    /// Sends a kAEGetURL ("GURL") Apple Event to exactly one process, the same event LaunchServices
    /// would send. Electron turns it into `app.on("open-url")` in that instance only.
    public static func sendGetURL(_ url: String, to pid: pid_t, timeout: TimeInterval = 10) throws {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                                           eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: url), forKeyword: AEKeyword(keyDirectObject))
        _ = try event.sendEvent(options: [.waitForReply], timeout: timeout)
    }
}

/// Reads and changes the system default handler for the `claude` URL scheme.
@MainActor
public enum URLHandlerRegistration {
    public static func currentHandlerBundleID(scheme: String = ClaudeConstants.urlScheme) -> String? {
        guard let url = URL(string: "\(scheme)://probe"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    public static func setHandler(appURL: URL, scheme: String = ClaudeConstants.urlScheme) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme)
    }
}
