// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Where the plugin gets its looks from. The real one asks macOS; tests
/// hand in made-up looks.
public protocol Lookout {
    /// The unarchivers running now, with their open files.
    mutating func look(now: Double) -> [ToolProcess]
    /// How long to wait before the next look, in seconds.
    func pause(attention: Tracker.Attention, now: Double) -> Double
}

/// Looks at the unarchivers running on this Mac.
///
/// It looks rarely while nothing happens and often while an archive is
/// open, so that it costs next to nothing when no unarchiver runs:
/// - no unarchiver running: one cheap question to macOS a second;
/// - one running, with no archive open: its open files, four times a second
///   (the sooner an archive is seen open, the sooner its pill: asked for on
///   12 Oct 2026);
/// - an archive open: ten times a second, to catch small files as they are
///   written;
/// - the Archive Utility app, or Keka, has just appeared: ten times a
///   second for a few seconds, because its helper, which does the
///   extracting, starts a moment after it.
///
/// (While Keka stays open with nothing to do, that is one cheap question
/// four times a second.)
public struct SystemLookout: Lookout {
    static let idlePause = 1.0
    static let toolPause = 0.25
    static let closePause = 0.1
    /// How long the app's appearing keeps the looks frequent, in seconds.
    static let heraldSeconds = 10.0

    private var scanner = ToolScanner()
    /// For checks on a real Mac: a second log with every look at a tool
    /// that has something open, as macOS reported it, to the millisecond.
    private let trace: PluginLog?
    private var lastTraced: [Int32: String] = [:]
    /// When the Archive Utility app, or Keka, was first seen running.
    private var heraldSince: Double?
    private var toolIsRunning = false

    public init(trace: PluginLog? = nil) {
        self.trace = trace
    }

    public mutating func look(now: Double) -> [ToolProcess] {
        let tools = scanner.scan()
        let processes = tools.map { ToolProcess(pid: $0.pid, tool: $0.tool, files: OpenFiles.list(of: $0.pid)) }
        if trace != nil {
            traceLook(processes)
        }
        toolIsRunning = tools.isEmpty == false
        heraldSince = scanner.heraldIsRunning ? (heraldSince ?? now) : nil
        return processes
    }

    public func pause(attention: Tracker.Attention, now: Double) -> Double {
        Self.pause(attention: attention, toolIsRunning: toolIsRunning, heraldAge: heraldSince.map { now - $0 })
    }

    /// How long to wait before the next look.
    static func pause(attention: Tracker.Attention, toolIsRunning: Bool, heraldAge: Double?) -> Double {
        if attention == .close { return closePause }
        if let heraldAge, heraldAge < heraldSeconds { return closePause }
        return toolIsRunning || heraldAge != nil ? toolPause : idlePause
    }

    /// Writes a line of the plugin's log into the trace too.
    func traceLine(_ line: String) {
        trace?.write(line, precise: true)
    }

    /// One line whenever what a tool has open changes: the archives it
    /// reads and the files it writes, each with its size.
    private mutating func traceLook(_ processes: [ToolProcess]) {
        var seen: [Int32: String] = [:]
        for process in processes {
            var text = "can't be read"
            if let files = process.files {
                let tool = process.tool
                let archives = files
                    .filter { $0.isWritable == false && (ArchiveName.isArchive($0.path) || tool.keepsCopy(at: $0.path)) }
                    .map { file in
                        "\(ArchiveName.fileName(of: file.path))\(tool.keepsCopy(at: file.path) ? " (its own copy)" : "") "
                            + "at \(file.position) of \(file.size)"
                    }
                let writes = files.filter(\.isWritable).map { "\($0.path) (\($0.size))" }
                text = "reads [\(archives.joined(separator: ", "))] writes [\(writes.joined(separator: ", "))]"
                if archives.isEmpty, writes.isEmpty { text = "nothing" }
            }
            seen[process.pid] = text
            if lastTraced[process.pid] != text {
                trace?.write("  \(process.tool.processName) \(process.pid): \(text)", precise: true)
            }
        }
        for pid in lastTraced.keys where seen[pid] == nil {
            trace?.write("  \(pid): gone", precise: true)
        }
        lastTraced = seen
    }
}
