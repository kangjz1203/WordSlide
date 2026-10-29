import AppKit
import ApplicationServices

/// Chromium creates its webpage accessibility tree only when an assistive client
/// requests it. Invoke `enable` on the selection reader's serial queue, once per
/// target App launch; the caller must allow the tree to finish initializing.
struct AccessibilityCompatibility {
    static func isChromiumOrElectron(_ app: NSRunningApplication) -> Bool {
        if isElectron(at: app.bundleURL) { return true }
        guard let identifier = app.bundleIdentifier?.lowercased() else { return false }
        let knownBrowserPrefixes = [
            "com.google.chrome", "org.chromium.chromium", "com.microsoft.edgemac",
            "com.brave.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera"
        ]
        return knownBrowserPrefixes.contains { identifier.hasPrefix($0) }
    }

    static func enable(pid: pid_t, appURL: URL?) {
        guard AXIsProcessTrusted() else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)

        let manual = "AXManualAccessibility" as CFString
        let enhanced = "AXEnhancedUserInterface" as CFString
        // Do not repeatedly set an active flag: Chromium debounces activation,
        // and another accessibility client may already have requested the tree.
        if isTrue(application, attribute: enhanced) { return }
        if isElectron(at: appURL) {
            // Electron explicitly supports this application-level attribute:
            // https://www.electronjs.org/docs/latest/tutorial/accessibility
            if isTrue(application, attribute: manual) { return }
            let status = AXUIElementSetAttributeValue(application, manual, kCFBooleanTrue)
            if status == .success || isTrue(application, attribute: manual) { return }
            // Unsupported Electron versions can still implement Chromium's
            // enhanced-interface path. Other errors do not justify another write.
            guard status == .attributeUnsupported || status == .notImplemented else { return }
        }

        // Chrome's setter starts its asynchronous activation before forwarding
        // to AppKit; its return code can be an error despite that side effect.
        // Do not infer completion from this return code or retry on every click.
        // https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/chrome_browser_application_mac.mm
        _ = AXUIElementSetAttributeValue(application, enhanced, kCFBooleanTrue)
        // Never turn these flags off on dismissal/exit: other assistive clients
        // may depend on the same App-wide accessibility mode.
    }

    private static func isElectron(at appURL: URL?) -> Bool {
        guard let appURL = appURL else { return false }
        let framework = appURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: framework.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isTrue(_ element: AXUIElement, attribute: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let boolean = value as? NSNumber else { return false }
        return boolean.boolValue
    }
}
