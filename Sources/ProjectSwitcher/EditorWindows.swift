import AppKit
import ApplicationServices
import CoreGraphics

struct OpenEditorWindow: Identifiable {
    let id: String
    let pid: pid_t
    let kind: EditorKind
    let title: String
    let projectName: String
    /// 可能为 nil：仅靠标题 + pid 通过 AppleScript 聚焦
    let axWindow: AXUIElement?
}

enum AccessibilityAuth {
    static func isTrusted(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for urlString in urls {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}

enum CursorAppMatcher {
    /// 只认正式 Cursor.app，不要 Helper / XPC（否则会扫到几十个进程）
    static func isCursor(_ app: NSRunningApplication) -> Bool {
        let path = app.bundleURL?.path ?? ""
        guard path.hasSuffix("/Cursor.app"), !path.contains("Helper"), !path.contains(".xpc") else {
            return false
        }
        return app.bundleIdentifier == "com.todesktop.230313mzl4w4u92"
            || app.bundleIdentifier == "com.cursor.Cursor"
            || app.localizedName == "Cursor"
    }

    static func isCursor(ownerName: String) -> Bool {
        ownerName == "Cursor"
    }

    static let processName = "Cursor"
}

enum WindowEnumerator {
    static func listOpenEditorWindows() -> [OpenEditorWindow] {
        let runningCursor = NSWorkspace.shared.runningApplications.filter(CursorAppMatcher.isCursor)
        guard !runningCursor.isEmpty else {
            return []
        }

        // Electron 的 AX Windows 常只返回当前桌面这一扇；用 System Events + CG 补全其它 Space / 最小化窗
        var byKey = [String: Candidate]()

        for app in runningCursor {
            let pid = app.processIdentifier
            let processName = app.localizedName ?? CursorAppMatcher.processName

            for title in appleScriptWindowTitles(processName: processName) {
                merge(
                    into: &byKey,
                    Candidate(pid: pid, title: title, axWindow: nil, zOrder: Int.max)
                )
            }

            for pair in axWindowTitles(pid: pid) {
                merge(
                    into: &byKey,
                    Candidate(pid: pid, title: pair.title, axWindow: pair.element, zOrder: Int.max)
                )
            }
        }

        for cg in cgCursorWindows() {
            merge(
                into: &byKey,
                Candidate(pid: cg.pid, title: cg.title, axWindow: nil, zOrder: cg.zOrder)
            )
        }

        for app in runningCursor {
            let pid = app.processIdentifier
            let axPairs = axWindowTitles(pid: pid)
            for (key, candidate) in byKey where candidate.pid == pid && candidate.axWindow == nil {
                if let match = axPairs.first(where: { $0.title == candidate.title }) {
                    byKey[key] = candidate.withAX(match.element)
                }
            }
        }

        var collected = Array(byKey.values)
        collected.sort { left, right in
            if left.zOrder != right.zOrder {
                return left.zOrder < right.zOrder
            }
            return left.projectName.localizedCaseInsensitiveCompare(right.projectName) == .orderedAscending
        }

        // 同一项目多窗：保留最近使用的一扇；不同项目全部列出
        var seenProjects = Set<DedupedWindowKey>()
        var unique: [OpenEditorWindow] = []
        unique.reserveCapacity(collected.count)
        for candidate in collected {
            guard !TitleParser.shouldIgnore(title: candidate.title) else {
                continue
            }
            let projectKey = DedupedWindowKey(projectName: candidate.projectName)
            if seenProjects.contains(projectKey) {
                continue
            }
            seenProjects.insert(projectKey)
            unique.append(candidate.asWindow())
        }
        return unique
    }

    private struct Candidate {
        let pid: pid_t
        let title: String
        let axWindow: AXUIElement?
        let zOrder: Int

        var projectName: String { TitleParser.projectName(from: title) }
        var key: String { "\(pid)|\(title)" }

        func withAX(_ element: AXUIElement) -> Candidate {
            Candidate(pid: pid, title: title, axWindow: element, zOrder: zOrder)
        }

        func withPreferredZOrder(_ otherZ: Int) -> Candidate {
            Candidate(pid: pid, title: title, axWindow: axWindow, zOrder: min(zOrder, otherZ))
        }

        func asWindow() -> OpenEditorWindow {
            OpenEditorWindow(
                id: key,
                pid: pid,
                kind: .cursor,
                title: title,
                projectName: projectName,
                axWindow: axWindow
            )
        }
    }

    private static func merge(into map: inout [String: Candidate], _ incoming: Candidate) {
        let trimmed = incoming.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        if let existing = map[incoming.key] {
            var merged = existing.withPreferredZOrder(incoming.zOrder)
            if merged.axWindow == nil, let ax = incoming.axWindow {
                merged = merged.withAX(ax)
            }
            map[incoming.key] = merged
        } else {
            map[incoming.key] = incoming
        }
    }

    private static func appleScriptWindowTitles(processName: String) -> [String] {
        let escaped = processName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "System Events"
          if not (exists process "\(escaped)") then return ""
          tell process "\(escaped)"
            try
              set windowNames to name of every window
              set AppleScript's text item delimiters to linefeed
              return windowNames as text
            on error
              return ""
            end try
          end tell
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return []
        }
        let result = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil {
            return []
        }
        let text = result.stringValue ?? ""
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func axWindowTitles(pid: pid_t) -> [(title: String, element: AXUIElement)] {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        let copyWindowsStatus = AXUIElementCopyAttributeValue(
            axApp,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard copyWindowsStatus == .success, let axWindows = windowsValue as? [AXUIElement] else {
            return []
        }

        return axWindows.compactMap { axWindow in
            guard isStandardWindow(axWindow) else {
                return nil
            }
            let title = axString(axWindow, kAXTitleAttribute as CFString) ?? ""
            guard !title.isEmpty else {
                return nil
            }
            return (title, axWindow)
        }
    }

    /// 含空标题窗口，并带上 AXDocument，供按项目路径关窗
    fileprivate static func listAXWindows(pid: pid_t) -> [(title: String, document: String?, element: AXUIElement)] {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        let copyWindowsStatus = AXUIElementCopyAttributeValue(
            axApp,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard copyWindowsStatus == .success, let axWindows = windowsValue as? [AXUIElement] else {
            return []
        }
        return axWindows.compactMap { axWindow in
            guard isStandardWindow(axWindow) else {
                return nil
            }
            let title = axString(axWindow, kAXTitleAttribute as CFString) ?? ""
            let document = axString(axWindow, kAXDocumentAttribute as CFString)
            return (title, document, axWindow)
        }
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        guard axString(window, kAXRoleAttribute as CFString) == (kAXWindowRole as String) else {
            return false
        }
        if let subrole = axString(window, kAXSubroleAttribute as CFString) {
            if subrole == "AXFloatingWindow" || subrole == "AXSystemFloatingWindow" {
                return false
            }
        }
        return true
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: AnyObject?
        let copyStatus = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard copyStatus == .success else {
            return nil
        }
        return value as? String
    }

    fileprivate struct CGCursorWindow {
        let pid: pid_t
        let title: String
        let zOrder: Int
        let bounds: CGRect
        let isOnscreen: Bool
        let windowID: CGWindowID
    }

    /// 含其它桌面 / 最小化窗口（不要用 optionOnScreenOnly）
    fileprivate static func cgCursorWindows(requireTitle: Bool = true) -> [CGCursorWindow] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result: [CGCursorWindow] = []
        for (index, row) in info.enumerated() {
            let ownerName = row[kCGWindowOwnerName as String] as? String ?? ""
            guard CursorAppMatcher.isCursor(ownerName: ownerName) else {
                continue
            }
            let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? (row[kCGWindowLayer as String] as? Int)
                ?? -1
            guard layer == 0 else {
                continue
            }
            let title = row[kCGWindowName as String] as? String ?? ""
            if requireTitle, title.isEmpty {
                continue
            }
            guard let pid = cgPid(from: row) else {
                continue
            }
            result.append(
                CGCursorWindow(
                    pid: pid,
                    title: title,
                    zOrder: index,
                    bounds: cgBounds(from: row),
                    isOnscreen: (row["kCGWindowIsOnscreen"] as? NSNumber)?.boolValue
                        ?? (row[kCGWindowIsOnscreen as String] as? Bool)
                        ?? false,
                    windowID: cgWindowID(from: row)
                )
            )
        }
        return result
    }

    fileprivate static func cgBounds(from row: [String: Any]) -> CGRect {
        guard let bounds = row[kCGWindowBounds as String] as? [String: Any] else {
            return .zero
        }
        let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
        let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
        let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
        let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
        return CGRect(x: x, y: y, width: w, height: h)
    }

    fileprivate static func cgWindowID(from row: [String: Any]) -> CGWindowID {
        if let asNumber = row[kCGWindowNumber as String] as? NSNumber {
            return CGWindowID(truncatingIfNeeded: asNumber.uint32Value)
        }
        if let asInt = row[kCGWindowNumber as String] as? Int {
            return CGWindowID(asInt)
        }
        return 0
    }

    private static func cgPid(from row: [String: Any]) -> pid_t? {
        if let asPid = row[kCGWindowOwnerPID as String] as? pid_t {
            return asPid
        }
        if let asInt = row[kCGWindowOwnerPID as String] as? Int {
            return pid_t(asInt)
        }
        if let asNumber = row[kCGWindowOwnerPID as String] as? NSNumber {
            return pid_t(truncatingIfNeeded: asNumber.intValue)
        }
        return nil
    }
}

enum WindowFocuser {
    static func focus(_ window: OpenEditorWindow) {
        if let runningApp = NSRunningApplication(processIdentifier: window.pid) {
            runningApp.activate(options: [.activateIgnoringOtherApps])
        }

        if let axWindow = window.axWindow {
            AXUIElementSetAttributeValue(
                axWindow,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            let axApp = AXUIElementCreateApplication(window.pid)
            AXUIElementSetAttributeValue(
                axApp,
                kAXFocusedWindowAttribute as CFString,
                axWindow
            )
            return
        }

        raiseViaAppleScript(window)
    }

    private static func raiseViaAppleScript(_ window: OpenEditorWindow) {
        let escapedTitle = window.title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let processName = CursorAppMatcher.processName
        let source = """
        tell application "System Events"
          if not (exists process "\(processName)") then return
          set frontmost of process "\(processName)" to true
          tell process "\(processName)"
            try
              set targetWindow to first window whose name is "\(escapedTitle)"
              perform action "AXRaise" of targetWindow
              set value of attribute "AXMinimized" of targetWindow to false
            end try
          end tell
        end tell
        """
        var errorInfo: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&errorInfo)
        }
    }
}

/// 打开 / 切到 Cursor 窗口时使用的布局。默认 Editor，避免进 Agent / Glass。
enum CursorWindowLayout: String, CaseIterable {
    case editor
    case agent

    private static let defaultsKey = "projectSwitcher.windowLayout"

    static var current: CursorWindowLayout {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let layout = CursorWindowLayout(rawValue: raw) {
                return layout
            }
            return .editor
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            UserDefaults.standard.synchronize()
        }
    }

    var menuTitle: String {
        switch self {
        case .editor: return "Editor（经典窗口）"
        case .agent: return "Agent"
        }
    }

    /// `cursor --classic` / `cursor --glass`
    var cliFlag: String {
        switch self {
        case .editor: return "--classic"
        case .agent: return "--glass"
        }
    }
}

extension WindowFocuser {
    /// 切到已打开项目：只用正式 Cursor.app / CLI，避免误开 CursorUIViewService.xpc
    static func focusProject(_ project: OpenProject) {
        let layout = CursorWindowLayout.current
        if focusViaCursorCLI(project.path, layout: layout) {
            return
        }
        _ = focusViaOpenCursorApp(project.path, layout: layout)
    }

    /// `open -na Cursor --args --classic <path>`，不要裸 `open -a`（会跟上次活动窗进 Agent）
    @discardableResult
    private static func focusViaOpenCursorApp(_ path: String, layout: CursorWindowLayout) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let appURL = mainCursorAppURL() {
            process.arguments = ["-na", appURL.path, "--args", layout.cliFlag, path]
        } else {
            process.arguments = ["-na", "Cursor", "--args", layout.cliFlag, path]
        }
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private static func focusViaCursorCLI(_ path: String, layout: CursorWindowLayout) -> Bool {
        guard let cli = cursorCLIPath() else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        // 不带 -r：复用最近窗口时可能落到 Agent
        process.arguments = [layout.cliFlag, path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func cursorCLIPath() -> String? {
        let candidates = [
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
            "\(NSHomeDirectory())/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            "\(NSHomeDirectory())/.local/bin/cursor",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 只接受真正的 Cursor.app，排除 Helper / .xpc
    private static func mainCursorAppURL() -> URL? {
        let knownIds = [
            "com.todesktop.230313mzl4w4u92",
            "com.cursor.Cursor",
        ]
        for bundleId in knownIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
               isMainCursorApp(url) {
                return url
            }
        }

        let candidates = [
            "/Applications/Cursor.app",
            "\(NSHomeDirectory())/Applications/Cursor.app",
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path), isMainCursorApp(url) {
                return url
            }
        }
        return nil
    }

    private static func isMainCursorApp(_ url: URL) -> Bool {
        let path = url.path
        guard path.hasSuffix("/Cursor.app") || path.hasSuffix("Cursor.app") else {
            return false
        }
        if path.contains(".xpc") || path.contains("Helper") || path.contains("CursorUIViewService") {
            return false
        }
        return true
    }

    static func dumpWindows(to path: String) {
        var lines: [String] = []
        lines.append("AX trusted: \(AccessibilityAuth.isTrusted(prompt: false))")
        lines.append("AXIsProcessTrusted: \(AXIsProcessTrusted())")

        let running = NSWorkspace.shared.runningApplications.filter(CursorAppMatcher.isCursor)
        lines.append("running Cursor apps: \(running.count)")
        for app in running {
            lines.append("  pid=\(app.processIdentifier) name=\(app.localizedName ?? "") bundle=\(app.bundleIdentifier ?? "") path=\(app.bundleURL?.path ?? "") main=\(isMainCursorProcess(app))")
            for item in WindowEnumerator.listAXWindows(pid: app.processIdentifier) {
                lines.append("    AX title=\(item.title.debugDescription) document=\(item.document ?? "nil")")
            }
        }

        lines.append("CG windows:")
        for cg in WindowEnumerator.cgCursorWindows(requireTitle: false) {
            lines.append("  id=\(cg.windowID) pid=\(cg.pid) onscreen=\(cg.isOnscreen) title=\(cg.title.debugDescription) bounds=\(cg.bounds)")
        }

        lines.append("storage projects:")
        for project in CursorOpenProjects.list() {
            let kind = project.isWorkspace ? "workspace" : "folder"
            lines.append("  [\(kind)] \(project.name) => \(project.path)")
        }
        lines.append("window titles:")
        for info in CursorWindowTitles.list() {
            let kind = info.isWorkspace ? "workspace" : "folder"
            lines.append("  [\(kind)] \(info.projectName) title=\(info.title.debugDescription)")
        }

        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        fputs(text, stderr)
    }

    /// 关掉该项目对应的 Cursor 窗口。成功才返回 true。绝不 open / -r / 切到该项目。
    @discardableResult
    static func closeProjectWindow(_ project: OpenProject) -> Bool {
        if project.isWorkspace || CursorWorkspace.isWorkspaceFile(project.path) {
            return closeWorkspaceWindow(project)
        }
        if CursorCloseBridge.requestClose(project) {
            return true
        }
        if clickOnscreenTrafficLight(of: project),
           waitUntilProjectWindowGone(project, hadVisibleMatch: true) {
            return true
        }
        return closeMatchedWindowsSilently(project)
    }

    /// 工作区窗口经常没有 workspaceFile，已打开的扩展也不会热加载。先短等扩展，再按标题关，最后才聚焦后发 ⌘⇧W。
    @discardableResult
    private static func closeWorkspaceWindow(_ project: OpenProject) -> Bool {
        if CursorCloseBridge.requestClose(project, timeout: 0.45) {
            return true
        }
        if clickOnscreenTrafficLight(of: project),
           waitUntilProjectWindowGone(project, hadVisibleMatch: true) {
            return true
        }
        if closeMatchedWindowsSilently(project) {
            return true
        }
        if clickCloseButtonsContainingNameViaAppleScript(project.name),
           waitUntilProjectWindowGone(project, hadVisibleMatch: true) {
            return true
        }
        if closeWorkspaceViaKeystroke(project) {
            return true
        }
        return false
    }

    /// 复用已打开的 Editor 窗口，再发「关闭窗口」。不走 Agent。
    @discardableResult
    private static func closeWorkspaceViaKeystroke(_ project: OpenProject) -> Bool {
        guard focusViaCursorCLI(project.path, layout: .editor)
            || focusViaOpenCursorApp(project.path, layout: .editor) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.45)
        postCloseWindowShortcut()
        return waitUntilProjectWindowGone(project, hadVisibleMatch: true)
    }

    private static func postCloseWindowShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyW: CGKeyCode = 13
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyW, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyW, keyDown: false) else {
            return
        }
        down.flags = [.maskCommand, .maskShift]
        up.flags = [.maskCommand, .maskShift]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// 点当前屏幕上该窗口左上角红灯，不先切成最近活动窗口。
    @discardableResult
    private static func clickOnscreenTrafficLight(of project: OpenProject) -> Bool {
        let matches = WindowEnumerator.cgCursorWindows(requireTitle: true).filter { window in
            window.isOnscreen && TitleParser.belongs(windowTitle: window.title, projectName: project.name)
        }
        NSLog("closeProjectWindow trafficLight matches=\(matches.count) project=\(project.name)")
        guard let target = matches.first else {
            return false
        }
        return clickClosePixel(of: target)
    }

    @discardableResult
    private static func clickClosePixel(of window: WindowEnumerator.CGCursorWindow) -> Bool {
        let quartz = window.bounds
        guard quartz.width > 40, quartz.height > 20 else {
            return false
        }
        let mainHeight = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        // kCGWindowBounds：主屏左上为原点、Y 向下；CGEvent：主屏左下为原点、Y 向上
        let click = CGPoint(
            x: quartz.minX + 12,
            y: mainHeight - quartz.minY - 14
        )
        NSLog("closeProjectWindow click close at \(click) title=\(window.title)")
        let source = CGEventSource(stateID: .hidSystemState)
        guard let mouseDown = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: click,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: click,
            mouseButton: .left
        ) else {
            return false
        }
        mouseDown.postToPid(window.pid)
        mouseUp.postToPid(window.pid)
        Thread.sleep(forTimeInterval: 0.05)
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    private static func closeMatchedWindowsSilently(_ project: OpenProject) -> Bool {
        let matched = windowsBelonging(to: project)
        NSLog("closeProjectWindow silently match=\(matched.count) project=\(project.name)")

        var attempted = false
        for target in matched {
            if pressCloseButton(of: target.element) {
                attempted = true
                continue
            }
            if !target.title.isEmpty, clickCloseButtonViaAppleScript(title: target.title) {
                attempted = true
            }
        }

        if !attempted {
            attempted = clickCloseButtonsMatchingProjectNameViaAppleScript(project.name)
        }

        guard attempted else {
            return false
        }
        return waitUntilProjectWindowGone(project, hadVisibleMatch: true)
    }

    private struct CloseTarget {
        let title: String
        let element: AXUIElement
    }

    private static func windowsBelonging(to project: OpenProject) -> [CloseTarget] {
        var targets: [CloseTarget] = []
        var seen = Set<String>()

        func append(title: String, element: AXUIElement) {
            let key = title.isEmpty ? "anon-\(targets.count)" : title
            guard !seen.contains(key) else { return }
            seen.insert(key)
            targets.append(CloseTarget(title: title, element: element))
        }

        for window in WindowEnumerator.listOpenEditorWindows() {
            guard TitleParser.belongs(windowTitle: window.title, projectName: project.name),
                  let axWindow = window.axWindow else {
                continue
            }
            append(title: window.title, element: axWindow)
        }

        let runningCursor = NSWorkspace.shared.runningApplications.filter { app in
            CursorAppMatcher.isCursor(app) && isMainCursorProcess(app)
        }
        for app in runningCursor {
            for item in WindowEnumerator.listAXWindows(pid: app.processIdentifier) {
                let titleBelongs = !item.title.isEmpty
                    && TitleParser.belongs(windowTitle: item.title, projectName: project.name)
                let documentBelongs = documentMatches(item.document, projectPath: project.path)
                if titleBelongs || documentBelongs {
                    append(title: item.title, element: item.element)
                }
            }
        }
        return targets
    }

    private static func isMainCursorProcess(_ app: NSRunningApplication) -> Bool {
        let path = app.bundleURL?.path ?? ""
        guard path.hasSuffix("/Cursor.app") || path.hasSuffix("Cursor.app") else {
            return false
        }
        return !path.contains(".xpc") && !path.contains("Helper")
    }

    private static func documentMatches(_ document: String?, projectPath: String) -> Bool {
        guard let document, !document.isEmpty else {
            return false
        }
        let path: String
        if document.hasPrefix("file://"), let url = URL(string: document) {
            path = LocalRecentProjects.normalize(url.path)
        } else {
            path = LocalRecentProjects.normalize(document)
        }
        let project = LocalRecentProjects.normalize(projectPath)
        return path == project || path.hasPrefix(project + "/")
    }

    /// 工作区以标题 / AX 为准；storage.json 的 openedWindows 会滞后。
    private static func waitUntilProjectWindowGone(_ project: OpenProject, hadVisibleMatch: Bool) -> Bool {
        Thread.sleep(forTimeInterval: 0.4)
        if !workspaceWindowStillVisible(project) {
            return true
        }
        if hadVisibleMatch, windowsBelonging(to: project).isEmpty {
            return true
        }
        Thread.sleep(forTimeInterval: 1.6)
        if !workspaceWindowStillVisible(project) {
            return true
        }
        let stillInStorage = storageHasProject(project)
        if stillInStorage {
            NSLog("closeProjectWindow: storage 里还有 \(project.path)")
        }
        return !stillInStorage
    }

    private static func workspaceWindowStillVisible(_ project: OpenProject) -> Bool {
        if project.isWorkspace || CursorWorkspace.isWorkspaceFile(project.path) {
            if CursorWindowTitles.list().contains(where: { info in
                info.isWorkspace && TitleParser.belongs(windowTitle: info.title, projectName: project.name)
            }) {
                return true
            }
            return !windowsBelonging(to: project).isEmpty
        }
        return CursorOpenProjects.isLive(project) || !windowsBelonging(to: project).isEmpty
    }

    private static func storageHasProject(_ project: OpenProject) -> Bool {
        CursorOpenProjects.isLive(project)
    }

    @discardableResult
    private static func pressCloseButton(of window: AXUIElement) -> Bool {
        var closeButtonValue: AnyObject?
        let copyClose = AXUIElementCopyAttributeValue(
            window,
            "AXCloseButton" as CFString,
            &closeButtonValue
        )
        if copyClose == .success, let closeButtonValue {
            let closeButton = closeButtonValue as! AXUIElement
            if AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
                return true
            }
        }
        if let found = findCloseButton(in: window, depth: 0) {
            return AXUIElementPerformAction(found, kAXPressAction as CFString) == .success
        }
        return false
    }

    private static func findCloseButton(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 5 {
            return nil
        }
        var subroleValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let subrole = subroleValue as? String,
           subrole == "AXCloseButton" {
            return element
        }

        var childrenValue: AnyObject?
        let copyChildren = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        guard copyChildren == .success, let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findCloseButton(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// Electron 上 AXPress 关闭钮经常空成功；System Events click 红灯更有效，且不 set frontmost。
    @discardableResult
    private static func clickCloseButtonViaAppleScript(title: String) -> Bool {
        let escapedTitle = escapeAppleScript(title)
        let processName = CursorAppMatcher.processName
        let source = """
        tell application "System Events"
          if not (exists process "\(processName)") then return false
          tell process "\(processName)"
            try
              set targetWindow to first window whose name is "\(escapedTitle)"
              click button 1 of targetWindow
              return true
            on error
              try
                perform action "AXPress" of (value of attribute "AXCloseButton" of targetWindow)
                return true
              on error
                return false
              end try
            end try
          end tell
        end tell
        """
        return runAppleScriptBoolean(source)
    }

    @discardableResult
    private static func clickCloseButtonsMatchingProjectNameViaAppleScript(_ projectName: String) -> Bool {
        let escapedName = escapeAppleScript(projectName)
        let processName = CursorAppMatcher.processName
        let source = """
        tell application "System Events"
          if not (exists process "\(processName)") then return false
          tell process "\(processName)"
            set closedAny to false
            repeat with w in every window
              set windowName to name of w
              if windowName contains " — \(escapedName)" or windowName contains " – \(escapedName)" or windowName contains " - \(escapedName)" or windowName is "\(escapedName)" or windowName is "\(escapedName) — Cursor" or windowName is "\(escapedName) - Cursor" or windowName contains "\(escapedName) (工作区)" or windowName contains "\(escapedName) (Workspace)" then
                try
                  click button 1 of w
                  set closedAny to true
                end try
              end if
            end repeat
            return closedAny
          end tell
        end tell
        """
        return runAppleScriptBoolean(source)
    }

    /// 工作区名足够独特，标题里出现即可关，兼容完整路径标题
    @discardableResult
    private static func clickCloseButtonsContainingNameViaAppleScript(_ projectName: String) -> Bool {
        let escapedName = escapeAppleScript(projectName)
        let processName = CursorAppMatcher.processName
        let source = """
        tell application "System Events"
          if not (exists process "\(processName)") then return false
          tell process "\(processName)"
            set closedAny to false
            repeat with w in every window
              set windowName to name of w
              if windowName contains "\(escapedName)" then
                try
                  click button 1 of w
                  set closedAny to true
                end try
              end if
            end repeat
            return closedAny
          end tell
        end tell
        """
        return runAppleScriptBoolean(source)
    }

    private static func escapeAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private static func runAppleScriptBoolean(_ source: String) -> Bool {
        var scriptErrorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return false
        }
        let result = script.executeAndReturnError(&scriptErrorInfo)
        if scriptErrorInfo != nil {
            return false
        }
        return result.booleanValue
    }
}
