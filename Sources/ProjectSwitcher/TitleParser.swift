import Foundation

enum EditorKind: String, Sendable {
    case cursor = "Cursor"

    var processDisplayName: String { "Cursor" }
}

enum TitleParser {
    static let ignoredTitleFragments = [
        "DevTools",
        "Developer Tools",
        "Tooltip",
    ]

    static func shouldIgnore(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        return ignoredTitleFragments.contains { fragment in
            trimmed.localizedCaseInsensitiveContains(fragment)
        }
    }

    /// 从 Cursor 窗口标题解析项目名。
    /// 常见格式：`文件名 — 项目名 — Cursor`、`项目名 — Cursor`。
    static func projectName(from title: String) -> String {
        var core = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in appSuffixes {
            if core.hasSuffix(suffix) {
                core = String(core.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        if let last = lastSegment(core, separatedBy: " — ") {
            return last
        }
        if let last = lastSegment(core, separatedBy: " – ") {
            return last
        }
        if let last = lastSegment(core, separatedBy: " - ") {
            return last
        }
        return core.isEmpty ? title : core
    }

    /// 窗口是否属于该项目（按标题解析出的项目名精确匹配，避免 ads 误伤 third_party_ads）
    static func belongs(windowTitle: String, projectName name: String) -> Bool {
        projectName(from: windowTitle).caseInsensitiveCompare(name) == .orderedSame
    }

    static func matches(windowTitle: String, projectName: String, query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return true
        }
        let needle = trimmedQuery.lowercased()
        return projectName.lowercased().contains(needle)
            || windowTitle.lowercased().contains(needle)
    }

    private static let appSuffixes = [
        " — Cursor",
        " - Cursor",
    ]

    private static func lastSegment(_ text: String, separatedBy separator: String) -> String? {
        let parts = text
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return nil
        }
        return parts.last
    }
}

struct DedupedWindowKey: Hashable, Sendable {
    let projectName: String

    init(projectName: String) {
        self.projectName = projectName.lowercased()
    }
}
