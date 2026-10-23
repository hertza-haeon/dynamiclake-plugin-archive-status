// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import os

/// The lists of compressed tars that take longer to read than a look may
/// last, read beside the plugin's loop.
///
/// A compressed tar has no index: to list it, all of it is unpacked (in
/// memory, by macOS's own library, nothing written). The plugin's loop
/// gives that three seconds (`CompressedTarReader.patience`) and can't
/// stand still for longer; a `tar.bz2` of 500 MB takes seventeen. So the
/// rest is read here, one task for each archive, while the loop goes on;
/// the loop asks at each look whether the list is there.
///
/// This is the one thing in the plugin that runs beside its loop. What the
/// two share is kept under a lock.
final class LaterIndexes: Sendable {
    static let shared = LaterIndexes()

    /// How long one reading may take at most.
    static let longest = Duration.seconds(30 * 60)

    private struct Reading: Sendable {
        var task: Task<Void, Never>?
        var result: Result<ArchiveIndex, IndexError>?
    }

    private let readings = OSAllocatedUnfairLock(initialState: [String: Reading]())
    private let read: @Sendable (String, () -> Bool) -> Result<ArchiveIndex, IndexError>

    /// Tests may give their own way of reading.
    init(read: @escaping @Sendable (String, () -> Bool) -> Result<ArchiveIndex, IndexError> = LaterIndexes.readSlowly) {
        self.read = read
    }

    /// Starts reading the list of the archive at `path`, unless that is
    /// under way or done.
    func begin(_ path: String) {
        let isNew = readings.withLock { readings in
            guard readings[path] == nil else { return false }
            readings[path] = Reading()
            return true
        }
        guard isNew else { return }
        let task = Task.detached(priority: .utility) { [self] in
            let start = ContinuousClock.now
            let result = read(path) { Task.isCancelled || ContinuousClock.now - start > Self.longest }
            // (Given up meanwhile: nobody waits for it.)
            readings.withLock { $0[path]?.result = result }
        }
        readings.withLock { $0[path]?.task = task }
    }

    /// The list once it is read, or why it couldn't be; nothing while the
    /// reading goes on, or when none was begun.
    func result(_ path: String) -> Result<ArchiveIndex, IndexError>? {
        readings.withLock { $0[path]?.result }
    }

    /// Gives the reading up, and forgets what it gave.
    func drop(_ path: String) {
        readings.withLock { $0.removeValue(forKey: path) }?.task?.cancel()
    }

    /// The list of a compressed tar, however long it takes: until
    /// `isOverdue` says to give up.
    static func readSlowly(_ path: String, isOverdue: () -> Bool) -> Result<ArchiveIndex, IndexError> {
        Result { () throws(IndexError) in
            let isInPieces = ArchiveName.numberedPart(path) != nil
            let source = try isInPieces ? FileSource(numberedFrom: path) : FileSource(path: path)
            return try CompressedTarReader.read(paths: source.paths, isOverdue: isOverdue)
        }
    }
}
