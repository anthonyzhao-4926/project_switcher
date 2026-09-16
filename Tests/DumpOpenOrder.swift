import Foundation

@main
enum DumpOpenOrder {
    static func main() {
        let recent = LocalRecentProjects.orderedPaths()
        fputs("LOCAL_RECENT (\(recent.count)):\n", stdout)
        for (index, path) in recent.enumerated() {
            fputs("  \(index): \(path)\n", stdout)
        }

        let projects = CursorOpenProjects.list()
        fputs("LIST_ORDER (\(projects.count)):\n", stdout)
        for (index, project) in projects.enumerated() {
            let key = LocalRecentProjects.normalize(project.path)
            let rank = recent.firstIndex(of: key).map(String.init) ?? "-"
            let kind = project.isWorkspace ? "workspace" : "folder"
            fputs("  \(index): [\(kind)] \(project.name)  rank=\(rank)  \(project.path)\n", stdout)
        }
    }
}
