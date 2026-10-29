import SwiftUI
import AppKit
import ServiceManagement
import MacGaugeCore

private let accent = Color(red: 0.04, green: 0.56, blue: 0.49)

struct Brand: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(accent.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("MacGauge").font(.system(size: 17, weight: .semibold))
                Text("내 Mac, 한눈에").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { p in
                    for ratio in [0.25, 0.5, 0.75] {
                        let y = geometry.size.height * ratio
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }.stroke(Color.secondary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                Path { p in
                    guard values.count > 1 else { return }
                    for (i, value) in values.enumerated() {
                        let point = CGPoint(x: geometry.size.width * Double(i) / Double(values.count - 1), y: geometry.size.height * (1 - min(1, max(0, value))))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }.stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityLabel("최근 CPU 사용률 추이")
    }
}

struct MetricCard: View {
    let name: String
    let value: String
    let detail: String
    let fraction: Double
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(name).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
            ProgressView(value: min(1, max(0, fraction))).tint(tint)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06)))
    }
}

struct StatusCards: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            MetricCard(name: "CPU", value: model.hasCPUSample ? DisplayFormat.percent(model.snapshot.cpu) : "—", detail: "\(ProcessInfo.processInfo.activeProcessorCount)개 논리 코어", fraction: model.snapshot.cpu, tint: accent)
            MetricCard(name: "MEMORY", value: DisplayFormat.percent(model.snapshot.memoryFraction), detail: "\(DisplayFormat.bytes(model.snapshot.memoryUsed)) / \(DisplayFormat.bytes(model.snapshot.memoryTotal))", fraction: model.snapshot.memoryFraction, tint: model.pressureColor)
            MetricCard(name: "DISK", value: DisplayFormat.percent(model.snapshot.diskFraction), detail: "\(DisplayFormat.bytes(model.snapshot.diskFree)) 사용 가능", fraction: model.snapshot.diskFraction, tint: model.snapshot.diskFraction > 0.9 ? .orange : accent)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Brand()
                Spacer()
                HStack(spacing: 5) { Circle().fill(accent).frame(width: 6, height: 6); Text("실시간 · 3초").font(.caption).foregroundStyle(.secondary) }
            }
            StatusCards(model: model)
            Picker("화면", selection: $model.tab) {
                Text("시스템").tag(0); Text("앱 사용량").tag(1); Text("로그·캐시 정리").tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            if !model.message.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle")
                    Text(model.message).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button { model.message = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("안내 닫기")
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Group {
                switch model.tab {
                case 1: AppsView(model: model)
                case 2: CleanupView(model: model)
                default: OverviewView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            HStack {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                Text(Host.current().localizedName ?? "이 Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                OptionsMenu(model: model)
            }
        }.padding(24).frame(minWidth: 620, minHeight: 660)
            .background(Color(nsColor: .windowBackgroundColor)).tint(accent)
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                KeepAwakeControls(model: model)
                Text("자동 잠자기를 방지합니다. 뚜껑 닫기·수동 잠자기는 막지 않습니다. 뚜껑을 닫고 사용하려면 외장 화면·전원·키보드·마우스를 연결하세요.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LoginStartControls(model: model)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("CPU 사용 추이").font(.headline); Spacer(); Text("최근 최대 2분").font(.caption).foregroundStyle(.secondary) }
                    Sparkline(values: model.history).frame(height: 78)
                }
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("메모리 압력").font(.headline)
                        Label(model.pressureTitle, systemImage: "circle.fill").foregroundStyle(model.pressureColor)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Text("스왑 사용량").font(.headline)
                        Text(DisplayFormat.bytes(model.snapshot.swapUsed)).monospacedDigit()
                    }
                }
                Text("메모리는 사용률보다 압력이 중요합니다. 불필요한 앱을 정상 종료하면 CPU 부하와 메모리 사용량을 줄일 수 있습니다.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("사용량이 큰 앱 보기", systemImage: "arrow.up.right") { model.tab = 1 }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("저장 공간").font(.headline)
                    Text("전체 \(DisplayFormat.bytes(model.snapshot.diskTotal)) 중 \(DisplayFormat.bytes(model.snapshot.diskFree)) 사용 가능")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("오래된 로그·캐시 살펴보기", systemImage: "sparkles") { model.tab = 2 }
                }
            }.padding(2)
        }
    }
}

struct AppsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("앱 검색", text: $model.search).textFieldStyle(.roundedBorder)
                Picker("정렬", selection: $model.sortByMemory) { Text("메모리 순").tag(true); Text("CPU 순").tag(false) }.frame(width: 125)
            }
            Text("앱과 하위 프로세스를 합산합니다. CPU 100%는 코어 1개 사용량입니다.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.processError.isEmpty { Text(model.processError).foregroundStyle(.orange).font(.caption) }
            HStack { Text("앱"); Spacer(); Text("CPU").frame(width: 70, alignment: .trailing); Text("메모리").frame(width: 95, alignment: .trailing); Spacer().frame(width: 26) }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.filteredApps) { app in AppRow(model: model, app: app) }
                    if model.filteredApps.isEmpty { Text(model.search.isEmpty ? "앱 사용량을 수집하고 있습니다…" : "일치하는 앱이 없습니다.").foregroundStyle(.secondary).padding(30) }
                }
            }
            Text("메모리는 프로세스별 실제 점유량의 합계로, 시스템 전체 사용량과 다를 수 있습니다.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct AppRow: View {
    @ObservedObject var model: AppModel
    let app: AppUsage
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSRunningApplication(processIdentifier: app.id)?.icon ?? NSImage(named: NSImage.applicationIconName)!)
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.app.name).lineLimit(1)
                Text("\(app.processCount)개 프로세스").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(model.hasAppSample ? String(format: "%.1f%%", app.cpu) : "—").monospacedDigit().frame(width: 70, alignment: .trailing)
            Text(app.processCount > 0 ? DisplayFormat.bytes(app.memory) : "조회 불가").monospacedDigit().frame(width: 95, alignment: .trailing)
            Menu {
                Button("앱으로 이동") { NSRunningApplication(processIdentifier: app.id)?.activate(options: [.activateAllWindows]) }
                Divider()
                Button("종료…", role: .destructive) { model.terminate(app, force: false) }.disabled(!model.canTerminate(app))
                Button("강제 종료…", role: .destructive) { model.terminate(app, force: true) }.disabled(!model.canTerminate(app))
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("\(app.app.name) 동작")
        }.font(.system(size: 12)).padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CleanupView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("수정된 지", selection: $model.days) { Text("30일 이상").tag(30); Text("60일 이상").tag(60); Text("90일 이상").tag(90) }
                    .frame(width: 190).disabled(model.busy)
                    .onChange(of: model.days) { _, _ in model.scan = nil; model.selected = [] }
                Spacer()
                if model.busy && !model.deleting { Button("검색 취소") { model.cancelScan() } }
                Button(model.scan == nil ? "검색" : "다시 검색", systemImage: "magnifyingglass") { model.scanFiles() }.disabled(model.busy)
            }
            Text("사용 중인 파일·소스·로그인 정보는 제외합니다. 선택한 파일만 삭제합니다.").font(.caption).foregroundStyle(.secondary)
            if model.busy {
                ProgressView().progressViewStyle(.linear)
                Text(model.progress).font(.caption).foregroundStyle(.secondary)
            }
            if let report = model.report { CleanupResultView(report: report, reportURL: model.reportURL) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let scan = model.scan {
                        if scan.groups.isEmpty {
                            Label("정리할 오래된 파일이 없습니다.", systemImage: "checkmark.circle").foregroundStyle(accent).padding(.vertical, 25)
                        } else {
                            HStack {
                                Text("\(DisplayFormat.bytes(scan.bytes)) · \(scan.groups.reduce(0) { $0 + $1.files.count }.formatted())개 파일").font(.headline)
                                Spacer()
                                Button(model.selected.count == scan.groups.count ? "선택 해제" : "전체 선택") {
                                    model.selected = model.selected.count == scan.groups.count ? [] : Set(scan.groups.map(\.id))
                                }.disabled(model.busy)
                            }
                            ForEach(scan.groups) { group in CleanupGroupView(model: model, group: group) }
                        }
                        if !scan.warnings.isEmpty {
                            DisclosureGroup("확인하지 못한 항목 \(scan.warnings.count)개") {
                                ForEach(scan.warnings.prefix(20), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                            }.foregroundStyle(.secondary)
                        }
                    } else if !model.busy && model.report == nil {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 30)).foregroundStyle(accent)
                            Text("정리 전에, 먼저 확인하세요.").font(.title3.weight(.semibold))
                            Text("앱 진단 로그, Maestro·npm·Gradle 로그, Dart 분석 데이터, JetBrains 다운로드·인덱스, Chrome 웹 캐시를 검색합니다.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("프로젝트 폴더와 AI 모델, 브라우저 기록은 검색 대상에 포함하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(2)
            }
            if model.scan != nil {
                Divider()
                HStack {
                    Text("선택 \(DisplayFormat.bytes(model.selectedBytes))").font(.headline)
                    Spacer()
                    Button("선택 항목 정리…", systemImage: "trash") { model.confirmDelete() }
                        .buttonStyle(.borderedProminent).disabled(model.busy || model.selectedFiles.isEmpty)
                }
            }
        }
    }
}

struct CleanupGroupView: View {
    @ObservedObject var model: AppModel
    let group: CleanupGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(get: { model.selected.contains(group.id) }, set: { if $0 { model.selected.insert(group.id) } else { model.selected.remove(group.id) } })) { Text(group.title).font(.headline) }
                    .toggleStyle(.checkbox).disabled(model.busy)
                Spacer()
                Text(DisplayFormat.bytes(group.bytes)).monospacedDigit()
            }
            Text(group.subtitle).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("\(group.files.count.formatted())개 파일 · 큰 파일 미리보기") {
                ForEach(group.files.prefix(15)) { file in
                    HStack {
                        Text(file.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).lineLimit(1).truncationMode(.middle).help(file.url.path)
                        Spacer()
                        Text(DisplayFormat.bytes(file.bytes))
                        Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }.buttonStyle(.plain).accessibilityLabel("Finder에서 파일 보기")
                    }.font(.caption2).padding(.vertical, 2)
                }
            }.font(.caption)
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CleanupResultView: View {
    let report: DeletionReport
    let reportURL: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(report.deleted.count.formatted())개 정리 · \(DisplayFormat.bytes(report.bytes))", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(accent)
            Text("변경·사용 중 \(report.skipped.count)개 제외 · 오류 \(report.errors.count)개").font(.caption).foregroundStyle(.secondary)
            Text("파일 할당 용량 합계입니다. 실제 확보 공간은 공유 블록·동시 작업에 따라 다를 수 있습니다.").font(.caption2).foregroundStyle(.secondary)
            if let reportURL { Button("정리 내역 보기") { NSWorkspace.shared.activateFileViewerSelecting([reportURL]) }.font(.caption) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct OptionsMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu {
            Button(model.awakeActive ? "잠자기 방지 끄기" : "잠자기 방지 시작 (설정된 시간)") {
                if model.awakeActive { model.stopKeepingAwake() } else { model.startKeepingAwake() }
            }
            Button("화면 즉시 끄기") { model.turnDisplayOff() }.disabled(model.turningDisplayOff)
            Divider()
            Toggle("상태바에 메모리 표시", isOn: $model.showMemoryInBar)
            Toggle("로그인 후 자동 시작", isOn: Binding(get: { model.loginRequested }, set: { model.toggleLogin($0) }))
            if model.loginPending { Button("로그인 항목 승인 열기") { SMAppService.openSystemSettingsLoginItems() } }
            Divider()
            Button("활성 상태 보기 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
            Button("MacGauge 종료") { (NSApp.delegate as? AppDelegate)?.quit() }.disabled(model.deleting)
        } label: { Label("설정", systemImage: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
    }
}

struct CompactView: View {
    @ObservedObject var model: AppModel
    let showDashboard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Brand(); Spacer(); Text(model.pressureTitle).font(.caption.weight(.medium)).foregroundStyle(model.pressureColor).padding(.horizontal, 9).padding(.vertical, 5).background(model.pressureColor.opacity(0.1), in: Capsule()) }
            VStack(spacing: 12) {
                metric("CPU", model.hasCPUSample ? DisplayFormat.percent(model.snapshot.cpu) : "측정 중", model.snapshot.cpu, accent)
                metric("MEM", "\(DisplayFormat.bytes(model.snapshot.memoryUsed)) / \(DisplayFormat.bytes(model.snapshot.memoryTotal))", model.snapshot.memoryFraction, model.pressureColor)
                metric("DSK", "\(DisplayFormat.bytes(model.snapshot.diskFree)) 여유", model.snapshot.diskFraction, model.snapshot.diskFraction > 0.9 ? .orange : accent)
            }
            Sparkline(values: model.history).frame(height: 45)
            Divider()
            HStack {
                Text("메모리 압력 \(model.pressureTitle)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("스왑 \(DisplayFormat.bytes(model.snapshot.swapUsed))").font(.caption).foregroundStyle(.secondary)
            }
            KeepAwakeControls(model: model)
            Button(action: showDashboard) { HStack { Text("앱 사용량 · 로그·캐시 정리"); Spacer(); Image(systemName: "arrow.up.right") }.padding(.vertical, 4) }.buttonStyle(.borderedProminent)
            HStack { Text(Host.current().localizedName ?? "이 Mac").font(.caption2).foregroundStyle(.secondary); Spacer(); OptionsMenu(model: model) }
        }.padding(20).frame(width: 360).tint(accent)
    }
    private func metric(_ label: String, _ value: String, _ fraction: Double, _ color: Color) -> some View {
        VStack(spacing: 5) {
            HStack { Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary); Spacer(); Text(value).font(.system(size: 12, design: .monospaced)) }
            ProgressView(value: min(1, max(0, fraction))).tint(color)
        }
    }
}

struct KeepAwakeControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("잠자기 방지", systemImage: model.awakeActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(model.awakeActive ? accent : .primary)
                Spacer()
                Button(model.awakeActive ? "끄기" : "시작") {
                    if model.awakeActive { model.stopKeepingAwake() } else { model.startKeepingAwake() }
                }.accessibilityLabel(model.awakeActive ? "잠자기 방지 끄기" : "잠자기 방지 시작")
            }
            if model.awakeActive {
                Text(model.awakeStatus).font(.caption).foregroundStyle(accent)
            } else {
                HStack {
                    Picker("유지 시간", selection: $model.awakeMinutes) {
                        Text("15분").tag(15); Text("30분").tag(30); Text("1시간").tag(60)
                        Text("2시간").tag(120); Text("직접 끌 때까지").tag(0)
                    }.labelsHidden().frame(maxWidth: 145).accessibilityLabel("잠자기 방지 시간")
                    Spacer()
                    Toggle("화면도 켜두기", isOn: $model.keepDisplayAwake).toggleStyle(.checkbox).font(.caption)
                }
            }
            Text("자동 잠자기만 방지 · 뚜껑 닫기는 제외").font(.caption2).foregroundStyle(.secondary)
            Button(action: { model.turnDisplayOff() }) {
                Label(model.turningDisplayOff ? "화면 끄는 중…" : "화면 즉시 끄기", systemImage: "display")
                    .frame(maxWidth: .infinity)
            }.disabled(model.turningDisplayOff)
            Text(model.awakeActive ? "잠자기 방지를 유지하고 화면만 끕니다." : "작업을 계속하려면 잠자기 방지를 먼저 시작하세요.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.awakeError.isEmpty {
                Text(model.awakeError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LoginStartControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.loginRequested }, set: { model.toggleLogin($0) })) {
                Label("로그인 후 자동 시작", systemImage: "power")
                    .font(.system(size: 12, weight: .semibold))
            }.toggleStyle(.switch)
            Text(model.loginStatusText).font(.caption).foregroundStyle(.secondary)
            if model.loginPending {
                Button("시스템 설정에서 승인") { SMAppService.openSystemSettingsLoginItems() }
            }
            if !model.loginError.isEmpty { Text(model.loginError).font(.caption).foregroundStyle(.red) }
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
