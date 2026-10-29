# WordSlide

**为 Apple Silicon Mac 编写的轻量划词词典。**

在网页或文档里选中一个英文单词，WordSlide 会在鼠标附近显示释义浮窗。App 常驻菜单栏，不占用 Dock，也不需要为每个浏览器安装扩展。

基于 **Swift、AppKit 和 SwiftUI**，不依赖第三方 Swift 包。当前版本为 **0.2.0**。

## 功能

- **跨 App 取词**：通过 macOS 辅助功能读取选区，支持拖选、双击和 Shift + 鼠标选择。
- **轻量浮窗**：显示可用的词性、音标、释义、例句、嵌套义项和翻译；长词条可滚动阅读。
- **三种词典来源**：macOS 本地词典、Oxford Dictionaries API、Collins Dictionary API。
- **Chrome / Electron 兼容**：请求启用网页辅助功能树，支持网页 text-marker 选区。
- **按需触发**：可设置按住 Option 才自动查询，或使用 `Control + Option + D` 查询当前选区。
- **手动查词与兼容复制**：菜单栏可输入单词；主动开启兼容选项后，快捷键可通过模拟 `⌘C` 获取选区。
- **运行控制**：支持排除指定 App、登录启动，以及查看最近的取词状态。

> “跨 App”取决于源软件是否提供可访问或可复制的选区。图片、扫描 PDF、受保护文本和部分自绘界面不支持自动取词；本项目不包含 OCR。

## 运行要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 13 或更高版本 |
| 硬件 | Apple Silicon；构建脚本生成 arm64 App |
| 开发工具 | Swift 5.8+，Command Line Tools 或 Xcode |
| 系统权限 | 自动取词需要授予 WordSlide 辅助功能权限 |
| 网络 | 已下载的本地词典可离线查询；Oxford / Collins 需要网络与自己的 API 凭据 |

## 从源码构建

在项目根目录执行：

```sh
# 确认开发工具可用
swift --version
xcrun --sdk macosx --show-sdk-path

# 运行离线测试
./scripts/test.sh
./scripts/test-selection.sh
./scripts/test-accessibility-selection.sh

# 构建并打包；如已有旧版正在运行，请先从菜单栏退出
./scripts/build.sh
```

若尚未安装 Command Line Tools，可执行 `xcode-select --install`，按系统提示完成安装。

构建脚本直接调用 `swiftc`，随后组装 App Bundle、进行本机 ad-hoc 签名，并生成以下文件：

```text
项目的上级目录/
├── WordSlide.app
└── WordSlide-macOS-arm64.zip
```

默认构建缓存位于项目内的 `.build/`。需要指定缓存位置时：

```sh
WORDSLIDE_BUILD_DIR=/private/tmp/wordslide-build-cache ./scripts/build.sh
```

这些构建仅进行本机 ad-hoc 签名，**没有 Developer ID 签名或 Apple 公证**。面向其他 Mac 分发前，应使用自己的 Developer ID 完成签名与公证。

## 安装与使用

1. 将构建出的 `WordSlide.app` 放入“应用程序”或其他固定位置，再启动。
2. 点击菜单栏词典图标，进入“设置”。打开 macOS **系统设置 → 隐私与安全性 → 辅助功能**，允许 WordSlide。
3. 返回 WordSlide，确认状态显示 **“辅助功能：已授权”**，并开启“鼠标选中单词后自动查询”。
4. 在其他 App 中拖选或双击一个英文单词，即可查看释义。

| 操作 | 方法 |
| --- | --- |
| 自动查询 | 拖选、双击或使用 Shift + 鼠标选择一个英文词 |
| 仅在需要时自动查询 | 在设置中启用“自动查询时需要按住 Option” |
| 查询当前选区 | `Control + Option + D`，或菜单栏“查询当前选区” |
| 输入单词 | 菜单栏“输入单词”，或设置中的“打开查词窗口” |
| 关闭浮窗 | 点击外部或关闭按钮；浮窗获得键盘焦点时可按 `Escape` |
| 停止后台运行 | 菜单栏 → 退出 WordSlide |

只查询**单个英文词**，支持 `can't`、`well-being` 等形式。整句、中文和含数字的字符串不会自动发送到词典服务。开始新的鼠标选词操作或关闭浮窗时，旧查询会被取消。

## 词典配置

### macOS 本地词典：默认，无需 Key

WordSlide 使用 Apple Dictionary Services，返回系统启用词典中的**第一个匹配词条**。它不会把所有本地词典的内容合并。

需要优先显示中文时：

1. 打开 macOS“词典”App → 设置。
2. 下载并启用英汉词典。
3. 将英汉词典拖到单语英语词典之前。

首次下载需要联网；下载后可离线查询。系统接口返回纯文本，部分附加内容可能不会提供。

### Oxford Dictionaries API

在 WordSlide 设置中选择 Oxford，填写自己的 **App ID** 和 **App Key**，点击“保存 API 凭据”。

- 可选择英式 `en-gb` 或美式 `en-us`。
- 英文释义使用 Words 端点，支持有效词形变化。
- 开启“同时请求英汉翻译”后，额外查询 `en → zh` Translations。
- **英汉翻译需要单独的词库权限**。中文请求失败时，仍展示已取得的英文释义，并说明原因。

凭据、产品权限、配额和计费以 [Oxford 官方平台](https://developer.oxforddictionaries.com/)为准。

### Collins Dictionary API

选择 Collins，填写自己的 **API Key** 和已获授权的 **Dictionary Code**，然后保存。

- 默认代码为 `english`；中文释义需要账号拥有相应双语词库，并填写 Collins 提供的代码。
- 先搜索精确词头，再获取对应词条；不会把相近短语当作所选单词返回。
- 最多搜索 5 页。若仍有其他结果，浮窗会明确提示可能不完整。
- HTML 正文转换为纯文本展示，不使用网页渲染器，也不执行脚本。

词形变化若未在所选词库中收录，可尝试手动输入原形。通过 [Collins 官方页面](https://www.collinsdictionary.com/collins-api)申请访问权限。

API 凭据输入后可用于本次运行；点击保存才会写入 macOS 钥匙串。项目不附带词典 Key 或商业词库授权。

## 常见问题

### 划词后没有反应

先看 WordSlide 设置中的**辅助功能状态**和**划词状态**：

- 未授权：在系统设置中允许 WordSlide。
- 自动划词关闭：重新开启，或按 `Control + Option + D`。
- 要求 Option：按住 Option 划词，或关闭这一限制。
- App 已被排除：检查排除列表中的 Bundle ID。
- 检测到手势但未读到文字：尝试快捷键复制取词，或手动输入。

### 系统开关已打开，App 仍显示未授权

移动 App、重新编译或运行另一份同名 App 后，旧授权记录可能不适用于当前构建。

核对 WordSlide 设置里显示的**“当前 App”路径**。在系统辅助功能列表中移除旧 WordSlide 条目，点击“+”添加当前运行的 App，开启开关，再退出重开。以 WordSlide 自己显示“已授权”为准。建议先确定最终安装位置，再授予权限。

### Chrome 首次取词较慢

Chromium 会按需生成网页辅助功能树。WordSlide 首次为相关进程启用取词时，会等待约 2.3 秒再读取选区。初始化完成后，后续查询不再重复等待这段启动时间。

兼容路径也覆盖已识别的 Chromium 浏览器和包含 Electron Framework 的 App，但具体网页、PDF 或编辑器仍可能有不同的选区实现。

### 某个 App 无法直接读取选区

开启“快捷键取词失败时，尝试模拟 ⌘C”，在源 App 中选词后按 `Control + Option + D`。

兼容复制仅用于**手动触发**，自动划词不会操作剪贴板。若内容不可复制，或剪贴板无法完整保存，本次操作会跳过。图片和扫描 PDF 需要先进行文字识别。

## 数据与隐私

- 本地词典模式不发送网络查询。
- 在线模式只向所选词典服务发送单词，不上传截图或完整文档。
- 不保存查词历史、不写入选词日志，不接入分析服务。设置中的取词状态不包含单词内容。
- API 凭据保存在 Keychain；普通偏好设置保存在 UserDefaults。
- 网络会话使用临时配置，不使用磁盘响应缓存或 Cookie 存储。
- 兼容复制会尽力恢复原剪贴板；检测到后续变化时不会覆盖新内容。第三方剪贴板历史工具仍可能记录复制内容。
- 不申请录屏权限；登录启动默认关闭。

## 项目结构

```text
WordSlide/
├── Package.swift                         # Swift Package 描述
├── Info.plist                            # App 标识、版本、最低系统版本
├── Sources/WordSlide/
│   ├── WordSlideApp.swift                # 菜单栏、生命周期、浮窗与快捷键
│   ├── SelectionMonitor.swift            # 选词事件、AX 查询与兼容复制
│   ├── SelectionGesture.swift            # 基于原始事件坐标的手势判断
│   ├── AccessibilityCompatibility.swift # Chromium / Electron 辅助功能初始化
│   ├── AccessibilitySelectedText.swift  # 普通文本、text marker 与 CFRange 提取
│   ├── DictionaryService.swift           # 本地、Oxford、Collins 查询与解析
│   ├── AppSettings.swift                 # 偏好设置、Keychain 与登录启动
│   ├── Models.swift                      # 查询模型与运行状态
│   └── Views.swift                       # 释义浮窗与设置界面
├── Tests/WordSlideTests/                 # XCTest 测试源码
├── scripts/                              # 构建、打包与独立回归测试
└── TESTING.md                            # 验证范围与实际结果
```

取词流程为：**选词手势 → 权限与来源检查 → 读取选区 → 校验英文词 → 查询所选词典 → 展示浮窗**。跨进程 AX 查询在后台队列执行；自动模式不定时扫描屏幕或轮询文档正文。

## 测试与验证范围

独立测试可在仅安装 Command Line Tools 的环境运行，无需 XCTest 运行时：

| 命令 | 覆盖范围 | 最近通过结果 |
| --- | --- | --- |
| `./scripts/test.sh` | 词典请求、解析、嵌套义项与错误处理 | 13 场景 / 61 断言 |
| `./scripts/test-selection.sh` | 拖选、双击、Shift、坐标与状态复位 | 9 场景 / 18 断言 |
| `./scripts/test-accessibility-selection.sh` | 网页 text marker、CFRange、类型与长度边界 | 15 场景 / 46 断言 |

合计 **37 个离线场景、125 条断言**。安装完整 Xcode 后，可另行运行 XCTest 套件：

```sh
./scripts/test.sh --xctest
```

本机已验证 App 启动、手动本地英汉查询和辅助功能授权生效；用户在重新授权后反馈 Chrome 划词恢复。离线测试使用合成数据，未验证真实 Oxford / Collins 账户的授权、配额或计费，也不能保证所有第三方 App 的兼容性。详细记录见 [TESTING.md](TESTING.md)。

## 参考资料

- [Apple Dictionary Services](https://developer.apple.com/documentation/coreservices/dictionary_services)
- [Apple Accessibility API](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)
- [Oxford API 端点](https://developer.oxforddictionaries.com/endpoints)
- [Collins REST API 文档](https://api.collinsdictionary.com/api/v1/documentation/html)
- [Electron 辅助功能](https://www.electronjs.org/docs/latest/tutorial/accessibility)

词典数据的版权、使用范围与费用由各提供方决定；本项目不包含可再分发的商业词库。
