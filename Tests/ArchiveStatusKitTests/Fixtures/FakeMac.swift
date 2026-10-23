// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import os
@testable import ArchiveStatusKit

/// A made-up Mac for the tracker: what is on its disk and what its
/// archives hold, set by each test, look after look. Nothing real is
/// touched.
struct FakeMac: Sendable {
    private struct State {
        var disk: [String: FileState] = [:]
        /// When each thing on the disk last changed.
        var changed: [String: Double] = [:]
        /// The made-up Mac's clock.
        var clock = 1_000_000.0
        /// How many times it was asked when something last changed.
        var changeTimeAsked = 0
        var indexes: [String: Result<ArchiveIndex, IndexError>] = [:]
        var indexReads: [String] = []
        /// What reading a list beside the loop gives, once it is done.
        var laterIndexes: [String: Result<ArchiveIndex, IndexError>] = [:]
        /// The lists whose reading beside the loop was begun, and given up.
        var laterBegun: [String] = []
        var laterDropped: [String] = []
        /// How long reading an index takes, by the made-up Mac's clock.
        var indexReadSeconds = 0.0
        /// How long one question about a file takes, by the same clock.
        var fileStateSeconds = 0.0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Puts something at a path, or takes it away (`.missing`). It counts
    /// as changed now, by the made-up Mac's clock, unless said otherwise.
    func put(_ what: FileState, at path: String, changedAt: Double? = nil) {
        state.withLock {
            $0.disk[path] = what == .missing ? nil : what
            $0.changed[path] = what == .missing ? nil : (changedAt ?? $0.clock)
        }
    }

    /// The made-up Mac's clock, in seconds.
    var clock: Double {
        get { state.withLock { $0.clock } }
        nonmutating set { state.withLock { $0.clock = newValue } }
    }

    func setIndex(_ entries: [ArchiveEntry], format: ArchiveFormat = .zip, for path: String, parts: [String]? = nil) {
        let index = ArchiveIndex(format: format, entries: entries, parts: parts ?? [path])
        state.withLock { $0.indexes[path] = .success(index) }
    }

    func setIndexFailure(_ error: IndexError, for path: String) {
        state.withLock { $0.indexes[path] = .failure(error) }
    }

    /// The reading of a list beside the loop comes to its end with this:
    /// asked for from now on, it is there (if the reading was begun).
    func finishLaterIndex(_ entries: [ArchiveEntry], format: ArchiveFormat = .compressedTar, for path: String) {
        let index = ArchiveIndex(format: format, entries: entries, parts: [path])
        state.withLock { $0.laterIndexes[path] = .success(index) }
    }

    func failLaterIndex(_ error: IndexError, for path: String) {
        state.withLock { $0.laterIndexes[path] = .failure(error) }
    }

    /// The archives whose list was begun to be read beside the loop, and
    /// those whose reading was given up, in order.
    var laterBegun: [String] { state.withLock { $0.laterBegun } }
    var laterDropped: [String] { state.withLock { $0.laterDropped } }

    /// How long reading an index takes, in seconds: the made-up Mac's
    /// clock moves on by as much each time one is read.
    var indexReadSeconds: Double {
        get { state.withLock { $0.indexReadSeconds } }
        nonmutating set { state.withLock { $0.indexReadSeconds = newValue } }
    }

    /// How long one question about a file takes, in seconds (thousands of
    /// them are asked at the end of a large archive).
    var fileStateSeconds: Double {
        get { state.withLock { $0.fileStateSeconds } }
        nonmutating set { state.withLock { $0.fileStateSeconds = newValue } }
    }

    /// How many times the tracker asked when something last changed.
    var changeTimeAsked: Int { state.withLock { $0.changeTimeAsked } }

    /// The archives whose index was read, in order.
    var indexReads: [String] { state.withLock { $0.indexReads } }

    var surroundings: Surroundings {
        Surroundings(
            fileState: { path in
                state.withLock {
                    $0.clock += $0.fileStateSeconds
                    return $0.disk[path] ?? .missing
                }
            },
            changeTime: { path in
                state.withLock {
                    $0.changeTimeAsked += 1
                    return $0.changed[path]
                }
            },
            wallClock: { state.withLock { $0.clock } },
            readIndex: { path in
                state.withLock {
                    $0.indexReads.append(path)
                    $0.clock += $0.indexReadSeconds
                    return $0.indexes[path] ?? .failure(.unreadable)
                }
            },
            beginLaterIndex: { path in state.withLock { $0.laterBegun.append(path) } },
            laterIndex: { path in
                state.withLock { $0.laterBegun.contains(path) && $0.laterDropped.contains(path) == false ? $0.laterIndexes[path] : nil }
            },
            dropLaterIndex: { path in state.withLock { $0.laterDropped.append(path) } },
            home: "/Users/me")
    }

    func tracker() -> Tracker {
        Tracker(surroundings: surroundings)
    }
}

/// Whether the owner is at the made-up Mac: set by each test. At the Mac,
/// and just touched it, unless a test says otherwise.
struct FakePresence: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (idle: Optional(0.0), isLocked: false))

    /// How long since the keyboard, the mouse or the trackpad was touched;
    /// nothing when the Mac doesn't say.
    var idle: Double? {
        get { state.withLock { $0.idle } }
        nonmutating set { state.withLock { $0.idle = newValue } }
    }

    var isLocked: Bool {
        get { state.withLock { $0.isLocked } }
        nonmutating set { state.withLock { $0.isLocked = newValue } }
    }

    var presence: Presence {
        Presence(isScreenLocked: { state.withLock { $0.isLocked } }, secondsSinceInput: { state.withLock { $0.idle } })
    }
}

/// An archive open for reading, the tool `at` that far into it (0: it
/// doesn't read it from one end to the other, or macOS doesn't tell).
func reading(_ path: String, size: UInt64 = 1_000, at position: UInt64 = 0) -> OpenFile {
    OpenFile(path: path, size: size, isReadable: true, isWritable: false, position: position)
}

/// A file being written.
func writing(_ path: String, size: UInt64) -> OpenFile {
    OpenFile(path: path, size: size, isReadable: false, isWritable: true)
}

func macPacker(_ files: [OpenFile]?, pid: Int32 = 500) -> ToolProcess {
    ToolProcess(pid: pid, tool: .macPacker, files: files)
}

/// Archive Utility's helper.
func helper(_ files: [OpenFile]?, pid: Int32 = 900) -> ToolProcess {
    ToolProcess(pid: pid, tool: .archiveUtility, files: files)
}

/// The Unarchiver.
func unarchiver(_ files: [OpenFile]?, pid: Int32 = 700) -> ToolProcess {
    ToolProcess(pid: pid, tool: .theUnarchiver, files: files)
}

/// One of Keka's helpers: Keka gives each archive to one of its own.
func kekaHelper(_ files: [OpenFile]?, pid: Int32 = 800) -> ToolProcess {
    ToolProcess(pid: pid, tool: .keka, files: files)
}

/// Where Archive Utility's helper works, as seen on a real Mac.
let helperFolder = "/private/var/folders/2f/x/T/com.apple.desktopservices.ArchiveService/TemporaryItems/NSIRD_ArchiveService_k3xQ9a"
