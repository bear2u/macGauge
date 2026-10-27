import Foundation
import Darwin

public struct FileStamp: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let modified: Int64
    public let nanoseconds: Int64
    public let changed: Int64
    public let changeNanoseconds: Int64
    public let allocated: UInt64
    public let owner: UInt32
    public let regular: Bool
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; size = s.st_size
        modified = Int64(s.st_mtimespec.tv_sec); nanoseconds = Int64(s.st_mtimespec.tv_nsec)
        changed = Int64(s.st_ctimespec.tv_sec); changeNanoseconds = Int64(s.st_ctimespec.tv_nsec)
        allocated = UInt64(max(0, s.st_blocks)) * 512; owner = s.st_uid
        regular = (s.st_mode & S_IFMT) == S_IFREG
    }
    static func read(_ path: String) throws -> FileStamp {
        var s = stat()
        guard lstat(path, &s) == 0 else { throw CleanupError.fileChanged }
        return FileStamp(s)
    }
}

public struct CleanupCandidate: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let ruleID: String
    public let stamp: FileStamp
    public var bytes: UInt64 { stamp.allocated }
}

public struct CleanupGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let files: [CleanupCandidate]
    public var bytes: UInt64 { files.reduce(0) { $0 + $1.bytes } }
}

public struct CleanupScan: Sendable {
    public let groups: [CleanupGroup]
    public let examined: Int
    public let warnings: [String]
    public let date: Date
    public var bytes: UInt64 { groups.reduce(0) { $0 + $1.bytes } }
}

public struct DeletionReport: Codable, Sendable {
    public let date: Date
    public let deleted: [String]
    public let bytes: UInt64
    public let skipped: [String]
    public let errors: [String]
}

public enum CleanupError: LocalizedError {
    case fileChanged, outsideRules, openFile, cannotCheckOpenFiles
    public var errorDescription: String? {
        switch self {
        case .fileChanged: return "검색 이후 변경되었거나 접근할 수 없는 파일입니다."
        case .outsideRules: return "허용된 정리 경로가 아니거나 심볼릭 링크가 포함되어 있습니다."
        case .openFile: return "프로그램이 사용 중인 파일입니다."
        case .cannotCheckOpenFiles: return "사용 중인 파일을 확인하지 못했습니다. 정리를 중단했습니다."
        }
    }
}

struct CleanupRule {
    let id: String
    let title: String
    let subtitle: String
    let root: URL
    let filter: Filter
    enum Filter { case logs, maestro, cache, downloads }
    func permits(_ url: URL) -> Bool {
        guard url.path.hasPrefix(root.path + "/"), !url.pathComponents.contains("LocalHistory") else { return false }
        let name = url.lastPathComponent.lowercased()
        switch filter {
        case .cache: return true
        case .maestro: return name == "maestro.log"
        case .downloads: return name.hasSuffix(".zip") || name.hasSuffix(".tar.gz")
        case .logs:
            return name.range(of: #"\.(log(?:\.\d+)?(?:\.gz)?|ips|crash)$"#, options: .regularExpression) != nil
        }
    }
}

public enum CleanupEngine {
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    static func rules(home: URL) -> [CleanupRule] {
        func rule(_ id: String, _ title: String, _ subtitle: String, _ path: String, _ filter: CleanupRule.Filter) -> CleanupRule {
            CleanupRule(id: id, title: title, subtitle: subtitle, root: home.appendingPathComponent(path), filter: filter)
        }
        var rules = [
            rule("logs", "오래된 진단 로그", "앱 오류·실행 기록 · 대화 기록 제외", "Library/Logs", .logs),
            rule("maestro", "Maestro 테스트 로그", "테스트 결과의 maestro.log 파일", ".maestro/tests", .maestro),
            rule("npm", "npm 실행 로그", "패키지 설치·실행 진단 기록", ".npm/_logs", .logs),
            rule("gradle", "Gradle 실행 로그", "데몬 로그만 · 빌드 캐시 유지", ".gradle/daemon", .logs),
            rule("dart", "Dart 분석 캐시", "IDE가 다시 생성하는 분석 데이터", ".dartServer/.analysis-driver", .cache),
            rule("electron", "Electron 다운로드 캐시", "재다운로드 가능한 압축 파일", "Library/Caches/electron", .downloads)
        ]
        let jetbrains = home.appendingPathComponent("Library/Caches/JetBrains")
        let versions = (try? FileManager.default.contentsOfDirectory(at: jetbrains, includingPropertiesForKeys: nil)) ?? []
        for version in versions {
            for name in ["plugins", "index", "caches"] {
                rules.append(CleanupRule(id: "jetbrains", title: "JetBrains 캐시", subtitle: "플러그인 다운로드·인덱스 · 로컬 히스토리 유지", root: version.appendingPathComponent(name), filter: name == "plugins" ? .downloads : .cache))
            }
        }
        for name in ["Cache", "Code Cache", "GPUCache"] {
            rules.append(rule("chrome", "Chrome 웹 캐시", "캐시만 · 로그인·방문 기록 유지", "Library/Caches/Google/Chrome/Default/\(name)", .cache))
        }
        return rules
    }

    public static func openFiles() throws -> Set<String> {
        let result = try CommandRunner.run("/usr/sbin/lsof", ["-n", "-P", "-w", "-u", String(geteuid()), "-F", "n"])
        let paths = Set(result.output.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) })
        guard (result.status == 0 || result.status == 1), !paths.isEmpty else { throw CleanupError.cannotCheckOpenFiles }
        return paths
    }

    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, days: Int = 30,
                            knownOpenFiles: Set<String>? = nil, progress: @Sendable (String) -> Void = { _ in }) throws -> CleanupScan {
        guard let canonicalHome = canonicalPath(home.path) else { throw CleanupError.outsideRules }
        let home = URL(fileURLWithPath: canonicalHome)
        let opened = try knownOpenFiles ?? openFiles()
        let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970
        var candidates: [String: [CleanupCandidate]] = [:]
        var labels: [String: CleanupRule] = [:]
        var warnings = Set<String>()
        var examined = 0
        var seen = Set<String>()
        for rule in rules(home: home) {
            try Task.checkCancellation()
            labels[rule.id] = rule
            guard FileManager.default.fileExists(atPath: rule.root.path) else { continue }
            guard canonicalPath(rule.root.path) == rule.root.path else { warnings.insert("링크 경로 제외: \(rule.root.path)"); continue }
            progress("\(rule.title) 확인 중…")
            guard let enumerator = FileManager.default.enumerator(at: rule.root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsPackageDescendants], errorHandler: { url, _ in
                warnings.insert("읽기 권한 없음: \(url.path)"); return true
            }) else { warnings.insert("읽기 실패: \(rule.root.path)"); continue }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                examined += 1
                if examined > 500_000 { warnings.insert("파일 50만 개 한도에 도달했습니다. 일부 항목만 검색했습니다."); break }
                if examined % 2000 == 0 { progress("\(rule.title) · \(examined.formatted())개 확인") }
                guard let stamp = try? FileStamp.read(url.path), stamp.regular, stamp.owner == geteuid(),
                      Double(stamp.modified) < cutoff, !opened.contains(url.path), rule.permits(url), seen.insert(url.path).inserted else { continue }
                if canonicalPath(url.path) != url.path { continue }
                candidates[rule.id, default: []].append(CleanupCandidate(url: url, ruleID: rule.id, stamp: stamp))
            }
            if examined > 500_000 { break }
        }
        let groups = candidates.compactMap { key, files -> CleanupGroup? in
            guard let label = labels[key], !files.isEmpty else { return nil }
            return CleanupGroup(id: key, title: label.title, subtitle: label.subtitle, files: files.sorted { $0.bytes > $1.bytes })
        }.sorted { $0.bytes > $1.bytes }
        return CleanupScan(groups: groups, examined: examined, warnings: Array(warnings).sorted(), date: Date())
    }

    /// Uses directory descriptors with O_NOFOLLOW. A replaced parent symlink cannot redirect deletion.
    static func deleteFile(_ candidate: CleanupCandidate, home: URL, cutoff: Double, allowedRules: [CleanupRule]) throws {
        let path = candidate.url.path
        guard path.hasPrefix(home.path + "/"), allowedRules.contains(where: { $0.id == candidate.ruleID && $0.permits(candidate.url) }) else { throw CleanupError.outsideRules }
        let components = String(path.dropFirst(home.path.count + 1)).split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else { throw CleanupError.outsideRules }
        var fd = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw CleanupError.outsideRules }
        defer { close(fd) }
        for part in components.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw CleanupError.outsideRules }
            close(fd); fd = next
        }
        let name = components.last!
        var current = stat()
        guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw CleanupError.fileChanged }
        let stamp = FileStamp(current)
        guard stamp == candidate.stamp, stamp.regular, stamp.owner == geteuid(), Double(stamp.modified) < cutoff else { throw CleanupError.fileChanged }
        guard unlinkat(fd, name, 0) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    public static func delete(_ candidates: [CleanupCandidate], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              days: Int = 30, knownOpenFiles: Set<String>? = nil,
                              progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> DeletionReport {
        guard let canonicalHome = canonicalPath(home.path) else { throw CleanupError.outsideRules }
        let home = URL(fileURLWithPath: canonicalHome)
        let opened = try knownOpenFiles ?? openFiles()
        let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86400).timeIntervalSince1970
        var deleted: [String] = []; var skipped: [String] = []; var errors: [String] = []; var bytes: UInt64 = 0
        let allowedRules = rules(home: home)
        var seen = Set<String>()
        for (index, candidate) in candidates.enumerated() {
            if !seen.insert(candidate.id).inserted { continue }
            do {
                if opened.contains(candidate.url.path) { throw CleanupError.openFile }
                try deleteFile(candidate, home: home, cutoff: cutoff, allowedRules: allowedRules)
                deleted.append(candidate.url.path); bytes += candidate.bytes
            } catch let error as CleanupError { skipped.append("\(candidate.url.path): \(error.localizedDescription)") }
            catch { errors.append("\(candidate.url.path): \(error.localizedDescription)") }
            if index % 200 == 0 || index == candidates.count - 1 { progress(index + 1, candidates.count) }
        }
        return DeletionReport(date: Date(), deleted: deleted, bytes: bytes, skipped: skipped, errors: errors)
    }
}
