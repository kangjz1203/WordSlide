# 验证记录

记录日期：2026-10-29。版本：0.2.0。

本机环境：Apple Silicon arm64、macOS 15.7.4、Swift 5.8.1、macOS SDK 13.3。

## 离线回归测试

| 命令 | 场景数 | 断言数 | 结果 |
| --- | ---: | ---: | --- |
| `./scripts/test.sh` | 13 | 61 | 通过 |
| `./scripts/test-selection.sh` | 9 | 18 | 通过 |
| `./scripts/test-accessibility-selection.sh` | 15 | 46 | 通过 |
| **合计** | **37** | **125** | **0 失败** |

词典测试覆盖多词性、深层义项、120 条义项不截断、英汉合并、请求路径与认证头，以及中文无权限、HTTP 错误、超时、无效 JSON、取消和缺少密钥。Collins 相关测试覆盖多页精确同形词、搜索上限提示、相近短语过滤和 HTML 文本化。

手势测试覆盖原始事件坐标、3 点阈值、双击、Shift、孤立松开事件、重复手势与状态复位。辅助功能提取测试覆盖网页 text-marker 选区、普通 CFRange、提取优先级、畸形属性和长度边界。

这些是独立的断言测试，使用合成属性和 URLProtocol fixture，不读取真实应用选区、不访问付费词典。当前 Command Line Tools 环境未运行 XCTest；完整 Xcode 环境可另行执行 `./scripts/test.sh --xctest`。

## 构建与界面

- 全量源代码已编译为 arm64 App，无第三方 Swift 包依赖。
- 打包后的 Info.plist 与 ad-hoc 代码签名已检查。
- App 已在本机启动，设置窗口和 410 × 520 释义浮窗已做视觉检查。
- 手动查询 `serendipity`，本地词典实际返回英汉释义和英美音标。
- 已验证 Escape 关闭释义浮窗。

## Chrome 与辅助功能授权

0.2 补充 Chromium / Electron 的辅助功能初始化、网页 text-marker 读取，并修复异步鼠标事件坐标与同来源激活通知的处理。

最初系统辅助功能开关已打开，但运行构建仍返回未授权。用户移除旧记录、重新添加当前构建后，已实际读取到 **“辅助功能：已授权”**。随后用户反馈 **Chrome 划词可以使用**。

这属于本机权限确认与用户反馈；未完成一套独立、全自动的 Chrome 双击和拖选端到端测试，也不代表所有浏览器、网页、PDF 或第三方 App 均已验证。

## 尚未验证

- 真实 Oxford / Collins 账户的词库权限、在线响应、配额和计费。
- 兼容复制及剪贴板恢复在各类第三方 App 中的完整交互。
- 登录启动在不同安装位置及系统版本下的行为。
- Intel Mac 支持、Developer ID 签名与 Apple 公证。

## 实现依据

- [Chromium 应用级辅助功能](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/chrome_browser_application_mac.mm)
- [Chromium 网页选区实现](https://raw.githubusercontent.com/chromium/chromium/main/ui/accessibility/platform/browser_accessibility_cocoa.mm)
- [Electron 辅助功能](https://www.electronjs.org/docs/latest/tutorial/accessibility)
