import CryptoKit
import Foundation

public enum InstallerError: LocalizedError {
    case downloadFailed(String)
    case extractFailed(String)
    case noAppInArchive
    case swapFailed(String)
    case rolledBack(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let m): return "Download failed: \(m)"
        case .extractFailed(let m): return "Couldn't unpack the update: \(m)"
        case .noAppInArchive: return "The update archive doesn't contain Claude.app."
        case .swapFailed(let m): return "Couldn't install the update: \(m)"
        case .rolledBack(let m): return "The new version failed verification after install and the previous version was restored. (\(m))"
        }
    }
}

/// Downloads, verifies and installs a Claude release, keeping the previous bundle until the new one verifies.
public final class UpdateInstaller: @unchecked Sendable {
    public let verifier: BundleVerifying
    public let workDirectory: URL
    private let fileManager = FileManager.default

    /// Test hook: runs after the new bundle is moved into place and before it is verified there.
    public var afterSwapHook: ((URL) throws -> Void)?

    public init(verifier: BundleVerifying = ClaudeSignatureVerifier(), workDirectory: URL) {
        self.verifier = verifier
        self.workDirectory = workDirectory
    }

    // MARK: Download

    public func download(_ url: URL, expectedSize: Int64?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let destination = workDirectory.appendingPathComponent(url.lastPathComponent.isEmpty ? "Claude.zip" : url.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        let downloader = FileDownloader(destination: destination, expectedSize: expectedSize, progress: progress)
        return try await downloader.run(url)
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func verifyChecksum(of file: URL, expected: String?) throws {
        guard let expected, !expected.isEmpty else { return }
        let actual = try Self.sha256(of: file)
        guard actual.lowercased() == expected.lowercased() else {
            throw VerificationError.checksumMismatch(expected: expected, found: actual)
        }
    }

    // MARK: Extract + verify

    /// Unzips `archive` (with ditto, preserving signatures/xattrs) and returns the contained .app.
    public func extract(_ archive: URL) throws -> URL {
        let dest = workDirectory.appendingPathComponent("staged-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        let result = try Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, dest.path])
        guard result.status == 0 else { throw InstallerError.extractFailed(result.stderr) }
        let items = try fileManager.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }) else { throw InstallerError.noAppInArchive }
        return app
    }

    @discardableResult
    public func verify(app: URL, expectedVersion: AppVersion?) throws -> VerifiedBundle {
        let verified = try verifier.verify(appAt: app)
        if let expectedVersion, verified.version != expectedVersion {
            throw VerificationError.wrongVersion(expected: expectedVersion.string, found: verified.version?.string)
        }
        return verified
    }

    // MARK: Swap

    /// Atomically-as-possible replaces `target` with `staged`.
    /// 1. verify staged, 2. rename target -> backup, 3. move staged -> target, 4. verify target,
    /// 5. delete backup. Any failure after step 2 restores the backup.
    @discardableResult
    public func install(staged: URL, over target: URL, expectedVersion: AppVersion?) throws -> VerifiedBundle {
        try verify(app: staged, expectedVersion: expectedVersion)

        let parent = target.deletingLastPathComponent()
        // No ".app" extension so LaunchServices never treats the backup as a second Claude.
        let backup = parent.appendingPathComponent("\(target.lastPathComponent).claude-profiles-backup")
        if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }

        let hadOriginal = fileManager.fileExists(atPath: target.path)
        if hadOriginal {
            do { try fileManager.moveItem(at: target, to: backup) }
            catch { throw InstallerError.swapFailed("couldn't move the current app aside: \(error.localizedDescription)") }
        }

        do {
            do {
                try fileManager.moveItem(at: staged, to: target)
            } catch {
                // Different volume: copy preserving everything, then verify.
                let r = try Shell.run("/usr/bin/ditto", [staged.path, target.path])
                guard r.status == 0 else { throw InstallerError.swapFailed(r.stderr) }
            }
            try afterSwapHook?(target)
            let verified = try verify(app: target, expectedVersion: expectedVersion)
            if hadOriginal { try? fileManager.removeItem(at: backup) }
            return verified
        } catch {
            // Roll back.
            if fileManager.fileExists(atPath: target.path) { try? fileManager.removeItem(at: target) }
            if hadOriginal { try? fileManager.moveItem(at: backup, to: target) }
            throw InstallerError.rolledBack(underlying: error.localizedDescription)
        }
    }

    public func cleanWorkDirectory() {
        try? fileManager.removeItem(at: workDirectory)
    }
}

/// Minimal delegate-based downloader with progress.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64?
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let lock = NSLock()

    init(destination: URL, expectedSize: Int64?, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func run(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                lock.lock()
                continuation = cont
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock(); let t = self.task; self.lock.unlock()
            t?.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        cont?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expectedSize ?? 0)
        if total > 0 { progress(min(1, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(InstallerError.downloadFailed("HTTP \(http.statusCode)")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(InstallerError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(InstallerError.downloadFailed(error.localizedDescription))) }
    }
}

/// Tiny synchronous process runner.
public enum Shell {
    public struct Result { public let status: Int32; public let stdout: String; public let stderr: String }

    @discardableResult
    public static func run(_ launchPath: String, _ args: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }
}
