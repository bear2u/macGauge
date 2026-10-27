import Foundation
import Darwin

public struct CommandResult {
    public let output: String
    public let status: Int32
}

public enum CommandRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: Double = 20) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let force = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2, execute: force)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel(); force.cancel()
        return CommandResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
    }
}

public struct ProcessReading: Sendable {
    public let pid: Int32
    public let parent: Int32
    public let cpuTime: UInt64
    public let memory: UInt64
    public let executable: String
}

public struct AppIdentity: Sendable {
    public let pid: Int32
    public let name: String
    public let bundlePath: String
    public init(pid: Int32, name: String, bundlePath: String) { self.pid = pid; self.name = name; self.bundlePath = bundlePath }
}

public struct AppUsage: Identifiable, Sendable {
    public var id: Int32 { app.pid }
    public let app: AppIdentity
    public let cpu: Double
    public let memory: UInt64
    public let processCount: Int
}

public enum ProcessSampler {
    public static func read() throws -> [ProcessReading] {
        let ps = try CommandRunner.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,comm="])
        guard ps.status == 0 else { throw NSError(domain: "MacGauge", code: 1, userInfo: [NSLocalizedDescriptionKey: "프로세스 목록을 읽지 못했습니다."]) }
        return ps.output.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 4, let pid = Int32(parts[0]), let parent = Int32(parts[1]), let uid = UInt32(parts[2]), uid == geteuid() else { return nil }
            var info = rusage_info_v2()
            let code = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard code == 0 else { return nil }
            return ProcessReading(pid: pid, parent: parent, cpuTime: info.ri_user_time + info.ri_system_time, memory: info.ri_phys_footprint, executable: String(parts[3]))
        }
    }

    public static func group(_ readings: [ProcessReading], previous: [ProcessReading], elapsed: Double, apps: [AppIdentity]) -> [AppUsage] {
        let old = Dictionary(previous.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let byPID = Dictionary(readings.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let identities = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [Int32: [ProcessReading]] = [:]
        for process in readings {
            var owner: Int32? = identities[process.pid]?.pid
            var parent = process.parent
            var visited = Set<Int32>()
            while owner == nil, parent > 1, visited.insert(parent).inserted {
                if identities[parent] != nil { owner = parent; break }
                guard let ancestor = byPID[parent] else { break }
                parent = ancestor.parent
            }
            if owner == nil {
                owner = apps.filter { !$0.bundlePath.isEmpty && process.executable.hasPrefix($0.bundlePath + "/") }
                    .max(by: { $0.bundlePath.count < $1.bundlePath.count })?.pid
            }
            if let owner { groups[owner, default: []].append(process) }
        }
        return apps.map { app in
            let group = groups[app.pid, default: []]
            let cpu = group.reduce(0.0) { sum, process in
                guard let last = old[process.pid], last.executable == process.executable, process.cpuTime >= last.cpuTime, elapsed > 0 else { return sum }
                return sum + Double(process.cpuTime - last.cpuTime) / (elapsed * 1_000_000_000) * 100
            }
            return AppUsage(app: app, cpu: cpu, memory: group.reduce(0) { $0 + $1.memory }, processCount: group.count)
        }
    }
}
