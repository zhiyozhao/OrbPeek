import Foundation

enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/orbpeek.log"

    static func info(_ s: String) {
        let line = "[OrbPeek \(Date())] \(s)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard let fh = FileHandle(forWritingAtPath: path) else {
                try? line.write(toFile: path, atomically: false, encoding: .utf8)
                return
            }
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            try? fh.write(contentsOf: line.data(using: .utf8)!)
        }
    }
}
