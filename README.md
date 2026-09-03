# Project Switcher

独立 macOS 小工具：全局热键唤起类似聚焦搜索的浮层，列出已经打开的 Cursor 项目窗口并切过去。

与 [Project Manager](https://github.com/anthonyzhao-4926/project_manager)（编辑器扩展）分工不同：扩展负责扫盘、标签和打开新窗口；本工具负责在桌面任意位置切换**已经打开**的窗口。

## 功能

- 全局热键 `⌥S`（Option + S）唤起屏幕中央浮层
- 列出 Cursor 当前已打开的项目（读 windowsState），可即时过滤
- 回车或点击后切到该项目对应窗口，不重复打开
- 菜单栏常驻；可选择登录时启动
- 排除 DevTools 等无关窗口

## 要求

- macOS 13+
- 首次使用必须在 **系统设置 → 隐私与安全性 → 辅助功能** 中勾选 **Project Switcher**（路径应是 `/Applications/Project Switcher.app`）
- 列出其它桌面窗口时，系统可能再弹一次 **自动化** 授权：允许 Project Switcher 控制 **System Events**

未授权时会提示没有权限。请只安装 `/Applications` 这一份；每次 `make dmg` / 重装后 ad-hoc 签名会变，需要重新勾选辅助功能，并完全退出再打开。

## 安装

拖拽安装（推荐）：

```bash
cd project_switcher
make dmg
open dist/Project-Switcher-*.dmg
```

打开 DMG 后，把 **Project Switcher** 拖到 **Applications**，再从「应用程序」启动。

也可直接拷贝到 `/Applications`：

```bash
make install
open "/Applications/Project Switcher.app"
```

然后打开系统设置授权辅助功能，再按 `⌥S`。未授权时窗口列表为空；装到 `/Applications` 后再授权，系统才能记住权限。

仅编译 App：

```bash
make app
```

产物在 `dist/Project Switcher.app`；`make dmg` 还会生成 `dist/Project-Switcher-<version>.dmg`。

本仓库用 `swiftc` + Makefile 构建（不依赖 SwiftPM）。若本机 Command Line Tools 出现 `SwiftBridging` 模块重定义，Makefile 会自动加一层 vfs overlay。

## 使用

1. 在任意 App（Finder、浏览器、飞书等）按下 `⌥S`
2. 输入项目名 / 路径过滤
3. 方向键选择，回车切到对应项目窗口；Esc 关闭

菜单栏图标也可手动打开浮层、跳转辅助功能设置、配置登录启动。

## 窗口标题解析

Cursor 标题大致为：

- `文件名 — 项目名 — Cursor`
- `项目名 — Cursor`

同一项目的多扇窗口默认合并为一条，并聚焦最近使用的那一扇。

## 非目标

以下能力未包含，可后续加：

- 搜索尚未打开的项目并 `cursor <path>` 新开窗口
- 展示 Project Manager 的标签、置顶、隐藏、打开次数
- Windows / Linux
