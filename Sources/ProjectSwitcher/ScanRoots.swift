import Foundation

/// 用户配置的扫描根目录；只扫一层子文件夹和 `.code-workspace`，不进默认列表。
enum ScanRoots {
    private static let defaultsKey = "projectSwitcher.scanRoots"

    static func orderedPaths() -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        func append(contentsOf source: [String]) {
            for path in source {
                let normalized = LocalRecentProjects.normalize(path)
                guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
                seen.insert(normalized)
                paths.append(normalized)
            }
        }

        append(contentsOf: readFile() ?? [])
        append(contentsOf: UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        return paths
    }

    static func add(_ path: String) {
        let normalized = LocalRecentProjects.normalize(path)
        guard !normalized.isEmpty else { return }
        var paths = orderedPaths().filter { LocalRecentProjects.normalize($0) != normalized }
        paths.append(normalized)
        persist(paths)
    }

    static func remove(_ path: String) {
        let normalized = LocalRecentProjects.normalize(path)
        persist(orderedPaths().filter { LocalRecentProjects.normalize($0) != normalized })
    }

    static func replaceAll(_ paths: [String]) {
        var seen = Set<String>()
        var unique: [String] = []
        for path in paths {
            let normalized = LocalRecentProjects.normalize(path)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            unique.append(normalized)
        }
        persist(unique)
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
            .appendingPathComponent("scan-roots.json", isDirectory: false)
    }
}

enum ProjectFolderScanner {
    /// 每个根目录只列一层子文件夹和 `.code-workspace`，不递归。
    static func list(roots: [String], fileManager: FileManager = .default) -> [OpenProject] {
        var seen = Set<String>()
        var projects: [OpenProject] = []

        for root in roots {
            let normalizedRoot = LocalRecentProjects.normalize(root)
            guard !normalizedRoot.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: normalizedRoot, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let children: [String]
            do {
                children = try fileManager.contentsOfDirectory(atPath: normalizedRoot)
            } catch let listRootError {
                NSLog("扫描路径失败 \(normalizedRoot): \(listRootError)")
                continue
            }

            for name in children.sorted() {
                if name.hasPrefix(".") { continue }
                let childPath = LocalRecentProjects.normalize(
                    (normalizedRoot as NSString).appendingPathComponent(name)
                )
                var childIsDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: childPath, isDirectory: &childIsDirectory) else {
                    continue
                }
                if childIsDirectory.boolValue {
                    guard !seen.contains(childPath) else { continue }
                    seen.insert(childPath)
                    projects.append(
                        OpenProject(
                            id: childPath,
                            name: name,
                            path: childPath,
                            isOpen: false
                        )
                    )
                    continue
                }
                guard CursorWorkspace.isWorkspaceFile(childPath) else {
                    continue
                }
                guard !seen.contains(childPath) else { continue }
                seen.insert(childPath)
                projects.append(
                    OpenProject(
                        id: childPath,
                        name: CursorWorkspace.displayName(fromPath: childPath),
                        path: childPath,
                        isOpen: false,
                        isWorkspace: true
                    )
                )
            }
        }
        return projects
    }
}

/// 用户配置的工作区目录；只扫一层 `.code-workspace`，不把子文件夹当项目。
enum WorkspaceRoots {
    private static let defaultsKey = "projectSwitcher.workspaceRoots"

    static func orderedPaths() -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        func append(contentsOf source: [String]) {
            for path in source {
                let normalized = LocalRecentProjects.normalize(path)
                guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
                seen.insert(normalized)
                paths.append(normalized)
            }
        }

        append(contentsOf: readFile() ?? [])
        append(contentsOf: UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        return paths
    }

    static func add(_ path: String) {
        let normalized = LocalRecentProjects.normalize(path)
        guard !normalized.isEmpty else { return }
        var paths = orderedPaths().filter { LocalRecentProjects.normalize($0) != normalized }
        paths.append(normalized)
        persist(paths)
    }

    static func remove(_ path: String) {
        let normalized = LocalRecentProjects.normalize(path)
        persist(orderedPaths().filter { LocalRecentProjects.normalize($0) != normalized })
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
            .appendingPathComponent("workspace-roots.json", isDirectory: false)
    }
}

enum WorkspaceFileScanner {
    /// 每个工作区目录只列一层 `.code-workspace`，不递归、不把子文件夹当项目。
    static func list(roots: [String], fileManager: FileManager = .default) -> [OpenProject] {
        var seen = Set<String>()
        var projects: [OpenProject] = []

        for root in roots {
            let normalizedRoot = LocalRecentProjects.normalize(root)
            guard !normalizedRoot.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: normalizedRoot, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let children: [String]
            do {
                children = try fileManager.contentsOfDirectory(atPath: normalizedRoot)
            } catch let listRootError {
                NSLog("扫描工作区目录失败 \(normalizedRoot): \(listRootError)")
                continue
            }

            for name in children.sorted() {
                if name.hasPrefix(".") { continue }
                let childPath = LocalRecentProjects.normalize(
                    (normalizedRoot as NSString).appendingPathComponent(name)
                )
                guard CursorWorkspace.isWorkspaceFile(childPath) else {
                    continue
                }
                guard !seen.contains(childPath) else { continue }
                seen.insert(childPath)
                projects.append(
                    OpenProject(
                        id: childPath,
                        name: CursorWorkspace.displayName(fromPath: childPath),
                        path: childPath,
                        isOpen: false,
                        isWorkspace: true
                    )
                )
            }
        }
        return projects
    }
}
