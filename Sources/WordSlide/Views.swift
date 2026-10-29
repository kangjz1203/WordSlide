import AppKit
import ApplicationServices
import SwiftUI

@MainActor struct PopupView: View {
    @ObservedObject var state: LookupState
    let onClose: () -> Void
    let onLookup: (String) -> Void
    let onSettings: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "character.book.closed")
                        .foregroundStyle(.secondary)
                    Text("WordSlide").font(.headline)
                    Spacer()
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help("打开设置")
                    .accessibilityLabel("打开设置")
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭（Esc）")
                    .accessibilityLabel("关闭词典窗口")
                }
                HStack(spacing: 8) {
                    TextField("输入英文单词", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { onLookup(query) }
                        .accessibilityLabel("查词")
                    Button("查询") { onLookup(query) }
                }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state.isLoading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在查询 \(state.word)…").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    } else if let error = state.error {
                        Label("查询未完成", systemImage: "exclamationmark.circle")
                            .font(.headline)
                        Text(error).textSelection(.enabled)
                        Button("重试") { onLookup(query) }
                    } else if let result = state.result {
                        Text(result.word).font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Text(result.source).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let notice = result.notice, !notice.isEmpty {
                            Text(notice).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        ForEach(result.sections) { section in
                            VStack(alignment: .leading, spacing: 7) {
                                if !section.heading.isEmpty {
                                    Text(section.heading).font(.headline)
                                        .textSelection(.enabled)
                                }
                                Text(section.body)
                                    .font(.body)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        if let url = result.sourceURL {
                            Link("查看来源", destination: url).font(.caption)
                        }
                    } else {
                        Text("选中一个英文单词即可查词。")
                            .font(.headline)
                        Text("也可以输入单词，或在其他 App 中选词后按 Control + Option + D。")
                            .foregroundStyle(.secondary)
                        Text("首次使用请在设置中授予辅助功能权限。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            HStack {
                Text("⌃⌥D 查询选区").font(.caption)
                Spacer()
                Text("Esc 关闭").font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { query = state.word }
        .onChange(of: state.word) { query = $0 }
    }
}

@MainActor struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var diagnostics: SelectionDiagnostics
    let onRequestAccessibility: () -> Void
    let onOpenSearch: () -> Void
    @State private var hasAccessibility = AXIsProcessTrusted()
    @State private var credentialMessage = ""
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WordSlide 设置").font(.title2.weight(.semibold))
                    Text("菜单栏常驻，选中英文单词后显示词典释义。")
                        .foregroundStyle(.secondary)
                    Button("打开查词窗口", action: onOpenSearch)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(hasAccessibility ? "辅助功能：已授权" : "辅助功能：尚未授权",
                              systemImage: hasAccessibility ? "checkmark.circle" : "hand.raised")
                            .font(.headline)
                        Text("读取其他 App 的选区需要辅助功能权限。在系统设置中允许 WordSlide 后，返回这里即可。")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("打开辅助功能设置", action: onRequestAccessibility)
                            Button("重新检查") { refreshStatus() }
                        }
                        Text("划词状态：\(diagnostics.status)")
                            .font(.callout).textSelection(.enabled)
                        if !hasAccessibility {
                            Text("若系统开关已打开但这里仍未授权，可能是旧构建的授权记录。请移除旧 WordSlide 记录，再添加下面这个 App，并退出重开。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("当前 App：\(Bundle.main.bundleURL.path)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                }
                GroupBox("运行方式") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("鼠标选中单词后自动查询", isOn: $settings.automaticLookup)
                        Toggle("自动查询时需要按住 Option", isOn: $settings.optionOnly)
                            .disabled(!settings.automaticLookup)
                        Text("全局快捷键：Control + Option + D（⌃⌥D）。先在原 App 中选中单词，再按快捷键。")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("快捷键取词失败时，尝试模拟 ⌘C", isOn: $settings.clipboardFallback)
                        Text("仅在你按快捷键时尝试复制，并尽力恢复原剪贴板；部分 App 仍可能不支持。此操作不会用于自动查词。")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle("登录 Mac 时启动", isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        ))
                        Text(settings.loginStatusText).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                }
                GroupBox("词典来源") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("查询来源", selection: $settings.provider) {
                            ForEach(DictionaryProvider.allCases) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }
                        switch settings.provider {
                        case .system: localDictionarySettings
                        case .oxford: oxfordSettings
                        case .collins: collinsSettings
                        }
                        if settings.provider != .system {
                            Divider()
                            HStack {
                                Button("保存 API 凭据") {
                                    credentialMessage = settings.saveCredentials() ? "已保存到本机钥匙串。" : ""
                                }
                                Text(credentialMessage).font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = settings.credentialsError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            Text("输入后立即用于本次运行；保存后下次启动仍可用。留空并保存会删除当前来源的相应凭据。查询时仅将单词发送给选中的词典服务。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                }
                GroupBox("排除的 App") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在这些 App 中不读取选区。每行填写一个 Bundle ID，例如 com.apple.Terminal。")
                            .font(.callout).foregroundStyle(.secondary)
                        TextEditor(text: $settings.excludedBundleIDs)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 62)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                }
                Text("支持提供可访问选区的 App。图片、扫描 PDF、受保护内容和部分自绘界面无法自动取词，可在菜单栏中手动输入。WordSlide 不保存查词历史；网络词典可能记录请求，请参阅服务商政策。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(refresh) { _ in refreshStatus() }
        .onAppear { refreshStatus() }
        .onChange(of: settings.provider) { _ in credentialMessage = "" }
        .onChange(of: settings.oxfordAppID) { _ in credentialMessage = "" }
        .onChange(of: settings.oxfordAppKey) { _ in credentialMessage = "" }
        .onChange(of: settings.collinsKey) { _ in credentialMessage = "" }
    }

    private var localDictionarySettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("无需 API Key，可离线使用已安装的 macOS 词典。系统接口返回首个匹配条目的可用释义，来源和中文内容由本机启用的词典决定。")
                .font(.callout).foregroundStyle(.secondary)
            Text("需要中文时，在「词典」App → 设置中下载并启用英汉词典，并将其拖到列表前面。首次下载需要网络。")
                .font(.callout).foregroundStyle(.secondary)
            Button("打开 macOS 词典") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Dictionary.app"))
            }
        }
    }

    private var oxfordSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("App ID", text: $settings.oxfordAppID)
                .textFieldStyle(.roundedBorder)
            SecureField("App Key", text: $settings.oxfordAppKey)
                .textFieldStyle(.roundedBorder)
            Picker("英语版本", selection: $settings.oxfordLanguage) {
                Text("英式英语 en-gb").tag("en-gb")
                Text("美式英语 en-us").tag("en-us")
            }
            Toggle("同时请求英汉翻译", isOn: $settings.oxfordChinese)
            Text("英文释义使用 Words 接口；英汉翻译另发请求，需要账号具有 en → zh Translations 访问权限。计费和配额由 Oxford 决定。")
                .font(.caption).foregroundStyle(.secondary)
            Link("申请 Oxford API 凭据", destination: URL(string: "https://developer.oxforddictionaries.com/")!)
        }
    }

    private var collinsSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField("API Key", text: $settings.collinsKey)
                .textFieldStyle(.roundedBorder)
            TextField("已授权的 Dictionary Code", text: $settings.collinsDictionary)
                .textFieldStyle(.roundedBorder)
            Text("请填写 Collins 为你的账号授权的词典代码；是否包含中文取决于所选词典及授权。此处的默认代码需要账号支持，App 不附带商业词典授权。")
                .font(.caption).foregroundStyle(.secondary)
            Link("申请 Collins API Key / 查看授权", destination: URL(string: "https://www.collinsdictionary.com/collins-api")!)
        }
    }

    private func refreshStatus() {
        hasAccessibility = AXIsProcessTrusted()
        settings.refreshLoginStatus()
    }
}
