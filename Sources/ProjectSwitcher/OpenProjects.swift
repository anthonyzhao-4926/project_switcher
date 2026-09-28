import AppKit
import CoreGraphics
import Foundation

struct OpenProject: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    /// 当前已打开的 Cursor 窗口；扫描到的未打开项目为 false
    let isOpen: Bool
    /// `.code-workspace` 多根工作区窗口
    let isWorkspace: Bool

    var searchText: String {
        isWorkspace ? "\(name) \(path) 工作区 workspace" : "\(name) \(path)"
    }

    init(id: String, name: String, path: String, isOpen: Bool = true, isWorkspace: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.isOpen = isOpen
        self.isWorkspace = isWorkspace
    }
}

enum CursorWorkspace {
    static func isWorkspaceFile(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".code-workspace")
    }

    static func displayName(fromPath path: String) -> String {
        let base = (path as NSString).lastPathComponent
        if base.lowercased().hasSuffix(".code-workspace") {
            return String(base.dropLast(".code-workspace".count))
        }
        return base
    }

    /// 解析 `.code-workspace` 里的文件夹，相对路径相对工作区文件所在目录
    static func memberFolders(at path: String, fileManager: FileManager = .default) -> [String] {
        guard isWorkspaceFile(path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = json["folders"] as? [[String: Any]] else {
            return []
        }
        let baseDir = (path as NSString).deletingLastPathComponent
        var result: [String] = []
        var seen = Set<String>()
        for folder in folders {
            guard let raw = folder["path"] as? String else {
                continue
            }
            let resolved: String
            if raw.hasPrefix("file://"), let url = URL(string: raw) {
                resolved = LocalRecentProjects.normalize(url.path)
            } else if raw.hasPrefix("/") {
                resolved = LocalRecentProjects.normalize(raw)
            } else {
                resolved = LocalRecentProjects.normalize(
                    (baseDir as NSString).appendingPathComponent(raw)
                )
            }
            guard !resolved.isEmpty, !seen.contains(resolved) else {
                continue
            }
            seen.insert(resolved)
            result.append(resolved)
        }
        return result
    }
}

/// 仅记录用户在本切换器里点开过的顺序
enum LocalRecentProjects {
    private static let defaultsKey = "projectSwitcher.localRecentPaths"
    private static let maxCount = 100

    static func touch(_ path: String) {
        let normalized = normalize(path)
        guard !normalized.isEmpty else { return }

        var paths = orderedPaths().filter { normalize($0) != normalized }
        paths.insert(normalized, at: 0)
        if paths.count > maxCount {
            paths = Array(paths.prefix(maxCount))
        }
        persist(paths)
    }

    static func orderedPaths() -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        func append(contentsOf source: [String]) {
            for path in source {
                let normalized = normalize(path)
                guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
                seen.insert(normalized)
                paths.append(normalized)
            }
        }

        append(contentsOf: readFile() ?? [])
        append(contentsOf: UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        return paths
    }

    static func remove(_ path: String) {
        let normalized = normalize(path)
        let paths = orderedPaths().filter { normalize($0) != normalized }
        persist(paths)
    }

    private static func persist(_ paths: [String]) {
        UserDefaults.standard.set(paths, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
        guard let url = fileURL() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONSerialization.data(withJSONObject: paths, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func readFile() -> [String]? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return nil
        }
        return paths
    }

    private static func fileURL() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ProjectSwitcher", isDirectory: true)
            .appendingPathComponent("local-recent-paths.json", isDirectory: false)
    }

    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

enum CursorCloseBridge {
    static func requestFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ProjectSwitcher", isDirectory: true)
            .appendingPathComponent("close-request.json", isDirectory: false)
    }

    /// 让已打开该项目的 Cursor 窗口自己执行 closeWindow，不聚焦、不依赖辅助功能。
    @discardableResult
    static func requestClose(_ project: OpenProject, timeout: TimeInterval = 1.6) -> Bool {
        ensureExtensionInstalled()
        let folder = requestFileURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let payload: [String: Any] = [
            "path": LocalRecentProjects.normalize(project.path),
            "name": project.name,
            "isWorkspace": project.isWorkspace || CursorWorkspace.isWorkspaceFile(project.path),
            "id": UUID().uuidString,
            "at": Date().timeIntervalSince1970,
            "done": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }
        do {
            try data.write(to: requestFileURL(), options: .atomic)
        } catch let writeRequestError {
            NSLog("close-request 写入失败: \(writeRequestError)")
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if requestClaimed(id: payload["id"] as? String) {
                waitUntilNotLive(project, timeout: 0.8)
                return true
            }
            if !CursorOpenProjects.isLive(project) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        if requestClaimed(id: payload["id"] as? String) {
            waitUntilNotLive(project, timeout: 0.5)
            return true
        }
        return !CursorOpenProjects.isLive(project)
    }

    private static func requestClaimed(id: String?) -> Bool {
        guard let id, let data = try? Data(contentsOf: requestFileURL()),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let done = json["done"] as? Bool ?? false
        let claimedId = json["id"] as? String
        return done && claimedId == id
    }

    private static func waitUntilNotLive(_ project: OpenProject, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, CursorOpenProjects.isLive(project) {
            Thread.sleep(forTimeInterval: 0.08)
        }
    }

    static func ensureExtensionInstalled() {
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/extensions/local.project-switcher-close-0.1.2", isDirectory: true)
        let sources = [
            Bundle.main.resourceURL?.appendingPathComponent("cursor-extension", isDirectory: true),
            URL(fileURLWithPath: "/Users/Shared/zhaoxin/tools/project_switcher/cursor-extension"),
        ].compactMap { $0 }

        guard let source = sources.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("extension.js").path)
        }) else {
            return
        }

        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in ["package.json", "extension.js"] {
            let from = source.appendingPathComponent(name)
            let to = dest.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: from, to: to)
        }
    }
}

enum CursorOpenProjects {
    static func list() -> [OpenProject] {
        sortByUserClickOrder(loadLiveProjects())
    }

    static func isLive(_ project: OpenProject) -> Bool {
        if project.isWorkspace || CursorWorkspace.isWorkspaceFile(project.path) {
            return isWorkspaceWindowLive(project)
        }
        return liveFolderNames().contains { name in
            name.caseInsensitiveCompare(project.name) == .orderedSame
        }
    }

    /// 先看窗口标题。openedWindows 会滞后：能看到其它工作区标题、但没有这一扇时，视为已关掉。
    private static func isWorkspaceWindowLive(_ project: OpenProject) -> Bool {
        let titles = CursorWindowTitles.list()
        let name = project.name
        if titles.contains(where: { info in
            info.isWorkspace && info.projectName.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return true
        }
        if titles.contains(where: \.isWorkspace) {
            return false
        }
        return liveWorkspacePaths().contains(LocalRecentProjects.normalize(project.path))
            || liveWorkspaceNames().contains { candidate in
                candidate.caseInsensitiveCompare(name) == .orderedSame
            }
    }

    /// 以正在跑的 Cursor 窗口 / extension-host 为准，storage.json 只做路径目录
    private static func loadLiveProjects() -> [OpenProject] {
        let catalog = pathCatalog()
        let opened = openedWindowPaths()
        let windowTitles = CursorWindowTitles.list()

        var seen = Set<String>()
        var projects: [OpenProject] = []

        func append(_ project: OpenProject) {
            let key = LocalRecentProjects.normalize(project.path)
            guard !key.isEmpty, !seen.contains(key) else {
                return
            }
            seen.insert(key)
            projects.append(project)
        }

        let workspacePaths = liveWorkspacePaths(
            catalog: catalog,
            openedWorkspaces: opened.workspaces,
            windowTitles: windowTitles
        )
        var memberFolders = Set<String>()
        for path in workspacePaths {
            append(
                OpenProject(
                    id: path,
                    name: CursorWorkspace.displayName(fromPath: path),
                    path: path,
                    isWorkspace: true
                )
            )
            for member in CursorWorkspace.memberFolders(at: path) {
                memberFolders.insert(LocalRecentProjects.normalize(member))
            }
        }

        let standaloneFolders = Set(opened.folders.map { LocalRecentProjects.normalize($0) })
        let dedicatedFolderNames = Set(
            windowTitles
                .filter { !$0.isWorkspace }
                .map { $0.projectName.lowercased() }
        )

        for name in liveFolderNames().sorted() {
            let folderCatalog = catalog.filter { !CursorWorkspace.isWorkspaceFile($0) }
            let path = resolvePath(name: name, catalog: folderCatalog) ?? name
            let key = LocalRecentProjects.normalize(path)
            if memberFolders.contains(key) {
                let hasDedicatedTitle = dedicatedFolderNames.contains(name.lowercased())
                let listedAsFolderWindow = standaloneFolders.contains(key)
                if !windowTitles.isEmpty {
                    if !hasDedicatedTitle {
                        continue
                    }
                } else if !listedAsFolderWindow {
                    continue
                }
            }
            append(
                OpenProject(
                    id: path,
                    name: (path as NSString).lastPathComponent,
                    path: path
                )
            )
        }
        return projects
    }

    private static func liveWorkspaceNames() -> [String] {
        liveWorkspacePaths().map { CursorWorkspace.displayName(fromPath: $0) }
    }

    private static func liveWorkspacePaths() -> [String] {
        let catalog = pathCatalog()
        let opened = openedWindowPaths()
        return liveWorkspacePaths(
            catalog: catalog,
            openedWorkspaces: opened.workspaces,
            windowTitles: CursorWindowTitles.list()
        )
    }

    private static func liveWorkspacePaths(
        catalog: [String],
        openedWorkspaces: [String],
        windowTitles: [CursorWindowTitles.Info]
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            let key = LocalRecentProjects.normalize(path)
            guard !key.isEmpty, !seen.contains(key) else {
                return
            }
            seen.insert(key)
            result.append(key)
        }

        let workspaceCatalog = catalog.filter { CursorWorkspace.isWorkspaceFile($0) }
        for info in windowTitles where info.isWorkspace {
            if let path = resolvePath(name: info.projectName, catalog: workspaceCatalog)
                ?? resolvePath(name: info.projectName, catalog: catalog) {
                append(path)
            }
        }

        for path in openedWorkspaces {
            let key = LocalRecentProjects.normalize(path)
            guard CursorWorkspace.isWorkspaceFile(key), FileManager.default.fileExists(atPath: key) else {
                continue
            }
            append(key)
        }
        return result
    }

    private static func liveFolderNames() -> [String] {
        let marker = "extension-host (user) "
        var names: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            let label = app.localizedName ?? ""
            guard let markerRange = label.range(of: marker) else {
                continue
            }
            let rest = String(label[markerRange.upperBound...])
            let name: String
            if let bracketRange = rest.range(of: " [") {
                name = String(rest[..<bracketRange.lowerBound])
            } else {
                name = rest
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                names.append(trimmed)
            }
        }
        return names
    }

    private static func pathCatalog() -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        func appendPath(_ raw: String?) {
            guard let raw, let path = pathFromFileURI(raw) else {
                return
            }
            let key = LocalRecentProjects.normalize(path)
            guard !seen.contains(key) else {
                return
            }
            seen.insert(key)
            paths.append(key)
        }

        if let data = loadStorageJSON() {
            let windowsState = data["windowsState"] as? [String: Any] ?? [:]
            if let opened = windowsState["openedWindows"] as? [[String: Any]] {
                for window in opened {
                    appendWindowPaths(window, using: appendPath)
                }
            }
            if let last = windowsState["lastActiveWindow"] as? [String: Any] {
                appendWindowPaths(last, using: appendPath)
            }
            let backup = data["backupWorkspaces"] as? [String: Any] ?? [:]
            if let folders = backup["folders"] as? [[String: Any]] {
                for folder in folders {
                    appendPath(folder["folderUri"] as? String)
                }
            }
            if let workspaces = backup["workspaces"] as? [[String: Any]] {
                for workspace in workspaces {
                    appendPath(workspace["configURIPath"] as? String)
                    appendPath(workspace["configPath"] as? String)
                }
            }
            if let associations = data["profileAssociations"] as? [String: Any],
               let mapped = associations["workspaces"] as? [String: Any] {
                for key in mapped.keys where CursorWorkspace.isWorkspaceFile(key) || key.contains(".code-workspace") {
                    appendPath(key)
                }
            }
        }
        for recent in LocalRecentProjects.orderedPaths() {
            appendPath(recent)
        }
        return paths
    }

    private static func openedWindowPaths() -> (folders: [String], workspaces: [String]) {
        var folders: [String] = []
        var workspaces: [String] = []
        var seenFolders = Set<String>()
        var seenWorkspaces = Set<String>()

        func append(_ raw: String?, into list: inout [String], seen: inout Set<String>) {
            guard let raw, let path = pathFromFileURI(raw) else {
                return
            }
            let key = LocalRecentProjects.normalize(path)
            guard !key.isEmpty, !seen.contains(key) else {
                return
            }
            seen.insert(key)
            list.append(key)
        }

        guard let data = loadStorageJSON() else {
            return ([], [])
        }
        let windowsState = data["windowsState"] as? [String: Any] ?? [:]
        var windows = windowsState["openedWindows"] as? [[String: Any]] ?? []
        if let last = windowsState["lastActiveWindow"] as? [String: Any] {
            windows.append(last)
        }
        for window in windows {
            append(window["folder"] as? String, into: &folders, seen: &seenFolders)
            append(window["workspace"] as? String, into: &workspaces, seen: &seenWorkspaces)
            if let ident = window["workspaceIdentifier"] as? [String: Any] {
                append(ident["configURIPath"] as? String, into: &workspaces, seen: &seenWorkspaces)
                append(ident["configPath"] as? String, into: &workspaces, seen: &seenWorkspaces)
            }
        }
        return (folders, workspaces)
    }

    private static func appendWindowPaths(_ window: [String: Any], using appendPath: (String?) -> Void) {
        appendPath(window["folder"] as? String)
        appendPath(window["workspace"] as? String)
        if let ident = window["workspaceIdentifier"] as? [String: Any] {
            appendPath(ident["configURIPath"] as? String)
            appendPath(ident["configPath"] as? String)
        }
    }

    private static func resolvePath(name: String, catalog: [String]) -> String? {
        let matches = catalog.filter { path in
            let base = (path as NSString).lastPathComponent
            if base.caseInsensitiveCompare(name) == .orderedSame {
                return true
            }
            return CursorWorkspace.displayName(fromPath: path).caseInsensitiveCompare(name) == .orderedSame
        }
        if let existing = matches.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return existing
        }
        if let first = matches.first {
            return first
        }

        var roots = Set(catalog.map { ($0 as NSString).deletingLastPathComponent })
        for extra in [
            "/Users/Shared/golang_project",
            "/Users/Shared/golang_project/data_development",
            "/Users/Shared/frontend",
            "/Users/Shared/tools",
            "/Users/Shared/zhaoxin/tools",
            "/Users/Shared/zhaoxin",
            "/Users/Shared/github_repo",
            "/Users/Shared/cursor_wordspace",
            "\(NSHomeDirectory())/Library/Application Support/Cursor/User/globalStorage/local.cursor-workspace/workspaces",
            "\(NSHomeDirectory())/Library/Application Support/Cursor/glassMultiRootWorkspaces",
        ] {
            roots.insert(extra)
        }
        for scanRoot in ScanRoots.orderedPaths() {
            roots.insert(scanRoot)
        }
        for workspaceRoot in WorkspaceRoots.orderedPaths() {
            roots.insert(workspaceRoot)
        }
        for root in roots {
            let candidate = LocalRecentProjects.normalize((root as NSString).appendingPathComponent(name))
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            let workspaceCandidate = LocalRecentProjects.normalize(
                (root as NSString).appendingPathComponent("\(name).code-workspace")
            )
            if FileManager.default.fileExists(atPath: workspaceCandidate) {
                return workspaceCandidate
            }
        }
        return nil
    }

    /// 点过的按点击顺序排在最前；没点过的保持 openedWindows 原顺序接在后面
    private static func sortByUserClickOrder(_ projects: [OpenProject]) -> [OpenProject] {
        var byPath = [String: OpenProject]()
        for project in projects {
            byPath[LocalRecentProjects.normalize(project.path)] = project
        }

        var result: [OpenProject] = []
        var used = Set<String>()
        for path in LocalRecentProjects.orderedPaths() {
            let key = LocalRecentProjects.normalize(path)
            guard let project = byPath[key], !used.contains(key) else {
                continue
            }
            result.append(project)
            used.insert(key)
        }
        for project in projects {
            let key = LocalRecentProjects.normalize(project.path)
            if !used.contains(key) {
                result.append(project)
            }
        }
        return result
    }

    private static func loadStorageJSON() -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/storage.json"
        )
        guard let raw = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: raw),
              let dict = json as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func pathFromFileURI(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("file://") {
            guard let url = URL(string: trimmed) else { return nil }
            return LocalRecentProjects.normalize(url.path)
        }
        if trimmed.hasPrefix("/") {
            return LocalRecentProjects.normalize(trimmed)
        }
        return nil
    }
}

enum CursorWindowTitles {
    struct Info {
        let title: String
        let projectName: String
        let isWorkspace: Bool
    }

    static func list() -> [Info] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result: [Info] = []
        var seen = Set<String>()
        for row in info {
            let ownerName = row[kCGWindowOwnerName as String] as? String ?? ""
            guard ownerName == "Cursor" else {
                continue
            }
            let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? (row[kCGWindowLayer as String] as? Int)
                ?? -1
            guard layer == 0 else {
                continue
            }
            let title = (row[kCGWindowName as String] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !TitleParser.shouldIgnore(title: title) else {
                continue
            }
            guard !seen.contains(title) else {
                continue
            }
            seen.insert(title)
            result.append(
                Info(
                    title: title,
                    projectName: TitleParser.projectName(from: title),
                    isWorkspace: TitleParser.isWorkspaceWindowTitle(title)
                )
            )
        }
        return result
    }
}
