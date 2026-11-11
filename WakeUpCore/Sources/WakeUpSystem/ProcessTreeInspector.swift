import Darwin
import Foundation
import WakeUpCore

/// Reads where a process and its ancestors are running from, using libproc.
public struct ProcessTreeInspector: ProcessInspecting {
    /// How many ancestors to look at (a script run by an interpreter run by a shell run by the job...).
    public var maxDepth: Int

    public init(maxDepth: Int = 12) {
        self.maxDepth = maxDepth
    }

    public func locations(ofProcess pid: Int32) -> [String] {
        var found: [String] = []
        var current = pid
        var depth = 0
        while current > 1, depth < maxDepth {
            if let executable = executablePath(ofProcess: current) { found.append(executable) }
            if let directory = workingDirectory(ofProcess: current) { found.append(directory) }
            guard let parent = parentProcess(of: current), parent != current else { break }
            current = parent
            depth += 1
        }
        return found
    }

    public func executablePath(ofProcess pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private func workingDirectory(ofProcess pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    private func parentProcess(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }
}
