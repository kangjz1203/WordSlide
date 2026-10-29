import AppKit
import SwiftUI
import ApplicationServices
import Carbon

@main
struct WordSlideApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

private let hotKeySignature: OSType = 0x57534C44 // WSLD

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let state = LookupState()
    private let diagnostics = SelectionDiagnostics()
    private let dictionary = DictionaryService()
    private var statusItem: NSStatusItem!
    private var panel: DictionaryPanel!
    private var settingsWindow: NSWindow?
    private var selectionMonitor: SelectionMonitor!
    private var lookupTask: Task<Void, Never>?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var localMouseMonitor: Any?
    private var hotKeyStatus: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Do not run two copies that compete for the hotkey and clipboard.
        let identifier = Bundle.main.bundleIdentifier ?? "local.wordslide.app"
        if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            NSApp.terminate(nil)
            return
        }
        buildPanel()
        buildMenu()
        selectionMonitor = SelectionMonitor(settings: settings, onSelection: { [weak self] word, point in
            self?.lookup(word, at: point)
        }, onFailure: { [weak self] message in
            self?.showError(message)
        }, onDismiss: { [weak self] in
            self?.dismissPanel()
        }, onStatus: { [weak self] status in
            self?.diagnostics.status = status
        })
        selectionMonitor.start()
        registerHotKey()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self = self, event.window !== self.panel { self.dismissPanel() }
            return event
        }
        if CommandLine.arguments.contains("--smoke-test") {
            lookup("serendipity", at: NSEvent.mouseLocation)
        } else if !UserDefaults.standard.bool(forKey: "hasOpenedWordSlide") || !AXIsProcessTrusted() {
            UserDefaults.standard.set(true, forKey: "hasOpenedWordSlide")
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lookupTask?.cancel()
        selectionMonitor?.stop()
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        if let handler = hotKeyHandler { RemoveEventHandler(handler) }
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: "WordSlide 划词词典")
        statusItem.button?.toolTip = "WordSlide · 划词词典"
        let menu = NSMenu()
        let header = NSMenuItem(title: "WordSlide · 划词词典", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        addItem("输入单词…", action: #selector(openSearch), to: menu)
        addItem("查询当前选区  ⌃⌥D", action: #selector(lookupSelection), to: menu)
        menu.addItem(.separator())
        let automatic = addItem("自动划词", action: #selector(toggleAutomatic(_:)), to: menu)
        automatic.state = settings.automaticLookup ? .on : .off
        automatic.tag = 10
        addItem("设置…", action: #selector(openSettings), key: ",", to: menu)
        addItem("授权辅助功能…", action: #selector(requestAccessibility), to: menu)
        menu.addItem(.separator())
        addItem("退出 WordSlide", action: #selector(quit), key: "q", to: menu)
        menu.delegate = self
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "WordSlide")
        addItem("输入单词…", action: #selector(openSearch), key: "l", to: applicationMenu)
        addItem("设置…", action: #selector(openSettings), key: ",", to: applicationMenu)
        applicationMenu.addItem(.separator())
        addItem("关闭窗口", action: #selector(closeKeyWindow), key: "w", to: applicationMenu)
        addItem("退出 WordSlide", action: #selector(quit), key: "q", to: applicationMenu)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func buildPanel() {
        panel = DictionaryPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 520),
                                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.title = "WordSlide"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.onEscape = { [weak self] in self?.dismissPanel() }
        panel.contentView = NSHostingView(rootView: PopupView(state: state, onClose: { [weak self] in
            self?.dismissPanel()
        }, onLookup: { [weak self] text in
            guard let self = self else { return }
            self.lookup(text, at: nil)
        }, onSettings: { [weak self] in self?.openSettings() }))
    }

    private func presentPanel(at point: NSPoint?, focus: Bool = false) {
        if let point = point {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
            let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let width = min(CGFloat(410), area.width - 24)
            let height = min(CGFloat(520), area.height - 24)
            let x = min(max(point.x + 14, area.minX + 12), area.maxX - width - 12)
            let preferredY = point.y - height - 16
            let y = min(max(preferredY, area.minY + 12), area.maxY - height - 12)
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            // A non-activating panel lets the source app keep its selection and keyboard focus.
            panel.orderFrontRegardless()
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else { panel.alphaValue = 1 }
    }

    private func lookup(_ input: String, at point: NSPoint?) {
        guard let word = EnglishWord.normalize(input) else {
            showError("请选择或输入一个英文单词；支持 can't、well-being 等形式。")
            return
        }
        lookupTask?.cancel()
        state.word = word
        state.result = nil
        state.error = nil
        state.isLoading = true
        presentPanel(at: point)
        let configuration = settings.configuration
        lookupTask = Task { [weak self, dictionary] in
            do {
                let result = try await dictionary.lookup(word, configuration: configuration)
                try Task.checkCancellation()
                self?.state.result = result
                self?.state.isLoading = false
            } catch is CancellationError {
                // A new selection, dismissal, or quitting cancels obsolete results.
            } catch {
                guard !Task.isCancelled else { return }
                self?.state.error = error.localizedDescription
                self?.state.isLoading = false
            }
        }
    }

    private func showError(_ message: String) {
        lookupTask?.cancel()
        state.isLoading = false
        state.word = ""
        state.result = nil
        state.error = message
        presentPanel(at: NSEvent.mouseLocation)
    }

    private func dismissPanel() {
        selectionMonitor?.cancelPendingLookup()
        lookupTask?.cancel()
        panel?.orderOut(nil)
    }

    @objc private func openSearch() {
        selectionMonitor?.cancelPendingLookup()
        lookupTask?.cancel()
        state.word = ""
        state.result = nil
        state.error = nil
        state.isLoading = false
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        presentPanel(at: NSPoint(x: screen.midX - 210, y: screen.midY + 260), focus: true)
    }

    @objc private func lookupSelection() {
        // Allow the status menu and keyboard modifiers to settle before inspecting the source app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.selectionMonitor.lookupSelection()
        }
    }

    @objc private func toggleAutomatic(_ sender: NSMenuItem) {
        settings.automaticLookup.toggle()
        sender.state = settings.automaticLookup ? .on : .off
        if !settings.automaticLookup { dismissPanel() }
    }

    @objc private func openSettings() {
        dismissPanel()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "WordSlide 设置"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 570, height: 520)
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, diagnostics: diagnostics, onRequestAccessibility: { [weak self] in
                self?.requestAccessibility()
            }, onOpenSearch: { [weak self] in
                self?.settingsWindow?.orderOut(nil)
                self?.openSearch()
            }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        if let message = hotKeyStatus {
            let alert = NSAlert()
            alert.messageText = "快捷键注册失败"
            alert.informativeText = message
            alert.beginSheetModal(for: settingsWindow!)
            hotKeyStatus = nil
        }
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func closeKeyWindow() {
        if NSApp.keyWindow === panel { dismissPanel() }
        else { NSApp.keyWindow?.performClose(nil) }
    }

    private func registerHotKey() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context = context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.lookupSelection() }
            return noErr
        }, 1, &type, context, &hotKeyHandler)
        let identifier = EventHotKeyID(signature: hotKeySignature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), identifier,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if handlerStatus != noErr || status != noErr {
            hotKeyStatus = "⌃⌥D 可能已被其他 App 占用。你仍可以通过菜单栏“查询当前选区”或“输入单词”查词。"
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 10)?.state = settings.automaticLookup ? .on : .off
    }
}

final class DictionaryPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
