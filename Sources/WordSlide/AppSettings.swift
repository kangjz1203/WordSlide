import AppKit
import ApplicationServices
import Foundation
import Security
import ServiceManagement
import SwiftUI

/// Preferences stay on this Mac; API credentials are stored only in the login Keychain.
@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults: UserDefaults

    @Published var provider: DictionaryProvider {
        didSet { defaults.set(provider.rawValue, forKey: "provider") }
    }
    @Published var automaticLookup: Bool {
        didSet { defaults.set(automaticLookup, forKey: "automaticLookup") }
    }
    @Published var optionOnly: Bool {
        didSet { defaults.set(optionOnly, forKey: "optionOnly") }
    }
    @Published var clipboardFallback: Bool {
        didSet { defaults.set(clipboardFallback, forKey: "clipboardFallback") }
    }
    @Published var oxfordAppID: String
    @Published var oxfordAppKey: String
    @Published var oxfordLanguage: String {
        didSet { defaults.set(oxfordLanguage, forKey: "oxfordLanguage") }
    }
    @Published var oxfordChinese: Bool {
        didSet { defaults.set(oxfordChinese, forKey: "oxfordChinese") }
    }
    @Published var collinsKey: String
    @Published var collinsDictionary: String {
        didSet { defaults.set(collinsDictionary, forKey: "collinsDictionary") }
    }
    @Published var excludedBundleIDs: String {
        didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") }
    }
    @Published private(set) var credentialsError: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginStatusText = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = DictionaryProvider(rawValue: defaults.string(forKey: "provider") ?? "system") ?? .system
        automaticLookup = defaults.object(forKey: "automaticLookup") as? Bool ?? true
        optionOnly = defaults.object(forKey: "optionOnly") as? Bool ?? false
        clipboardFallback = defaults.object(forKey: "clipboardFallback") as? Bool ?? false
        oxfordLanguage = defaults.string(forKey: "oxfordLanguage") ?? "en-gb"
        oxfordChinese = defaults.object(forKey: "oxfordChinese") as? Bool ?? true
        collinsDictionary = defaults.string(forKey: "collinsDictionary") ?? "english"
        excludedBundleIDs = defaults.string(forKey: "excludedBundleIDs") ?? ""
        oxfordAppID = ""
        oxfordAppKey = ""
        collinsKey = ""
        do {
            oxfordAppID = try CredentialStore.read("oxford-app-id")
            oxfordAppKey = try CredentialStore.read("oxford-app-key")
            collinsKey = try CredentialStore.read("collins-key")
        } catch {
            credentialsError = error.localizedDescription
        }
        refreshLoginStatus()
    }

    var configuration: LookupConfiguration {
        LookupConfiguration(
            provider: provider,
            oxfordAppID: oxfordAppID.trimmingCharacters(in: .whitespacesAndNewlines),
            oxfordAppKey: oxfordAppKey.trimmingCharacters(in: .whitespacesAndNewlines),
            oxfordLanguage: oxfordLanguage,
            oxfordChinese: oxfordChinese,
            collinsKey: collinsKey.trimmingCharacters(in: .whitespacesAndNewlines),
            collinsDictionary: collinsDictionary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @discardableResult func saveCredentials() -> Bool {
        do {
            switch provider {
            case .system: break
            case .oxford:
                try CredentialStore.write(oxfordAppID.trimmingCharacters(in: .whitespacesAndNewlines), account: "oxford-app-id")
                try CredentialStore.write(oxfordAppKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "oxford-app-key")
            case .collins:
                try CredentialStore.write(collinsKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "collins-key")
            }
            credentialsError = nil
            return true
        } catch {
            credentialsError = error.localizedDescription
            return false
        }
    }

    func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            loginStatusText = "已启用，可在系统设置 → 通用 → 登录项中管理。"
        case .requiresApproval:
            launchAtLogin = true
            loginStatusText = "等待批准：请在系统设置 → 通用 → 登录项中允许 WordSlide。"
        case .notRegistered:
            launchAtLogin = false
            loginStatusText = "启用后，登录 Mac 时自动在菜单栏运行。"
        case .notFound:
            launchAtLogin = false
            loginStatusText = "请先将 WordSlide.app 放在固定位置，再启用登录启动。"
        @unknown default:
            launchAtLogin = false
            loginStatusText = "系统暂时无法读取登录项状态。"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            loginStatusText = "无法更改登录项：\(error.localizedDescription)"
        }
    }
}

private enum CredentialStore {
    static let service = "com.wordslide.mac.dictionary-credentials"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)"
            return "无法访问登录钥匙串：\(detail)。输入的凭据仍可在本次运行使用，请解锁钥匙串后重新保存。"
        }
    }

    static func read(_ account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return value
    }

    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = Data(value.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }
}
