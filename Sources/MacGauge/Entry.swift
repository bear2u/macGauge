import AppKit
import SwiftUI
import MacGaugeCore

@main @MainActor enum MacGaugeMain {
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            let first = Metrics.read(previous: nil)
            Thread.sleep(forTimeInterval: 0.3)
            let (value, _) = Metrics.read(previous: first.1)
            let processes = try? ProcessSampler.read()
            print("cpu=\(value.cpu) memory=\(value.memoryUsed)/\(value.memoryTotal) pressure=\(value.pressure) swap=\(value.swapUsed) free=\(value.diskFree) processes=\(processes?.count ?? -1)")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var dismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var item: NSStatusItem!
    private var statusPanel: StatusPanel!
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch opens the existing app, rather than adding another monitor.
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.symverse.MacGauge")
        if let other = siblings.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "MacGauge")
        let panelItem = appMenu.addItem(withTitle: "상태바 패널 보기", action: #selector(togglePopover), keyEquivalent: "1")
        panelItem.target = self
        let dashboardItem = appMenu.addItem(withTitle: "상세 창 열기", action: #selector(openWindowAction), keyEquivalent: "2")
        dashboardItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = appMenu.addItem(withTitle: "MacGauge 종료", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "MacGauge")
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        item.button?.setAccessibilityLabel("MacGauge 시스템 지표")
        statusPanel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 550),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        statusPanel.title = "MacGauge 상태바 패널"
        statusPanel.isOpaque = false; statusPanel.backgroundColor = .clear
        statusPanel.hasShadow = true; statusPanel.level = .popUpMenu
        statusPanel.hidesOnDeactivate = false; statusPanel.isReleasedWhenClosed = false
        statusPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        statusPanel.dismiss = { [weak self] in self?.hideStatusPanel() }
        statusPanel.contentViewController = NSHostingController(rootView:
            CompactView(model: model, showDashboard: { [weak self] in self?.showWindow() })
                .frame(width: 360, height: 550)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18)))
        model.onStatusUpdate = { [weak self] in self?.updateStatus() }
        model.start(); updateStatus()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstLaunch || CommandLine.arguments.contains("--show-window") { showWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshLoginStatus() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.deleting { model.message = "정리를 마친 뒤 종료할 수 있습니다."; showWindow(); return .terminateCancel }
        model.cancelScan(); model.stopKeepingAwake(); return .terminateNow
    }
    func updateStatus() {
        let cpu = model.hasCPUSample ? DisplayFormat.percent(model.snapshot.cpu) : "—"
        item.button?.title = " CPU \(cpu)" + (model.showMemoryInBar ? "  MEM \(DisplayFormat.percent(model.snapshot.memoryFraction))" : "")
        item.button?.image = NSImage(systemSymbolName: model.awakeActive ? "cup.and.saucer.fill" : "waveform.path.ecg",
                                    accessibilityDescription: model.awakeActive ? "잠자기 방지 켜짐" : "MacGauge")
        item.button?.toolTip = "MacGauge · 메모리 압력 \(model.pressureTitle) · 디스크 \(DisplayFormat.bytes(model.snapshot.diskFree)) 여유\n잠자기 방지: \(model.awakeStatus)"
    }
    @objc func togglePopover() {
        model.refreshLoginStatus()
        if NSApp.currentEvent?.type == .rightMouseUp {
            hideStatusPanel()
            let menu = NSMenu()
            menu.addItem(withTitle: "MacGauge 열기", action: #selector(openWindowAction), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "종료", action: #selector(quit), keyEquivalent: "q")
            for entry in menu.items { entry.target = self }
            item.menu = menu; item.button?.performClick(nil); item.menu = nil
            return
        }
        if statusPanel.isVisible { hideStatusPanel() }
        else if let button = item.button, let anchorWindow = button.window,
                let screen = anchorWindow.screen ?? NSScreen.main {
            let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let width = statusPanel.frame.width, height = statusPanel.frame.height
            let bounds = screen.visibleFrame
            let x = min(max(anchor.midX - width / 2, bounds.minX + 8), bounds.maxX - width - 8)
            // Keep the entire panel below the menu bar, with a deliberate six-point gap.
            let top = min(anchor.minY, bounds.maxY) - 6
            statusPanel.setFrameOrigin(NSPoint(x: x, y: max(bounds.minY + 8, top - height)))
            NSApp.activate(ignoringOtherApps: true)
            statusPanel.makeKeyAndOrderFront(nil)
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hideStatusPanel() }
            }
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // Let the status button itself toggle the panel on mouse-up.
                if let self, event.window != self.statusPanel, event.window != self.item.button?.window,
                   event.window?.level != .popUpMenu { self.hideStatusPanel() }
                return event
            }
            model.panelVisible = true; model.refresh()
        }
    }
    private func hideStatusPanel() {
        statusPanel.orderOut(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil; localClickMonitor = nil
        model.panelVisible = window?.isVisible == true
    }
    @objc func openWindowAction() { showWindow() }
    func showWindow() {
        model.refreshLoginStatus()
        hideStatusPanel()
        if window == nil {
            let controller = NSHostingController(rootView: DashboardView(model: model))
            let newWindow = NSWindow(contentViewController: controller)
            newWindow.title = "MacGauge"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 700, height: 770))
            newWindow.minSize = NSSize(width: 660, height: 710)
            newWindow.isReleasedWhenClosed = false; newWindow.delegate = self; newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.panelVisible = true; model.refresh()
    }
    func windowWillClose(_ notification: Notification) { model.panelVisible = statusPanel.isVisible }
    @objc func quit() { NSApp.terminate(nil) }
}
