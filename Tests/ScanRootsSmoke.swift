import Foundation

@main
enum ScanRootsSmoke {
    static func main() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-switcher-scan-\(UUID().uuidString)", isDirectory: true)
        let nested = tempRoot.appendingPathComponent("alpha", isDirectory: true)
        let nestedChild = nested.appendingPathComponent("should-not-appear", isDirectory: true)
        let beta = tempRoot.appendingPathComponent("beta", isDirectory: true)
        let hidden = tempRoot.appendingPathComponent(".hidden", isDirectory: true)
        let fileURL = tempRoot.appendingPathComponent("readme.txt", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: nestedChild, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            try "hi".write(to: fileURL, atomically: true, encoding: .utf8)
        } catch let setupTempError {
            fputs("FAIL: 无法创建临时目录 \(setupTempError)\n", stderr)
            exit(1)
        }
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projects = ProjectFolderScanner.list(roots: [tempRoot.path])
        let names = Set(projects.map(\.name))
        if names != ["alpha", "beta"] {
            fputs("FAIL: 应只扫一层可见文件夹，got \(names.sorted())\n", stderr)
            exit(1)
        }
        if projects.contains(where: { $0.isOpen }) {
            fputs("FAIL: 扫描项目不应标记为已打开\n", stderr)
            exit(1)
        }
        if projects.contains(where: { $0.name == "should-not-appear" }) {
            fputs("FAIL: 不应递归到第二层\n", stderr)
            exit(1)
        }

        print("ScanRoots smoke tests passed")
    }
}
