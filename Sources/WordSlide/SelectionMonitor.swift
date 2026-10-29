import AppKit
import ApplicationServices
import Carbon

/// Reads only selections after a selection gesture or the explicit lookup hotkey.
/// Automatic lookup never synthesizes keystrokes and never reads the clipboard.
@MainActor final class SelectionMonitor {
    private let settings: AppSettings
    private let onSelection: (String, NSPoint) -> Void
    private let onFailure: (String) -> Void
    private let onDismiss: () -> Void
    private let onStatus: (String) -> Void
    private var eventMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var pendingTask: Task<Void, Never>?
    private var generation = 0
    private var gesture = SelectionGestureTracker()
    private var gestureInProgress = false
    private var activeRequestPID: pid_t?
    private var warmups: [pid_t: Task<Void, Never>] = [:]
    private var terminationObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var wasTrusted = AXIsProcessTrusted()
    private let readerQueue = DispatchQueue(label: "app.wordslide.selection", qos: .userInitiated)

    init(settings: AppSettings,
         onSelection: @escaping (String, NSPoint) -> Void,
         onFailure: @escaping (String) -> Void,
         onDismiss: @escaping () -> Void,
         onStatus: @escaping (String) -> Void = { _ in }) {
        self.settings = settings
        self.onSelection = onSelection
        self.onFailure = onFailure
        self.onDismiss = onDismiss
        self.onStatus = onStatus
    }

    func start() {
        guard eventMonitor == nil else { return }
        installMouseMonitor()
        onStatus(AXIsProcessTrusted() ? "等待选词操作。" : "辅助功能未生效，自动取词已暂停。")
        if let app = eligibleFrontmostApplication() { _ = warmup(for: app) }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermission() }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.warmups.removeValue(forKey: app.processIdentifier)?.cancel()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    self.cancelPending()
                } else {
                    // A delayed notification for the selection's own source must not cancel it.
                    if self.activeRequestPID != app.processIdentifier && !self.gestureInProgress {
                        self.cancelPending()
                        self.gesture.reset()
                        self.onDismiss()
                    }
                    _ = self.warmup(for: app)
                }
            }
        }
    }

    private struct MouseSnapshot {
        let type: NSEvent.EventType
        let point: CGPoint
        let clickCount: Int
        let flags: NSEvent.ModifierFlags
    }

    private func installMouseMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Global events are delivered asynchronously. Live mouseLocation may already
            // be at mouse-up when a queued mouse-down is processed. Use the event's point.
            guard let point = event.cgEvent?.location else { return }
            let snapshot = MouseSnapshot(type: event.type, point: point,
                                         clickCount: event.clickCount, flags: event.modifierFlags)
            self?.handleMouse(snapshot)
        }
    }

    private func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        guard trusted != wasTrusted else { return }
        wasTrusted = trusted
        cancelPending()
        gesture.reset()
        installMouseMonitor()
        if trusted {
            onStatus("辅助功能已生效，等待选词操作。")
            if let app = eligibleFrontmostApplication() { _ = warmup(for: app) }
        } else {
            for task in warmups.values { task.cancel() }
            warmups.removeAll()
            onStatus("辅助功能未生效，自动取词已暂停。")
        }
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        for task in warmups.values { task.cancel() }
        warmups.removeAll()
        gesture.reset()
        cancelPending()
    }

    /// Called by the registered Control–Option–D hotkey. Clipboard fallback is opt-in.
    func lookupSelection() {
        cancelPending()
        guard AXIsProcessTrusted() else {
            onFailure("请先在「系统设置 → 隐私与安全性 → 辅助功能」中允许 WordSlide，然后重试。")
            return
        }
        guard let app = eligibleFrontmostApplication() else {
            onFailure("当前 App 已被排除，或 WordSlide 正在前台。请先回到需要查词的 App。")
            return
        }
        beginLookup(in: app, quartzPoint: CGEvent(source: nil)?.location ?? .zero, automatic: false)
    }

    private func handleMouse(_ event: MouseSnapshot) {
        if event.type != .leftMouseUp {
            cancelPending()
            onDismiss()
            gestureInProgress = event.type == .leftMouseDown
            if gestureInProgress { gesture.mouseDown(at: event.point) }
            else { gesture.reset() }
            return
        }
        let selected = gesture.mouseUp(at: event.point, clickCount: event.clickCount, shift: event.flags.contains(.shift))
        gestureInProgress = false
        guard selected else { return }
        guard settings.automaticLookup else { onStatus("已收到选词手势；自动划词当前关闭。" ); return }
        guard AXIsProcessTrusted() else { onStatus("已收到选词手势，但辅助功能权限尚未生效。" ); return }
        guard !settings.optionOnly || event.flags.contains(.option) else {
            onStatus("已收到选词手势；当前设置要求同时按住 Option。")
            return
        }
        guard let app = eligibleFrontmostApplication() else { return }
        beginLookup(in: app, quartzPoint: event.point, automatic: true)
    }

    /// Use before local search/settings interactions so an older AX request cannot reopen a panel.
    func cancelPendingLookup() {
        cancelPending()
        gesture.reset()
        gestureInProgress = false
    }

    private func cancelPending() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        activeRequestPID = nil
    }

    private func eligibleFrontmostApplication() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !excludedBundleIDs.contains(app.bundleIdentifier ?? "") else { return nil }
        return app
    }

    private var excludedBundleIDs: Set<String> {
        Set(settings.excludedBundleIDs
            .components(separatedBy: CharacterSet(charactersIn: "\n,; "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    private func sourceIsCurrent(_ pid: pid_t, generation expected: Int) -> Bool {
        generation == expected && eligibleFrontmostApplication()?.processIdentifier == pid
    }

    private func warmup(for app: NSRunningApplication) -> Task<Void, Never>? {
        guard AXIsProcessTrusted(), !excludedBundleIDs.contains(app.bundleIdentifier ?? ""),
              AccessibilityCompatibility.isChromiumOrElectron(app) else { return nil }
        let pid = app.processIdentifier
        if let existing = warmups[pid] { return existing }
        let appURL = app.bundleURL
        let task = Task { [readerQueue] in
            await withCheckedContinuation { continuation in
                readerQueue.async {
                    AccessibilityCompatibility.enable(pid: pid, appURL: appURL)
                    continuation.resume()
                }
            }
            // Chromium deliberately debounces full webpage accessibility activation by 2 s.
            try? await Task.sleep(nanoseconds: 2_300_000_000)
        }
        warmups[pid] = task
        return task
    }

    private func beginLookup(in app: NSRunningApplication, quartzPoint: CGPoint, automatic: Bool) {
        pendingTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let pid = app.processIdentifier
        activeRequestPID = pid
        let primaryHeight = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        let point = NSPoint(x: quartzPoint.x, y: primaryHeight - quartzPoint.y)
        let allowCopy = !automatic && settings.clipboardFallback
        let accessibilityWarmup = warmup(for: app)
        let sourceName = app.localizedName ?? "当前 App"
        onStatus("\(sourceName)：正在读取选区。")
        pendingTask = Task { [weak self] in
            guard let self else { return }
            if let accessibilityWarmup {
                await accessibilityWarmup.value
            }
            // Native controls and web views publish their selection shortly after mouse-up.
            if automatic {
                try? await Task.sleep(nanoseconds: 130_000_000)
            }
            guard !Task.isCancelled, self.sourceIsCurrent(pid, generation: requestGeneration) else { return }
            var result: SelectionReadResult = .none
            for delay: UInt64 in [0, 130_000_000, 250_000_000] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, self.sourceIsCurrent(pid, generation: requestGeneration) else { return }
                result = await self.readSelection(pid: pid, point: quartzPoint)
                if case .none = result { continue }
                break
            }
            guard !Task.isCancelled, self.sourceIsCurrent(pid, generation: requestGeneration) else { return }
            switch result {
            case .secure:
                self.onStatus("\(sourceName)：当前为受保护输入区域，已跳过。")
                if !automatic { self.onFailure("受保护的输入区域不支持划词。请在普通文本中选中一个英文单词。") }
                return
            case .text(let text):
                self.onStatus(EnglishWord.normalize(text) == nil ? "\(sourceName)：选区不是单个英文词。" : "\(sourceName)：已读到英文词，正在查询。")
                self.deliver(text, at: point, automatic: automatic)
                return
            case .none:
                self.onStatus("\(sourceName)：已检测到选词，但未读到文字；可尝试 ⌃⌥D 复制取词。")
                break
            }
            if allowCopy {
                do {
                    let copied = try await self.copySelection(from: pid, generation: requestGeneration)
                    guard !Task.isCancelled, self.sourceIsCurrent(pid, generation: requestGeneration) else { return }
                    self.onStatus("\(sourceName)：已通过手动复制取词。")
                    self.deliver(copied, at: point, automatic: false)
                } catch {
                    guard !Task.isCancelled, self.sourceIsCurrent(pid, generation: requestGeneration) else { return }
                    self.onFailure(error.localizedDescription)
                }
            } else if !automatic {
                self.onFailure("没有读到选中的文字。请选中一个英文单词；如该 App 不支持辅助功能取词，可在设置中开启「快捷键取词失败时，尝试模拟 ⌘C」。图片和扫描 PDF 需先进行文字识别。")
            }
        }
    }

    private func deliver(_ text: String, at point: NSPoint, automatic: Bool) {
        guard let word = EnglishWord.normalize(text) else {
            if !automatic { onFailure("请只选中一个英文单词（支持连字符和缩写），然后按 ⌃⌥D。") }
            return
        }
        onSelection(word, point)
    }

    private func readSelection(pid: pid_t, point: CGPoint) async -> SelectionReadResult {
        let cancellation = AXReadCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                readerQueue.async {
                    let result = SelectionReader(pid: pid, point: point, cancellation: cancellation).read()
                    continuation.resume(returning: result)
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    // MARK: Explicit, opt-in clipboard compatibility

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let changeCount: Int
    }

    private func snapshotPasteboard() throws -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        var size = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // Refuse the fallback if any representation cannot be preserved.
                guard let data = item.data(forType: type) else { throw CopyFallbackError.cannotPreserve }
                size += data.count
                guard size <= 32 * 1_024 * 1_024 else { throw CopyFallbackError.cannotPreserve }
                representations[type] = data
            }
            items.append(representations)
        }
        guard pasteboard.changeCount == count else { throw CopyFallbackError.clipboardChanged }
        return PasteboardSnapshot(items: items, changeCount: count)
    }

    private func restore(_ snapshot: PasteboardSnapshot, ifCurrentChangeCount count: Int) {
        let pasteboard = NSPasteboard.general
        // A newer copy operation belongs to the user or another App: leave it alone.
        guard pasteboard.changeCount == count else { return }
        let items: [NSPasteboardItem] = snapshot.items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func copySelection(from pid: pid_t, generation expected: Int) async throws -> String {
        // Wait for Control/Option to be released so the source App receives a plain Command-C.
        for _ in 0..<35 {
            guard !Task.isCancelled, sourceIsCurrent(pid, generation: expected) else { throw CancellationError() }
            if NSEvent.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard NSEvent.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty else {
            throw CopyFallbackError.modifiersHeld
        }
        guard !Task.isCancelled, sourceIsCurrent(pid, generation: expected), AXIsProcessTrusted(),
              !IsSecureEventInputEnabled() else { throw CopyFallbackError.unavailable }
        // Recheck the focused field immediately before synthesizing a copy.
        let securityCheck = await readSelection(pid: pid, point: CGEvent(source: nil)?.location ?? .zero)
        if case .secure = securityCheck { throw CopyFallbackError.unavailable }
        if case .text(let text) = securityCheck { return text }
        guard !Task.isCancelled, sourceIsCurrent(pid, generation: expected) else { throw CancellationError() }
        let snapshot = try snapshotPasteboard()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x08, keyDown: false) else {
            throw CopyFallbackError.unavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        var observedCount: Int?
        // Once a copy has been sent, finish cleanup even when a new click cancels lookup.
        // A Dispatch timer keeps cancellation from skipping clipboard restoration.
        for _ in 0..<40 {
            await noncancellingDelay(20)
            let current = NSPasteboard.general.changeCount
            if current != snapshot.changeCount {
                // Only claim the clipboard while the same source App remains frontmost.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    throw CopyFallbackError.clipboardChanged
                }
                observedCount = current
                break
            }
        }
        guard let observedCount else { throw CopyFallbackError.noSelection }
        // Delayed / promised representations must finish before reading and restoring.
        await noncancellingDelay(40)
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == observedCount else { throw CopyFallbackError.clipboardChanged }
        defer { restore(snapshot, ifCurrentChangeCount: observedCount) }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            throw CopyFallbackError.noSelection
        }
        return text
    }

    private func noncancellingDelay(_ milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}

private enum CopyFallbackError: LocalizedError {
    case cannotPreserve, clipboardChanged, modifiersHeld, unavailable, noSelection
    var errorDescription: String? {
        switch self {
        case .cannotPreserve:
            return "当前剪贴板包含无法完整保存或体积过大的内容，本次未执行复制。可手动复制单词后在菜单中查词。"
        case .clipboardChanged:
            return "复制期间剪贴板发生了其他变化，已停止取词。请重新选择后重试。"
        case .modifiersHeld:
            return "请按一下并松开 ⌃⌥D 后再查词。"
        case .unavailable:
            return "当前输入区域禁止读取或复制。请检查辅助功能权限，或在普通文本中选词。"
        case .noSelection:
            return "该 App 没有复制出选中的文字。可使用菜单中的手动查词；图片和扫描 PDF 需要先做文字识别。"
        }
    }
}

private enum SelectionReadResult {
    case text(String)
    case secure
    case none
}

/// Thread-safe cancellation lets a superseded request stop walking an AX tree.
private final class AXReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// All synchronous IPC to other Apps lives on a dedicated queue, with bounded work.
private final class SelectionReader {
    let pid: pid_t
    let point: CGPoint
    let cancellation: AXReadCancellation
    let deadline = ProcessInfo.processInfo.systemUptime + 1.0
    var visited = Set<CFHashCode>()

    init(pid: pid_t, point: CGPoint, cancellation: AXReadCancellation) {
        self.pid = pid
        self.point = point
        self.cancellation = cancellation
    }

    var shouldStop: Bool { cancellation.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline }

    func read() -> SelectionReadResult {
        guard !shouldStop, AXIsProcessTrusted() else { return .none }
        if IsSecureEventInputEnabled() { return .secure }
        let application = AXUIElementCreateApplication(pid)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(application, 0.08)
        AXUIElementSetMessagingTimeout(system, 0.08)
        let focused = element(attribute(application, kAXFocusedUIElementAttribute))
            ?? element(attribute(system, kAXFocusedUIElementAttribute))
        if let focused, secure(focused) { return .secure }

        // Mouse location often identifies a PDF or web content element better than keyboard focus.
        var hovered: AXUIElement?
        if !shouldStop {
            AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hovered)
        }
        if let hovered, owned(hovered) {
            var candidate: AXUIElement? = hovered
            for _ in 0..<14 {
                guard let current = candidate, !shouldStop else { break }
                if secure(current) { return .secure }
                if let text = selectedText(current) { return .text(text) }
                candidate = element(attribute(current, kAXParentAttribute))
            }
        }
        if let focused, owned(focused), !shouldStop {
            var candidate: AXUIElement? = focused
            for _ in 0..<14 {
                guard let current = candidate, !shouldStop else { break }
                if secure(current) { return .secure }
                if let text = selectedText(current) { return .text(text) }
                candidate = element(attribute(current, kAXParentAttribute))
            }
            if let text = searchChildren(of: focused) { return .text(text) }
        }
        // Some document Apps expose selection on a descendant of the active window.
        if !shouldStop, let window = element(attribute(application, kAXFocusedWindowAttribute)),
           let text = searchChildren(of: window) {
            return .text(text)
        }
        return .none
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        guard !shouldStop else { return false }
        // AX timeout settings belong to the individual reference; descendants and
        // parent references must be configured before their first synchronous IPC.
        AXUIElementSetMessagingTimeout(element, 0.08)
        return !shouldStop
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func owned(_ element: AXUIElement) -> Bool {
        var owner: pid_t = 0
        return prepare(element) && AXUIElementGetPid(element, &owner) == .success && owner == pid
    }

    private func secure(_ element: AXUIElement) -> Bool {
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        return subrole == kAXSecureTextFieldSubrole
    }

    private func selectedText(_ element: AXUIElement) -> String? {
        guard !shouldStop, !secure(element) else { return nil }
        return AccessibilitySelectedText.read(attribute: { name in
            self.attribute(element, name)
        }, parameterized: { name, parameter in
            guard self.prepare(element) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString,
                                                             parameter, &value) == .success else { return nil }
            return value
        })
    }

    private func searchChildren(of root: AXUIElement) -> String? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 48, !shouldStop {
            let (current, depth) = queue[index]
            index += 1
            let hash = CFHash(current)
            guard visited.insert(hash).inserted else { continue }
            // Do not inspect descendants of secure fields.
            if secure(current) { continue }
            if let text = selectedText(current) { return text }
            guard depth < 5, !shouldStop else { continue }
            var count: CFIndex = 0
            guard prepare(current),
                  AXUIElementGetAttributeValueCount(current, kAXChildrenAttribute as CFString, &count) == .success,
                  count > 0 else { continue }
            var children: CFArray?
            // Fetch only a bounded prefix instead of materializing an entire document's AX tree.
            let limit = min(count, max(0, 48 - queue.count))
            guard limit > 0, prepare(current),
                  AXUIElementCopyAttributeValues(current, kAXChildrenAttribute as CFString, 0, limit, &children) == .success,
                  let children = children as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }
}
