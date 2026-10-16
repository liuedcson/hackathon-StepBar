import AppKit
import SwiftUI
import Carbon
import Combine

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store!
    var item: NSStatusItem!
    var panel: KeyPanel!
    var debugWindow: NSWindow?
    var hotkey: EventHotKeyRef?
    var localMonitor: Any?
    var flagsMonitor: Any?
    var voiceTimer: Timer?
    var pauseWatch: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Menu-bar apps have no main menu; without an Edit menu ⌘V/⌘C/⌘X/⌘A/⌘Z never reach text fields.
        let mainMenu = NSMenu(), editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        store = Store()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Brand.mark(size: 17)
        // Menu bar: black or white with the system theme. Half transparent means collection is paused. Nothing else changes it.
        pauseWatch = store.$paused.receive(on: RunLoop.main).sink { [weak self] paused in
            self?.item.button?.alphaValue = paused ? 0.4 : 1
            self?.item.button?.toolTip = paused ? "StepBar · 已暂停" : "StepBar · 阶跃星辰 Chrome AI 聚焦搜索"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "设置", action: #selector(settings), keyEquivalent: "")
        menu.addItem(withTitle: "暂停 / 恢复", action: #selector(pause), keyEquivalent: "")
        menu.addItem(withTitle: "退出 StepBar", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item.menu = menu
        // Borderless and transparent: the SwiftUI card sizes itself and the empty area below stays invisible.
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(self, selector: #selector(panelResigned), name: NSWindow.didResignKeyNotification, object: panel)
        panel.contentView = NSHostingView(rootView: LauncherView(store: store, open: { [weak self] in self?.run($0) }))
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in delegate.show() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        registerHotkey()
        NotificationCenter.default.addObserver(self, selector: #selector(registerHotkey), name: .init("StepBarSettingsChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(diagnostics), name: .init("StepBarShowDiagnostics"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(quit), name: .init("StepBarInstallUpdate"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            let command = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 53:
                if !self.store.query.isEmpty { self.store.query = "" } else { self.closePanel() }
                return nil
            case 125: self.store.moveSelection(1); return nil
            case 126: self.store.moveSelection(-1); return nil
            case 36, 76:
                if self.store.results.indices.contains(self.store.selection) { self.run(self.store.results[self.store.selection]) }
                return nil
            case 51 where command:
                self.store.closeSelected(); return nil
            case 48: self.store.generate(); return nil
            default: break
            }
            if command, event.charactersIgnoringModifiers == "," { self.settings(); return nil }
            if command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit), digit <= self.store.results.count {
                self.run(self.store.results[digit - 1]); return nil
            }
            return event
        }
        // Hold ⌥ alone for 0.3 s to talk; release to search with the transcript.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.type == .keyDown { self.voiceTimer?.invalidate(); return event }
            if flags == .option {
                self.voiceTimer?.invalidate()
                self.voiceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in Task { @MainActor in self.store.startVoice() } }
            } else {
                self.voiceTimer?.invalidate()
                if self.store.listening { self.store.stopVoice() }
            }
            return event
        }
        if CommandLine.arguments.contains("--diagnostics") { diagnostics() }
    }
    @objc func show() {
        if panel.isVisible && panel.isKeyWindow && NSApp.isActive { closePanel(); return }
        store.query = ""; store.yieldToForeground(); store.captureInvocation(); store.prepareLauncher()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.22 - panel.frame.height)) }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); store.focusRequest += 1
    }
    func closePanel() {
        panel.orderOut(nil); store.searchGeneration += 1; store.launcherOpen = false
        if store.listening { store.listening = false; _ = store.voice.stop(); store.intent = nil }
    }
    @objc func panelResigned() { if panel.isVisible { closePanel() } }
    func run(_ item: SearchItem) { closePanel(); store.open(item) }
    @objc func diagnostics() {
        closePanel()
        if debugWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "StepBar · Step 的理解与记忆"; window.isReleasedWhenClosed = false
            // Same glass as the panel: the window is clear, the glass view fills it and SwiftUI lists drop their backgrounds.
            window.titlebarAppearsTransparent = true; window.isOpaque = false; window.backgroundColor = .clear
            // Open on the current Space, including over full-screen apps; otherwise it lands on another desktop.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentView = Self.glass(NSHostingView(rootView: DiagnosticsView(store: store).padding(.top, 22))); debugWindow = window
        }
        debugWindow?.center(); NSApp.activate(ignoringOtherApps: true); debugWindow?.makeKeyAndOrderFront(nil)
    }
    static func glass(_ content: NSView) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(); glass.cornerRadius = 0; glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView(); effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        content.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: effect.leadingAnchor), content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                                     content.topAnchor.constraint(equalTo: effect.topAnchor), content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        return effect
    }
    @objc func settings() { store.diagnosticTab = "settings"; diagnostics() }
    @objc func registerHotkey() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        let (key, modifiers): (Int, Int) = switch store.settings.hotkey {
        case "controlL": (kVK_ANSI_L, controlKey)
        case "optionSpace": (kVK_Space, optionKey)
        default: (kVK_ANSI_M, cmdKey)
        }
        let result = RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x53545042, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        item.menu?.items.first?.title = "StepBar 搜索  \(store.settings.hotkeyLabel.replacingOccurrences(of: " ", with: ""))"
        if result != noErr { store.status = "快捷键已被占用，请从菜单栏唤出或在设置里切换。" }
    }
    @objc func wake() { store.resetAfterWake() }
    @objc func pause() { store.togglePause() }
    @objc func installExtension() { store.installExtension() }
    @objc func quit() { store.save(); Store.writer.sync {}; NSApp.terminate(nil) }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@main struct StepBarMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--update-check") {
            let updater = Updater()
            Task { await updater.check(); print(updater.status); exit(updater.status.contains("最新版本") || updater.available != nil ? 0 : 1) }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--configure-from-stdin") {
            do { try RuntimeChecks.configure() }
            catch { fputs("Configuration failed; check input and Keychain access.\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--export-local-config") {
            do { try RuntimeChecks.exportLocal() }
            catch { fputs("Local configuration export failed.\n", stderr); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--search-check"), index + 1 < CommandLine.arguments.count {
            let query = CommandLine.arguments[index + 1]
            Task { await RuntimeChecks.searchCheck(query); exit(0) }
            RunLoop.main.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--voice-check"), CommandLine.arguments.count > index + 1 {
            Task { await RuntimeChecks.voiceCheck(CommandLine.arguments[index + 1]); exit(0) }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--clean-check") { RuntimeChecks.cleanCheck(); return }
        if let index = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > index + 1 {
            exit(Brand.writeIconset(CommandLine.arguments[index + 1]) ? 0 : 1)
        }
        if CommandLine.arguments.contains("--understand") {
            Task { await RuntimeChecks.understand(rounds: Int(CommandLine.arguments.last ?? "") ?? 3); exit(0) }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--eval-search") {
            Task { await RuntimeChecks.evalSearch(ai: CommandLine.arguments.contains("--ai"), limit: 200); exit(0) }
            RunLoop.main.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--model-bench") {
            let queries = Array(CommandLine.arguments[(index + 1)...])
            Task { await RuntimeChecks.modelBench(queries); exit(0) }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--ai-self-check") {
            Task { await RuntimeChecks.liveCheck(); exit(0) }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
