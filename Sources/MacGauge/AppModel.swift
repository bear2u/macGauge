import AppKit
import SwiftUI
import Combine
import ServiceManagement
import MacGaugeCore

@MainActor final class AppModel: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    @Published var history: [Double] = []
    @Published var apps: [AppUsage] = []
    @Published var tab = 0
    @Published var sortByMemory = true
    @Published var search = ""
    @Published var scan: CleanupScan?
    @Published var selected = Set<String>()
    @Published var days = 30
    @Published var busy = false
    @Published var deleting = false
    @Published var progress = ""
    @Published var report: DeletionReport?
    @Published var reportURL: URL?
    @Published var message = ""
    @Published var hasCPUSample = false
    @Published var hasAppSample = false
    @Published var processError = ""
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginPending = SMAppService.mainApp.status == .requiresApproval
    @Published var showMemoryInBar = UserDefaults.standard.object(forKey: "showMemoryInBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMemoryInBar, forKey: "showMemoryInBar"); onStatusUpdate?() }
    }
    var onStatusUpdate: (() -> Void)?
    var panelVisible = false
    private var timer: Timer?
    private var previousCPU: CPUSample?
    private var previousProcesses: [ProcessReading] = []
    private var previousDate: Double?
    private var refreshing = false
    private var scanTask: Task<Void, Never>?
    private var worker: Task<CleanupScan, Error>?

    var filteredApps: [AppUsage] {
        apps.filter { search.isEmpty || $0.app.name.localizedCaseInsensitiveContains(search) }
            .sorted { sortByMemory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
    }
    var selectedFiles: [CleanupCandidate] { scan?.groups.filter { selected.contains($0.id) }.flatMap(\.files) ?? [] }
    var selectedBytes: UInt64 { selectedFiles.reduce(0) { $0 + $1.bytes } }
    var pressureTitle: String {
        switch snapshot.pressure { case 1: return "정상"; case 2: return "주의"; case 4: return "높음"; default: return "확인 중" }
    }
    var pressureColor: Color {
        switch snapshot.pressure { case 1: return .green; case 2: return .orange; case 4: return .red; default: return .secondary }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let oldCPU = previousCPU
        let showApps = panelVisible
        let identities = showApps ? NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }.map { AppIdentity(pid: $0.processIdentifier, name: $0.localizedName ?? "앱", bundlePath: $0.bundleURL?.path ?? "") } : []
        let lastProcesses = previousProcesses
        let lastDate = previousDate
        Task {
            let result = await Task.detached(priority: .utility) { () -> (SystemSnapshot, CPUSample, [ProcessReading], [AppUsage], Double, String?) in
                let (snapshot, cpu) = Metrics.read(previous: oldCPU)
                let now = ProcessInfo.processInfo.systemUptime
                guard showApps else { return (snapshot, cpu, [], [], now, nil) }
                do {
                    let readings = try ProcessSampler.read()
                    let usages = ProcessSampler.group(readings, previous: lastProcesses, elapsed: now - (lastDate ?? now), apps: identities)
                    return (snapshot, cpu, readings, usages, now, nil)
                } catch { return (snapshot, cpu, [], [], now, error.localizedDescription) }
            }.value
            self.snapshot = result.0; self.previousCPU = result.1
            self.hasCPUSample = oldCPU != nil
            if self.hasCPUSample {
                self.history.append(result.0.cpu)
                if self.history.count > 40 { self.history.removeFirst(self.history.count - 40) }
            }
            if showApps {
                self.previousProcesses = result.2; self.apps = result.3
                self.previousDate = result.4; self.processError = result.5 ?? ""
                self.hasAppSample = lastDate != nil && result.5 == nil
            } else { self.previousDate = nil; self.previousProcesses = []; self.hasAppSample = false }
            self.refreshing = false; self.onStatusUpdate?()
        }
    }

    func scanFiles() {
        guard !busy else { return }
        busy = true; report = nil; reportURL = nil; scan = nil; selected = []; message = ""
        progress = "사용 중인 파일 확인 중…"
        let age = days
        worker = Task.detached(priority: .utility) { [self] in
            try CleanupEngine.scan(days: age) { text in Task { @MainActor in self.progress = text } }
        }
        scanTask = Task {
            defer { busy = false; worker = nil }
            do {
                scan = try await worker?.value
                progress = "검색 완료"
            } catch is CancellationError { progress = "검색을 취소했습니다." }
            catch { message = error.localizedDescription; progress = "검색 실패" }
        }
    }
    func cancelScan() { worker?.cancel() }

    func confirmDelete() {
        let files = selectedFiles
        guard !busy, !files.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "선택한 오래된 파일을 삭제할까요?"
        alert.informativeText = "\(files.count.formatted())개 · \(DisplayFormat.bytes(selectedBytes))\n휴지통을 거치지 않고 삭제됩니다. 검색 이후 변경되었거나 사용 중인 파일은 제외합니다. 다음 실행 시 캐시를 다시 생성할 수 있습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "영구 삭제")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; deleting = true; message = ""; progress = "사용 중인 파일 다시 확인 중…"
        let age = days
        Task {
            defer { busy = false; deleting = false; refresh() }
            do {
                let result = try await Task.detached(priority: .utility) { [self] in
                    try CleanupEngine.delete(files, days: age) { done, total in
                        Task { @MainActor in self.progress = "\(done.formatted()) / \(total.formatted())개 확인" }
                    }
                }.value
                report = result; scan = nil; selected = []
                progress = "정리 완료"
                do {
                    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacGauge/Reports")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("cleanup-\(Int(Date().timeIntervalSince1970)).json")
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(result).write(to: url, options: .atomic)
                    reportURL = url
                } catch { message = "정리는 완료했지만 내역 저장에 실패했습니다: \(error.localizedDescription)" }
            } catch { message = error.localizedDescription; progress = "정리를 중단했습니다." }
        }
    }

    func canTerminate(_ usage: AppUsage) -> Bool {
        guard usage.id != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: usage.id), !app.isTerminated,
              app.bundleURL?.path == usage.app.bundlePath else { return false }
        return !["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver"].contains(app.bundleIdentifier ?? "")
    }
    func terminate(_ usage: AppUsage, force: Bool) {
        guard canTerminate(usage) else { return }
        let alert = NSAlert()
        alert.messageText = "\(usage.app.name)을(를) \(force ? "강제 종료" : "종료")할까요?"
        alert.informativeText = force ? "저장하지 않은 작업을 잃을 수 있습니다. 이 앱과 연결된 작업이 중단됩니다." : "앱에 정상 종료를 요청합니다. 저장하지 않은 문서가 있으면 앱에서 확인을 요청할 수 있습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "취소"); alert.addButton(withTitle: force ? "강제 종료" : "종료")
        guard alert.runModal() == .alertSecondButtonReturn, canTerminate(usage), let app = NSRunningApplication(processIdentifier: usage.id) else { return }
        let accepted = force ? app.forceTerminate() : app.terminate()
        message = accepted ? "\(usage.app.name)에 종료를 요청했습니다." : "종료 요청을 전달하지 못했습니다. 앱 상태를 확인해 주세요."
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if app.isTerminated { message = "\(usage.app.name)이(가) 종료됐습니다." }
            else if accepted { message = "\(usage.app.name)이(가) 아직 실행 중입니다. 저장 확인 창이나 진행 중인 작업을 확인해 주세요." }
            refresh()
        }
    }
    func toggleLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { message = "로그인 실행 설정 실패: \(error.localizedDescription)" }
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginPending = SMAppService.mainApp.status == .requiresApproval
    }
}
