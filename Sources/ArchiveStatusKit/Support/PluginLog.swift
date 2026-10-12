// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The plugin's log: one line per event, in a file outside the plugin's
/// package (DynamicLake checks that package and nothing may be written into
/// it). Writing to the log is never allowed to break the plugin.
public struct PluginLog: Sendable {
    /// `~/Library/Logs/ArchiveStatus/plugin.log`
    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Logs/ArchiveStatus/plugin.log"
    }

    /// Past this size the log is set aside as `plugin.log.1` and begun anew.
    static let maxBytes: Int64 = 256 * 1024

    public let path: String
    /// Whether each line is printed as well.
    public let echo: Bool

    public init(path: String, echo: Bool = false) {
        self.path = path
        self.echo = echo
    }

    /// Appends one line. `precise` adds the milliseconds to its time.
    public func write(_ message: String, precise: Bool = false) {
        let now = Date.now
        var stamp = Self.stamp(now)
        if precise {
            let milliseconds = Int((now.timeIntervalSince1970 - now.timeIntervalSince1970.rounded(.down)) * 1000)
            stamp += "." + String(repeating: "0", count: 3 - String(milliseconds).count) + String(milliseconds)
        }
        let line = stamp + "  " + message + "\n"
        if echo {
            print(line, terminator: "")
            fflush(stdout)
        }
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var info = stat()
        if stat(path, &info) == 0, info.st_size > Self.maxBytes {
            rename(path, path + ".1")
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// `2026-10-11 17:14:43`, in the Mac's own time zone, whatever its
    /// language and region are set to.
    static func stamp(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        localtime_r(&seconds, &parts)
        func two(_ value: Int32) -> String {
            value < 10 ? "0\(value)" : "\(value)"
        }
        return "\(parts.tm_year + 1900)-\(two(parts.tm_mon + 1))-\(two(parts.tm_mday)) "
            + "\(two(parts.tm_hour)):\(two(parts.tm_min)):\(two(parts.tm_sec))"
    }
}
