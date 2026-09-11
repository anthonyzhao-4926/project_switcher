import AppKit
import Foundation

struct OpenProject: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    /// 当前已打开的 Cursor 窗口；扫描到的未打开项目为 false
    let isOpen: Bool

    var searchText: String { "\(name) \(path)" }

    init(id: String, name: String, path: String, isOpen: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.isOpen = isOpen
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
    static func requestClose(_ project: OpenProject) -> Bool {
        ensureExtensionInstalled()
        let folder = requestFileURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let payload: [String: Any] = [
            "path": LocalRecentProjects.normalize(project.path),
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

        let deadline = Date().addingTimeInterval(1.6)
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
            .appendingPathComponent(".cursor/extensions/local.project-switcher-close-0.1.1", isDirectory: true)
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
        liveProjectNames().contains { name in
            name.caseInsensitiveCompare(project.name) == .orderedSame
        }
    }

    /// 以正在跑的 Cursor 窗口为准，不用滞后的 storage.json openedWindows
    private static func loadLiveProjects() -> [OpenProject] {
        let catalog = pathCatalog()
        var seen = Set<String>()
        var projects: [OpenProject] = []
        for name in liveProjectNames().sorted() {
            let path = resolvePath(name: name, catalog: catalog) ?? name
            let key = LocalRecentProjects.normalize(path)
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            projects.append(OpenProject(id: path, name: (path as NSString).lastPathComponent, path: path))
        }
        return projects
    }

    private static func liveProjectNames() -> [String] {
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
                    appendPath(window["folder"] as? String)
                    appendPath(window["workspace"] as? String)
                }
            }
            if let last = windowsState["lastActiveWindow"] as? [String: Any] {
                appendPath(last["folder"] as? String)
            }
            let backup = data["backupWorkspaces"] as? [String: Any] ?? [:]
            if let folders = backup["folders"] as? [[String: Any]] {
                for folder in folders {
                    appendPath(folder["folderUri"] as? String)
                }
            }
        }
        for recent in LocalRecentProjects.orderedPaths() {
            appendPath(recent)
        }
        return paths
    }

    private static func resolvePath(name: String, catalog: [String]) -> String? {
        let matches = catalog.filter { path in
            (path as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
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
        ] {
            roots.insert(extra)
        }
        for scanRoot in ScanRoots.orderedPaths() {
            roots.insert(scanRoot)
        }
        for root in roots {
            let candidate = LocalRecentProjects.normalize((root as NSString).appendingPathComponent(name))
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
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
