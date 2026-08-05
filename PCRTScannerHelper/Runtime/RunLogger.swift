import Foundation
import PCRTCore

final class RunLogger {
    let url: URL
    private let lock = NSLock()
    private let handle: FileHandle
    private let sendLog: (String) -> Void
    private let formatter: DateFormatter

    init(url: URL, sendLog: @escaping (String) -> Void) throws {
        self.url = url
        self.sendLog = sendLog
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o640])
        handle = try FileHandle(forWritingTo: url)
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    deinit { try? handle.close() }

    func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        lock.lock()
        defer { lock.unlock() }
        if let data = (line + "\n").data(using: .utf8) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                // Logging must not crash a diagnostic run.
            }
        }
        sendLog(line)
    }
}
