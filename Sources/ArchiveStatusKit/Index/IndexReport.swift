// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What an archive's index says, as a few lines of text: for checking the
/// readers against real archives (`archive-status --index <archive>`).
public enum IndexReport {
    public static func text(for path: String) -> String {
        let began = ProcessInfo.processInfo.systemUptime
        let index: ArchiveIndex
        do {
            index = try ArchiveIndex.read(at: path)
        } catch {
            return "\(path)\n  no index: \(error)"
        }
        let took = (ProcessInfo.processInfo.systemUptime - began) * 1000
        var lines = [path]
        var summary = "  \(index.format.logName): \(Amount.count(index.fileCount)) file\(index.fileCount == 1 ? "" : "s"), "
            + "\(Amount.bytes(index.totalSize)) (\(Amount.count(Int(clamping: index.totalSize))) bytes)"
        let folders = index.entries.count - index.fileCount
        if folders > 0 { summary += ", \(Amount.count(folders)) folder\(folders == 1 ? "" : "s")" }
        lines.append(summary)
        if index.parts.count > 1 {
            lines.append("  \(index.parts.count) parts: " + index.parts.map(ArchiveName.fileName).joined(separator: ", "))
        }
        if index.needsPassword { lines.append("  needs a password") }
        if index.isWhole == false { lines.append("  the index is incomplete: the total may be too low") }
        let files = index.entries.filter { $0.isFolder == false }
        if let first = files.first {
            lines.append("  first: \(first.path) (\(Amount.count(Int(clamping: first.size))) bytes)")
        }
        if files.count > 1, let last = files.last {
            lines.append("  last:  \(last.path) (\(Amount.count(Int(clamping: last.size))) bytes)")
        }
        lines.append("  read in \(Int(took.rounded())) ms")
        return lines.joined(separator: "\n")
    }
}
