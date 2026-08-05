import Foundation
import Darwin

struct WorkspaceValidator {
    static func validate(arguments: HelperArguments) throws -> URL {
        guard geteuid() == 0 else { throw HelperError.notRoot }
        let workspace = URL(fileURLWithPath: arguments.workspacePath, isDirectory: true).standardizedFileURL
        guard workspace.path.hasPrefix("/Users/") || workspace.path.hasPrefix("/private/var/") || workspace.path.hasPrefix("/var/") else {
            throw HelperError.invalidWorkspace("The report workspace is outside an approved temporary or user directory.")
        }
        var info = stat()
        guard lstat(workspace.path, &info) == 0 else {
            throw HelperError.invalidWorkspace("The report workspace could not be inspected: \(String(cString: strerror(errno))).")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw HelperError.invalidWorkspace("The report workspace is not a directory.")
        }
        guard info.st_uid == arguments.userUID else {
            throw HelperError.invalidWorkspace("The report workspace owner does not match the logged-in user.")
        }
        guard (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw HelperError.invalidWorkspace("The report workspace is writable by another user.")
        }
        let marker = workspace.appendingPathComponent(".pcrt-write-test")
        do {
            try Data("PCRT".utf8).write(to: marker, options: .atomic)
            try FileManager.default.removeItem(at: marker)
        } catch {
            throw HelperError.invalidWorkspace("The report workspace is not writable: \(error.localizedDescription)")
        }
        return workspace
    }

    static func returnOwnership(of workspace: URL, to uid: uid_t) {
        let enumerator = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: nil)
        _ = chown(workspace.path, uid, gid_t.max)
        while let url = enumerator?.nextObject() as? URL {
            _ = chown(url.path, uid, gid_t.max)
        }
    }
}
