import Foundation
import Darwin

/// A running Claude Desktop main process.
public struct ClaudeProcess: Hashable, Sendable {
    public let pid: pid_t
    public let executablePath: String
    public let arguments: [String]
    public let startTime: Date

    /// The value of `--user-data-dir=` if present; nil means Claude's default data dir.
    public var userDataDirectory: String? { ClaudeProcess.userDataDirectory(from: arguments) }

    public static func userDataDirectory(from arguments: [String]) -> String? {
        var iterator = arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            if arg.hasPrefix("--user-data-dir=") {
                return String(arg.dropFirst("--user-data-dir=".count))
            }
            if arg == "--user-data-dir" { return iterator.next() }
        }
        return nil
    }
}

/// Enumerates Claude main processes using sysctl (no `ps` parsing, no privileges needed for own processes).
public enum ProcessScanner {
    /// Returns every main (non-helper) process whose executable is `executablePath`.
    public static func claudeMainProcesses(executablePath: String) -> [ClaudeProcess] {
        let wanted = canonicalPath(executablePath)
        return allProcesses().compactMap { info -> ClaudeProcess? in
            let pid = info.kp_proc.p_pid
            guard pid > 0, let path = ProcessScanner.executablePath(of: pid), canonicalPath(path) == wanted else { return nil }
            let args = arguments(of: pid) ?? [path]
            let tv = info.kp_proc.p_starttime
            let start = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
            return ClaudeProcess(pid: pid, executablePath: path, arguments: args, startTime: start)
        }
    }

    /// PIDs of processes from `appPath` (main or helpers) whose `--user-data-dir` is `dataDirectory`.
    /// The default profile's main process has no switch, but its helpers carry the default dir explicitly.
    public static func processesUsing(dataDirectory: String, appPath: String) -> [pid_t] {
        let wanted = canonicalPath(dataDirectory)
        let prefix = canonicalPath(appPath) + "/"
        return allProcesses().compactMap { info -> pid_t? in
            let pid = info.kp_proc.p_pid
            guard pid > 0, let path = ProcessScanner.executablePath(of: pid), canonicalPath(path).hasPrefix(prefix),
                  let args = arguments(of: pid) else { return nil }
            if let dir = ClaudeProcess.userDataDirectory(from: args) { return canonicalPath(dir) == wanted ? pid : nil }
            return nil
        }
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Reads argv of `pid` via KERN_PROCARGS2.
    public static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs2(Array(buffer.prefix(size)))
    }

    /// Parses the KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, argv[0..argc-1], env...
    static func parseProcArgs2(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var i = 4
        while i < bytes.count && bytes[i] != 0 { i += 1 }   // exec path
        while i < bytes.count && bytes[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc && i < bytes.count {
            let start = i
            while i < bytes.count && bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}
