import Foundation

/// A release advertised by Claude's official Squirrel JSON update feed.
public struct AvailableRelease: Equatable, Sendable, Codable {
    public let version: AppVersion
    public let name: String?
    public let downloadURL: URL
    public let sha256: String?
    public let size: Int64?
    public let publishedAt: String?
    public let notes: String?
}

/// Reads the same feed Claude's own updater uses (read-only GET; nothing is reported back besides the query).
///
/// Claude builds the URL as
/// `<base>/api/desktop/darwin/<arch>/squirrel/update?device_id=…&version=…&os_version=…`
/// where base is `https://api.anthropic.com` (or `https://releases.claude.com` when the
/// "Check for updates on releases.claude.com" setting is on) and arch is `arm64` on Apple silicon
/// (after a probe) or `universal`.
public struct UpdateFeed: Sendable {
    public static let defaultBases = [URL(string: "https://api.anthropic.com")!,
                                      URL(string: "https://releases.claude.com")!]

    public var bases: [URL]
    public var arch: String
    public var deviceID: String

    public init(bases: [URL] = UpdateFeed.defaultBases, arch: String = UpdateFeed.hostArch, deviceID: String) {
        self.bases = bases
        self.arch = arch
        self.deviceID = deviceID
    }

    public static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "universal"
        #endif
    }

    public func feedURL(base: URL, arch: String, currentVersion: String, osVersion: String) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("api/desktop/darwin/\(arch)/squirrel/update"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "version", value: currentVersion),
            URLQueryItem(name: "os_version", value: osVersion),
        ]
        return comps.url!
    }

    public static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Parses a feed response. Returns nil when the feed has no release (HTTP 204/404 or empty list).
    public static func parse(_ data: Data) throws -> AvailableRelease? {
        struct UpdateTo: Decodable {
            let name: String?
            let version: String
            let pub_date: String?
            let url: String
            let notes: String?
            let sha256: String?
            let size: Int64?
        }
        struct Release: Decodable { let version: String; let updateTo: UpdateTo }
        struct Response: Decodable { let currentRelease: String?; let releases: [Release]? }
        // Squirrel's simpler single-release format ({"url":..., "name":...}) is also accepted.
        struct Single: Decodable { let url: String; let name: String?; let version: String?; let notes: String?; let pub_date: String? }

        if let response = try? JSONDecoder().decode(Response.self, from: data), let releases = response.releases {
            let candidates = releases.compactMap { r -> AvailableRelease? in
                guard let v = AppVersion(r.updateTo.version), let url = URL(string: r.updateTo.url) else { return nil }
                return AvailableRelease(version: v, name: r.updateTo.name, downloadURL: url,
                                        sha256: r.updateTo.sha256?.lowercased(), size: r.updateTo.size,
                                        publishedAt: r.updateTo.pub_date, notes: r.updateTo.notes)
            }
            let preferred = response.currentRelease.flatMap(AppVersion.init)
            if let p = preferred, let match = candidates.first(where: { $0.version == p }) { return match }
            return candidates.max { $0.version < $1.version }
        }
        let single = try JSONDecoder().decode(Single.self, from: data)
        guard let url = URL(string: single.url),
              let v = AppVersion(single.version ?? single.name ?? "") else { return nil }
        return AvailableRelease(version: v, name: single.name, downloadURL: url, sha256: nil, size: nil,
                                publishedAt: single.pub_date, notes: single.notes)
    }

    /// Queries the feed. Tries the host architecture first, then `universal`, across bases.
    public func fetchLatest(currentVersion: String, session: URLSession = .shared) async throws -> AvailableRelease? {
        var lastError: Error?
        let arches = arch == "universal" ? ["universal"] : [arch, "universal"]
        for base in bases {
            for a in arches {
                let url = feedURL(base: base, arch: a, currentVersion: currentVersion, osVersion: Self.osVersionString)
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                do {
                    let (data, response) = try await session.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 204 { return nil }
                    guard status == 200 else {
                        lastError = UpdateFeedError.httpStatus(status)
                        continue
                    }
                    return try Self.parse(data)
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError ?? UpdateFeedError.httpStatus(0)
    }
}

public enum UpdateFeedError: LocalizedError {
    case httpStatus(Int)
    public var errorDescription: String? {
        switch self {
        case .httpStatus(let s): return "The update feed answered HTTP \(s)."
        }
    }
}
