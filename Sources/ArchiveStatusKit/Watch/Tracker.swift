// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What is at a path on disk.
public enum FileState: Sendable, Equatable {
    case missing
    case file(size: UInt64)
    /// A folder, with the number of items right inside it where the disk's
    /// format tells that without the folder being listed.
    case folder(items: Int?)
    case other

    /// An empty file or an empty folder: what Archive Utility puts where
    /// its result will be.
    var isEmptyPlaceholder: Bool {
        self == .file(size: 0) || self == .folder(items: 0)
    }
}

/// What the tracker asks of the Mac besides the unarchivers' open files.
/// Tests put stand-ins in its place.
public struct Surroundings: Sendable {
    /// What is at a path. Nothing is opened, and no folder is listed.
    public var fileState: @Sendable (String) -> FileState
    /// When what is at a path last changed (its contents, or its being
    /// put there), in seconds on the Mac's own clock; nothing when nothing
    /// is there. Unlike the dates the Finder shows, an unarchiver can't set
    /// this one: a file just written always says "now".
    public var changeTime: @Sendable (String) -> Double?
    /// The Mac's own clock, in the same seconds.
    public var wallClock: @Sendable () -> Double
    /// Reads an archive's index.
    public var readIndex: @Sendable (String) -> Result<ArchiveIndex, IndexError>
    /// The user's home folder.
    public var home: String

    public init(fileState: @escaping @Sendable (String) -> FileState,
                changeTime: @escaping @Sendable (String) -> Double?,
                wallClock: @escaping @Sendable () -> Double,
                readIndex: @escaping @Sendable (String) -> Result<ArchiveIndex, IndexError>,
                home: String) {
        self.fileState = fileState
        self.changeTime = changeTime
        self.wallClock = wallClock
        self.readIndex = readIndex
        self.home = home
    }

    /// The Mac itself.
    public static var live: Surroundings {
        Surroundings(
            fileState: { path in
                var info = stat()
                guard lstat(path, &info) == 0 else { return .missing }
                switch info.st_mode & S_IFMT {
                case S_IFREG:
                    return .file(size: UInt64(max(0, info.st_size)))
                case S_IFDIR:
                    // On a Mac's own disk format a folder's link count is
                    // the number of its items, plus two.
                    return .folder(items: info.st_nlink >= 2 ? Int(info.st_nlink) - 2 : nil)
                default:
                    return .other
                }
            },
            changeTime: { path in
                var info = stat()
                guard lstat(path, &info) == 0 else { return nil }
                return Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
            },
            wallClock: { Date.now.timeIntervalSince1970 },
            readIndex: { path in
                Result { () throws(IndexError) in try ArchiveIndex.read(at: path) }
            },
            home: NSHomeDirectory())
    }
}

/// One extraction, as far as it can be told from outside.
public struct Extraction: Sendable {
    public enum Ending: Sendable, Equatable {
        /// Everything the archive holds was extracted.
        case complete
        /// It stopped short: cancelled, or failed. From outside the two
        /// look the same.
        case stopped
        /// It ended, and whether it got to its end can't be told.
        case unknown
    }

    /// A number of its own, for as long as the plugin runs.
    public let id: Int
    public let tool: Tool
    /// The archive: its first part, for one in several parts.
    public let archivePath: String
    /// When the first file of it was seen being written (for one that
    /// waits for its turn: when the tool was first seen with it).
    public internal(set) var startedAt: Double
    /// True while the tool has the archive open and has not begun to
    /// extract it: it waits for its turn behind another (The Unarchiver
    /// takes them one after the other), or the tool is still reading it
    /// through before its first file.
    public internal(set) var isWaiting = false
    /// The size of everything once extracted, when the index gave it.
    public internal(set) var total: UInt64?
    /// How much is extracted so far.
    public internal(set) var written: UInt64 = 0
    /// The number of files the archive holds, when the index gave it.
    public internal(set) var fileCount: Int?
    /// Which of them is being written (1 for the first).
    public internal(set) var fileNumber: Int?
    /// The folder the items are written into.
    public internal(set) var destination: String?
    /// Where the extracted item is, or will be: the one item, or the folder
    /// that holds them when there are several. What Open opens.
    public internal(set) var result: String?
    /// What Show in Finder shows, selected: the item, or the items at the
    /// top of what was extracted.
    public internal(set) var revealPaths: [String] = []
    public internal(set) var pace: Pace
    /// Whole seconds left, once that can be told; and when that figure
    /// changes to its next second.
    public internal(set) var secondsLeft: Int?
    public var secondsLeftChangeAt: Double? { secondsLeft == nil ? nil : pace.nextTickAt }
    /// Bytes per second over the last readings.
    public var speed: Double { pace.speed }
    /// Since when nothing more is written, once that has lasted long enough
    /// to call the extraction stalled; nothing while it goes on.
    public internal(set) var stalledSince: Double?
    /// True for an archive without an index: `total` is then the archive's
    /// own size and `written` how far into it the unarchiver has read. It
    /// is the one measure there is of such an extraction (decided on
    /// 12 Oct 2026).
    public internal(set) var measuresArchive = false
    public internal(set) var ending: Ending?
    public internal(set) var endedAt: Double?

    /// The archive's name, as its card says it.
    public var name: String { ArchiveName.fileName(of: archivePath) }
}

/// Follows extractions from what the unarchivers have open, one look at a
/// time. It holds no clock and asks macOS nothing by itself: each look is
/// handed to it, which is what lets every case be replayed in tests.
public struct Tracker: Sendable {
    /// How much attention the next look deserves.
    public enum Attention: Sendable, Equatable {
        /// No unarchiver has an archive open.
        case none
        /// One has: an extraction is under way, or may begin.
        case close
    }

    /// The extractions under way.
    public var extractions: [Extraction] {
        watched.values.compactMap(\.extraction).sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    /// The last extractions that ended, the latest last.
    public private(set) var ended: [Extraction] = []

    public var attention: Attention { watched.isEmpty ? .none : .close }

    /// A progress line goes to the log this often, in seconds.
    static let reportEvery = 1.0
    /// How long Archive Utility is given, once its helper has let go of the
    /// archive, to put the result in place or take its placeholder away.
    static let verdictWait = 5.0
    /// How long Archive Utility's placeholder must have been gone before
    /// that is taken for a stop: never the instant in which the result
    /// might be taking its place.
    static let goneWait = 0.3
    /// How long Keka is given, once the helper it gave an archive to is
    /// gone, to put the result in place or to take its work folder away.
    /// Both can take long with very many files: Keka marks each extracted
    /// file as downloaded when the archive was (14 s for 150,000 files),
    /// and on a cancel it empties the folder file by file (3.4 s for
    /// 63,000). Seen on a real Mac, 12 Oct 2026.
    static func kekaFinishWait(files: Int?) -> Double {
        guard let files else { return 120 }
        return max(30, Double(files) / 2_000)
    }

    /// How many names are tried to find where Archive Utility's result goes.
    static let resultNamesTried = 50
    /// For an archive without an index, Archive Utility's placeholder is
    /// looked for this long after the extraction began, in seconds.
    static let placeholderSearchSeconds = 3.0
    /// How many ended extractions are kept.
    static let endedKept = 20
    /// How many of a tool's own copies of archives are remembered.
    static let copiesKept = 20
    /// How many of an archive's first files are looked for, to tell that
    /// MacPacker has begun to extract it (see `findBeginning`).
    static let firstFilesTried = 3
    /// ...and how long before the tool was seen with the archive open such
    /// a file may have been written, in seconds.
    static let beginningMargin = 1.0
    /// How many places MacPacker extracted into are remembered, to look
    /// there first the next time.
    static let placesKept = 3
    /// The longest an index is taken to have needed to be read, in seconds
    /// (the Mac's clock, which tells it, can be set meanwhile).
    static let longestIndexRead = 60.0

    /// How many items Show in Finder selects at most.
    static let maxRevealed = 30
    /// An extraction under way that writes nothing for this long is
    /// stalled, in seconds.
    static let stallSeconds = 15.0
    /// Without an index, the tool counts as having read the archive to its
    /// end when no more than this is left of it, in bytes, or a hundredth
    /// of it: a tar ends in empty blocks that needn't be read.
    static let unreadEnd: UInt64 = 64 * 1024
    /// A file counts as written by an extraction when it last changed no
    /// earlier than this long before the tool was first seen with the
    /// archive open, in seconds: the first look may come a moment after the
    /// tool began.
    static let writtenMargin = 3.0

    private let surroundings: Surroundings
    private var watched: [Key: Watched] = [:]
    /// The copies a tool made of compressed archives, to extract from
    /// (`Tool.keepsCopy`): for each program, the copy and the archive it was
    /// unpacked from, the latest last.
    private var copies: [Int32: [(copy: String, archive: String)]] = [:]
    /// Where MacPacker last extracted into, the latest first.
    private var recentPlaces: [String] = []
    /// Archives whose extraction is over while the tool still has them
    /// open (The Unarchiver keeps an archive for seconds after it is done
    /// with it, or until the others it was given are done too): not to be
    /// taken for another extraction.
    private var overAndStillOpen: Set<Key> = []
    private var nextID = 1

    public init(surroundings: Surroundings = .live) {
        self.surroundings = surroundings
    }

    /// One archive open in one program.
    private struct Key: Hashable, Comparable {
        var pid: Int32
        var archive: String

        static func < (left: Key, right: Key) -> Bool {
            (left.pid, left.archive) < (right.pid, right.archive)
        }
    }

    private enum IndexState {
        case unread
        case read(IndexLookup)
        case failed(IndexError)
    }

    /// An archive a tool has open, and the extraction it turned out to be,
    /// if it did.
    private struct Watched {
        let tool: Tool
        /// The Mac's clock when the tool was first seen with the archive open.
        let seenAt: Double
        /// At how many looks in a row it has had it open, with no
        /// extraction yet.
        var looks = 0
        /// How far into the archive the tool has read at this look, and
        /// the archive's size; nothing when the archive is in several
        /// parts.
        var reading: (position: UInt64, size: UInt64)?
        /// The tool's own copy of the archive, when it extracts from one:
        /// what it reads then. (The index is still the archive's own: macOS
        /// doesn't let a program read what is in another app's folders,
        /// and doesn't ask either. Seen on a real Mac, 12 Oct 2026.)
        var copy: String?
        /// The second way of telling how far the extraction is (see `probe`).
        var probing = Probing.untried
        var index: IndexState = .unread
        var extraction: Extraction?
        /// The place in the index of the file last seen being written.
        var place = 0
        /// The file last seen being written, and its size then.
        var current: (path: String, size: UInt64)?
        /// Without an index: what the files already left behind add up to.
        var settled: UInt64 = 0
        /// Archive Utility: where the result will be, beside the archive.
        /// While it works, an empty placeholder stands there: an empty
        /// file when the result is one file, an empty folder otherwise.
        var result: String?
        var resultIsFile = false
        /// Whether that placeholder was seen.
        var sawPlaceholder = false
        /// The Unarchiver and Keka: the folder the tool extracts into, where
        /// the result will go (`.TheUnarchiverTemp0`, `photos.kextraction`).
        /// When it is gone, the extraction is over.
        var work: String?
        /// When the tool was first seen without the archive, while the
        /// ending is still being worked out.
        var closedSince: Double?
        /// Since when, after that, nothing is at the result's place.
        var goneSince: Double?
        /// The last look at which a file of this extraction was being written.
        var lastWriteAt: Double?
        var lastReportAt = -Double.infinity
        var lastReported: UInt64?
        var wentBack = false

        var lookup: IndexLookup? {
            if case .read(let lookup) = index { lookup } else { nil }
        }
    }

    // MARK: One look

    /// Takes one look: the unarchivers running at `now` (seconds on a clock
    /// that only moves forward) with their open files. Returns the lines
    /// for the log.
    public mutating func step(now: Double, processes: [ToolProcess]) -> [String] {
        // (Reading an index takes time: what comes after it in this look
        // is as of then. See `readIndexIfNeeded`.)
        var now = now
        var lines: [String] = []
        var open: Set<Key> = []
        var unreadable: Set<Int32> = []

        for process in processes {
            guard let files = process.files else {
                unreadable.insert(process.pid)
                continue
            }
            observe(process, files: files, now: &now, open: &open, lines: &lines)
        }

        // The archives a tool no longer has open: looked into and closed,
        // or an extraction that ended.
        for key in watched.keys.sorted() where open.contains(key) == false && unreadable.contains(key.pid) == false {
            close(key, now: now, lines: &lines)
        }
        overAndStillOpen.formIntersection(open)
        // A program that is gone takes its copies with it.
        if copies.isEmpty == false {
            let running = Set(processes.map(\.pid))
            copies = copies.filter { running.contains($0.key) }
        }
        return lines
    }

    private mutating func observe(_ process: ToolProcess, files: [OpenFile], now: inout Double,
                                  open: inout Set<Key>, lines: inout [String]) {
        let tool = process.tool
        // An archive being extracted is open for reading only. A file open
        // for writing is something being written, whatever its name: an
        // archive may well hold another archive.
        let reads = files.filter { $0.isReadable && $0.isWritable == false }
        let writes = files.filter(\.isWritable)
        noteCopies(of: process, reads: reads, writes: writes)

        // 1. The archives it has open. The parts of a multi-part RAR are
        //    one archive, known by its first part; the tool's own copy of
        //    an archive goes by that archive.
        let known = copies[process.pid] ?? []
        var sources: [(archive: String, file: OpenFile, isCopy: Bool)] = []
        for file in reads {
            if let origin = known.last(where: { $0.copy == file.path })?.archive {
                sources.append((origin, file, true))
            } else if ArchiveName.isArchive(file.path), ArchiveName.isInTrash(file.path) == false {
                sources.append((RarVolumeName.firstPart(of: file.path), file, false))
            }
        }
        for source in sources {
            let key = Key(pid: process.pid, archive: source.archive)
            if overAndStillOpen.contains(key) {
                open.insert(key)                          // (still held, and done with)
                continue
            }
            if watched[key]?.closedSince != nil {
                // Opened again while the ending of the last extraction was
                // still being worked out: that one is settled first.
                finish(key, as: .unknown, now: now, lines: &lines)
            }
            if watched[key] == nil {
                watched[key] = Watched(tool: tool, seenAt: surroundings.wallClock())
            }
            if source.isCopy {
                watched[key]?.copy = source.file.path
            }
            open.insert(key)
        }
        // How far each has been read. (A tool may have an archive open more
        // than once; the reading that moves is the furthest. Once it works
        // from its copy, the copy is what it reads.)
        for key in open where key.pid == process.pid {
            var parts = sources.filter { $0.archive == key.archive }
            if parts.contains(where: \.isCopy) {
                parts.removeAll { $0.isCopy == false }
            }
            let furthest = parts.map(\.file).max { $0.position < $1.position }
            let isOnePart = Set(parts.map(\.file.path)).count == 1
            watched[key]?.reading = isOnePart ? furthest.map { ($0.position, $0.size) } : nil
        }
        // Its archives: those open, and those let go of whose extraction
        // isn't settled yet (the last file may still be being written).
        let keys = watched.keys
            .filter { $0.pid == process.pid && (open.contains($0) || watched[$0]?.extraction != nil) }
            .sorted()
        // (Readings are only taken of archives being followed.)
        guard keys.isEmpty == false else { return }

        // 2. The indexes. Archive Utility's helper has an archive open only
        //    to extract it. MacPacker also has it open to show what is in
        //    it: the index is read once MacPacker writes something.
        let counted = writes.filter { counts($0.path, for: tool) }
        if tool.opensOnlyToExtract || counted.isEmpty == false {
            for key in keys {
                now += readIndexIfNeeded(key)
            }
        }
        // An archive in a tool's queue is known from the moment the tool
        // has it: it waits for its turn.
        if tool.queuesWhatItOpens {
            for key in keys where open.contains(key) && watched[key]?.extraction == nil {
                queue(key, now: now, lines: &lines)
            }
        }
        // Keka has made the folder a helper will work in before it starts
        // the helper: one that has an archive open beside such a folder is
        // about to extract it, and the extraction is known before its first
        // file. (Not at the first look: a helper that starts another has,
        // for an instant, a double of itself with the same archive open.
        // And one helper an archive.)
        if tool == .keka {
            for key in keys where open.contains(key) && watched[key]?.extraction == nil {
                watched[key]?.looks += 1
                let work = Tool.kekaWorkFolder(for: key.archive)
                guard let entry = watched[key], entry.looks >= 2, case .folder = surroundings.fileState(work),
                      isExtracted(key.archive, byAnotherThan: key) == false else { continue }
                now += readIndexIfNeeded(key)
                watched[key]?.work = work
                queue(key, now: now, lines: &lines)
            }
        }
        // (An archive MacPacker keeps open past one look is read all the
        // same, to find the extraction's beginning without waiting for a
        // file to be caught: `findBeginning`. Not one it had open for a
        // moment, to list it; and not a tar, whose reading can take
        // seconds.)
        if tool == .macPacker {
            for key in keys where open.contains(key) && watched[key]?.extraction == nil {
                watched[key]?.looks += 1
                if let entry = watched[key], entry.looks >= 2, entry.copy == nil, ArchiveName.hasIndex(key.archive) {
                    now += readIndexIfNeeded(key)
                }
            }
        }

        // 3. Each file being written belongs to the archive whose index
        //    lists it; where two do, to the one that lists more of its path.
        for write in counted {
            var listed: [(key: Key, match: IndexLookup.Match)] = []
            for key in keys {
                guard let entry = watched[key], let lookup = entry.lookup,
                      let match = lookup.match(write.path, notBefore: entry.place) else { continue }
                listed.append((key, match))
            }
            if let best = owner(among: listed, of: keys.count) {
                note(write, match: best.match, key: best.key, now: now, lines: &lines)
            } else if let key = unlistedOwner(of: write.path, among: keys), countsWithoutIndex(write.path, for: tool) {
                noteUnlisted(write, key: key, now: now, lines: &lines)
            }
        }

        // 3b. MacPacker's first files, found where it puts them, when none
        //     was caught being written.
        if tool == .macPacker {
            for key in keys where open.contains(key) && watched[key]?.extraction == nil {
                findBeginning(key, now: now, lines: &lines)
            }
        }

        // 3c. Keka's too, in the folder it made for the archive: a helper
        //     has a small file open for an instant only. (Seen on a
        //     real Mac, 12 Oct 2026: of 150,000 small files, the first
        //     to be caught was the 46,241st, eight seconds in.)
        if tool == .keka {
            for key in keys where open.contains(key) && watched[key]?.extraction?.isWaiting == true {
                guard let work = watched[key]?.work else { continue }
                beginIfWritten(key, in: [Self.join(work, Tool.kekaWritesInto)], now: now, lines: &lines)
            }
        }

        // 4. What goes on by itself: the placeholder, the pace, the log.
        for key in keys {
            tick(key, isOpen: open.contains(key), now: now, lines: &lines)
        }
    }

    // MARK: A tool's own copies

    /// Remembers the copy a tool is making of a compressed archive: the
    /// file it writes among its own while it reads the archive, and no
    /// other like it. What is extracted from the copy later, under a name
    /// that says nothing, is then known to be that archive's.
    private mutating func noteCopies(of process: ToolProcess, reads: [OpenFile], writes: [OpenFile]) {
        let made = writes.filter { process.tool.keepsCopy(at: $0.path) }
        guard made.isEmpty == false else { return }
        let origins = Set(reads.map(\.path).filter(ArchiveName.isCompressed))
        guard origins.count == 1, let origin = origins.first else { return }
        var known = copies[process.pid] ?? []
        for copy in made where known.contains(where: { $0.copy == copy.path }) == false {
            known.append((copy.path, origin))
        }
        copies[process.pid] = Array(known.suffix(Self.copiesKept))
    }

    // MARK: Whose file it is

    /// Of the archives whose index lists a file being written, the one it
    /// belongs to: the one that lists the most of its path. Where two list
    /// as much (the same thing extracted twice at once: Archive Utility
    /// extracts several archives at the same time, in one helper), each
    /// extraction writes in a place of its own: the one that writes there,
    /// else one that hasn't begun.
    ///
    /// For the same reason, with `count` archives open and more than one,
    /// a file that lies elsewhere than where an extraction writes isn't
    /// that extraction's, even if its index lists one like it: it is
    /// another archive's, which may have no index to claim it by.
    private func owner(among listed: [(key: Key, match: IndexLookup.Match)], of count: Int)
        -> (key: Key, match: IndexLookup.Match)? {
        var listed = listed
        if count > 1 {
            listed.removeAll { candidate in
                guard let place = watched[candidate.key]?.extraction?.destination else { return false }
                return place != candidate.match.root
            }
        }
        guard let depth = listed.map(\.match.depth).max() else { return nil }
        let tied = listed.filter { $0.match.depth == depth }
        guard tied.count > 1 else { return tied.first }
        return tied.first { watched[$0.key]?.extraction?.destination == $0.match.root }
            ?? tied.first { watched[$0.key]?.extraction == nil }
            ?? tied.first
    }

    /// The archive without an index that a file no index lists belongs to,
    /// if that can be told: the only one there is, unless the file lies
    /// where an archive with an index is being extracted (a file its index
    /// doesn't list); or, of several, the one that writes there.
    private func unlistedOwner(of path: String, among keys: [Key]) -> Key? {
        let unindexed = keys.filter { watched[$0]?.lookup == nil }
        guard unindexed.isEmpty == false else { return nil }
        func writesThere(_ key: Key) -> Bool {
            guard let place = watched[key]?.extraction?.destination else { return false }
            return path.hasPrefix(place.hasSuffix("/") ? place : place + "/")
        }
        if let there = unindexed.first(where: writesThere) { return there }
        guard keys.contains(where: { watched[$0]?.lookup != nil && writesThere($0) }) == false else { return nil }
        let fresh = unindexed.filter { watched[$0]?.extraction == nil }
        if unindexed.count == 1 { return unindexed.first }
        return fresh.count == 1 ? fresh.first : nil
    }

    /// Whether another of the tool's programs is already taken to extract
    /// this archive.
    private func isExtracted(_ archive: String, byAnotherThan key: Key) -> Bool {
        watched.contains { $0.key != key && $0.key.archive == archive && $0.value.tool == watched[key]?.tool
            && $0.value.extraction != nil }
    }

    // MARK: Which files count

    /// Whether a file a tool writes can be part of an extraction. MacPacker
    /// keeps files of its own, and what it shows of an archive without
    /// extracting it, in its own folders: those don't count. Nor does what
    /// one of Keka's helpers writes anywhere but in a folder Keka extracts
    /// into.
    private func counts(_ path: String, for tool: Tool) -> Bool {
        switch tool {
        case .archiveUtility:
            true
        case .macPacker, .theUnarchiver:
            path.hasPrefix(surroundings.home + "/Library/") == false
                && path.hasPrefix("/private/var/folders/") == false
                && path.hasPrefix("/var/folders/") == false
        case .keka:
            // (Its helpers also compress: only what goes into a folder it
            // extracts into is an extraction's.)
            tool.workFolder(of: path) != nil
        }
    }

    /// The same for a file no index can vouch for. An archive being written
    /// is then taken for one being made, not extracted (Archive Utility's
    /// helper also compresses, and reads whatever it compresses), and the
    /// helper must be writing into its own temporary folder.
    private func countsWithoutIndex(_ path: String, for tool: Tool) -> Bool {
        guard ArchiveName.isArchive(path) == false else { return false }
        switch tool {
        case .archiveUtility: return path.contains("/TemporaryItems/")
        case .theUnarchiver, .keka: return tool.workFolder(of: path) != nil
        case .macPacker: return true
        }
    }

    // MARK: The index

    /// Reads the archive's index, if that wasn't tried yet, and returns
    /// how long it took, in seconds. With very many items, or a compressed
    /// tar, that is a second or more, and the look it is read in has grown
    /// old by as much: what is measured after it is as of later. (Seen on
    /// a real Mac, 12 Oct: counted as time spent extracting, it made
    /// the first speed a twentieth of the true one, and the extraction
    /// expected to take 475 s.)
    private mutating func readIndexIfNeeded(_ key: Key) -> Double {
        guard var entry = watched[key], case .unread = entry.index else { return 0 }
        let before = surroundings.wallClock()
        switch surroundings.readIndex(key.archive) {
        case .success(let index):
            entry.index = .read(IndexLookup(index))
        case .failure(let error):
            entry.index = .failed(error)
        }
        watched[key] = entry
        return min(max(0, surroundings.wallClock() - before), Self.longestIndexRead)
    }

    // MARK: Waiting for its turn

    /// Takes an archive a tool has in its queue for an extraction that
    /// waits: its size counts from now, and it begins with its first file.
    private mutating func queue(_ key: Key, now: Double, lines: inout [String]) {
        guard var entry = watched[key], entry.extraction == nil else { return }
        var extraction = Extraction(id: takeID(), tool: entry.tool, archivePath: key.archive, startedAt: now, pace: Pace(now: now))
        extraction.isWaiting = true
        var what = "its size can't be read"
        if let lookup = entry.lookup {
            extraction.total = lookup.index.totalSize
            extraction.fileCount = lookup.index.fileCount
            what = "\(Amount.bytes(lookup.index.totalSize)) in \(files(lookup.index.fileCount)) (\(lookup.index.format.logName))"
        }
        entry.extraction = extraction
        watched[key] = entry
        lines.append("\(extraction.name): \(entry.tool.displayName) has it open, to extract it: \(what)")
    }

    // MARK: MacPacker's beginning

    /// Tells that MacPacker has begun to extract an archive it has open,
    /// without a file caught being written. (Found on 12 Oct 2026: the
    /// pill took too long to appear. MacPacker has a small file open for a
    /// fraction of a millisecond: of very many small ones, the first to be
    /// caught may come seconds into the extraction.)
    ///
    /// The archive's first files are looked for where MacPacker puts what
    /// it extracts: beside the archive, in Downloads, where it extracted
    /// last, and in a folder named after the archive in each of those. One
    /// that is there, written since MacPacker opened the archive, is the
    /// beginning. A few questions to macOS a look; no folder is listed.
    private mutating func findBeginning(_ key: Key, now: Double, lines: inout [String]) {
        guard let entry = watched[key], entry.extraction == nil, entry.lookup != nil else { return }
        let name = ArchiveName.baseName(of: key.archive)
        var roots: [String] = []
        for base in [ArchiveName.folder(of: key.archive), Self.join(surroundings.home, "Downloads")] + recentPlaces
            + recentPlaces.map(ArchiveName.folder) where base.isEmpty == false {
            for root in [base, Self.join(base, name)] where roots.contains(root) == false {
                roots.append(root)
            }
        }
        beginIfWritten(key, in: roots, now: now, lines: &lines)
    }

    /// Begins the extraction of an archive when one of its first files is
    /// in one of these folders, written since the tool was seen with the
    /// archive: a few questions to macOS, no folder listed.
    private mutating func beginIfWritten(_ key: Key, in roots: [String], now: Double, lines: inout [String]) {
        guard let entry = watched[key], let lookup = entry.lookup else { return }
        let firsts = lookup.filePlaces.prefix(Self.firstFilesTried)
        for root in roots {
            for place in firsts {
                let path = Self.join(root, lookup.index.entries[place].path)
                guard let changed = surroundings.changeTime(path), changed >= entry.seenAt - Self.beginningMargin,
                      case .file(let size) = surroundings.fileState(path),
                      let match = lookup.match(path, notBefore: 0) else { continue }
                note(OpenFile(path: path, size: size, isReadable: false, isWritable: true), match: match, key: key,
                     now: now, lines: &lines)
                return
            }
        }
    }

    // MARK: A file being written

    private mutating func note(_ write: OpenFile, match: IndexLookup.Match, key: Key, now: Double,
                               lines: inout [String]) {
        guard var entry = watched[key], let lookup = entry.lookup else { return }
        if entry.extraction == nil || entry.extraction?.isWaiting == true {
            // (One that waited keeps its number: it begins now.)
            var extraction = Extraction(id: entry.extraction?.id ?? takeID(), tool: entry.tool, archivePath: key.archive,
                                        startedAt: now, pace: Pace(now: now))
            extraction.total = lookup.index.totalSize
            extraction.fileCount = lookup.index.fileCount
            extraction.destination = match.root
            if entry.tool.worksBesideResult {
                entry.work = entry.tool.workFolder(of: write.path) ?? entry.work
            }
            if Self.writesInPlace(entry) {
                // MacPacker writes at the final place: what it leaves is
                // there from the start. So does The Unarchiver when it is
                // set never to make a folder for what it extracts.
                (extraction.result, extraction.revealPaths) = Self.leftBehind(in: match.root, index: lookup.index)
            }
            if entry.tool == .macPacker {
                recentPlaces.removeAll { $0 == match.root }
                recentPlaces.insert(match.root, at: 0)
                recentPlaces = Array(recentPlaces.prefix(Self.placesKept))
            }
            entry.extraction = extraction
            lines.append(startLine(extraction, index: lookup.index, fromCopy: entry.copy != nil))
        }
        if match.place < entry.place, entry.wentBack == false {
            entry.wentBack = true
            lines.append("\(ArchiveName.fileName(of: key.archive)): a file from earlier in the index is being written "
                         + "(place \(match.place + 1) after \(entry.place + 1)): the progress keeps to the furthest seen")
        }
        if match.place >= entry.place {
            entry.place = match.place
            entry.current = (write.path, write.size)
            entry.extraction?.fileNumber = lookup.fileNumber[match.place]
        }
        let done = lookup.bytesDone(place: match.place, written: write.size)
        if let extraction = entry.extraction, done > extraction.written {
            entry.extraction?.written = done
        }
        entry.lastWriteAt = now
        watched[key] = entry
    }

    private mutating func noteUnlisted(_ write: OpenFile, key: Key, now: Double, lines: inout [String]) {
        guard var entry = watched[key] else { return }
        if entry.extraction == nil || entry.extraction?.isWaiting == true {
            var extraction = Extraction(id: entry.extraction?.id ?? takeID(), tool: entry.tool, archivePath: key.archive,
                                        startedAt: now, pace: Pace(now: now))
            // (Archive Utility: the folder it works in for this archive,
            // which tells its files from those of another it extracts at
            // the same time.)
            extraction.destination = entry.tool.workFolder(of: write.path) ?? ArchiveName.folder(of: write.path)
            entry.extraction = extraction
            if entry.tool.worksBesideResult {
                entry.work = extraction.destination
            }
            var why = "its index can't be read"
            if case .failed(let error) = entry.index {
                why = reason(error)
            }
            if followReading(&entry) {
                lines.append("\(extraction.name): \(entry.tool.displayName) is extracting it; no total to read (\(why)), "
                             + "so it is followed by how far \(Self.whatIsRead(entry)) has been read, "
                             + "of its \(Amount.bytes(entry.extraction?.total ?? 0))")
            } else {
                lines.append("\(extraction.name): \(entry.tool.displayName) is extracting it; total unknown (\(why))")
            }
        }
        // One file at a time: when another file is being written, the one
        // before is taken as done at the size last seen.
        if let current = entry.current, current.path != write.path {
            entry.settled = entry.settled.addingSaturating(current.size)
        }
        entry.current = (write.path, write.size)
        // (Only where the reading of the archive tells nothing: what is
        // caught being written is far from all that is written.)
        let done = entry.settled.addingSaturating(write.size)
        if let extraction = entry.extraction, extraction.measuresArchive == false, done > extraction.written {
            entry.extraction?.written = done
        }
        entry.lastWriteAt = now
        watched[key] = entry
    }

    /// For an archive without an index: takes how far the tool has read
    /// into the archive as the measure of the extraction, when macOS tells
    /// it (the tool reads the archive from one end to the other). Returns
    /// whether it does.
    ///
    /// The amount stops one byte short of the archive's size while the
    /// extraction is under way: a tool reads ahead of what it writes, and
    /// 100 % is only said at the end.
    @discardableResult
    private func followReading(_ entry: inout Watched) -> Bool {
        guard entry.lookup == nil, var extraction = entry.extraction, extraction.ending == nil,
              let reading = entry.reading, reading.position > 0, reading.size > 1 else {
            return entry.extraction?.measuresArchive ?? false
        }
        if extraction.measuresArchive == false {
            extraction.measuresArchive = true
            extraction.total = reading.size
            extraction.written = 0
        }
        extraction.written = max(extraction.written, min(reading.position, reading.size - 1))
        entry.extraction = extraction
        return true
    }

    private func reason(_ error: IndexError) -> String {
        switch error {
        case .unreadable: "the archive can't be read"
        case .notAnArchive: "this kind of archive has no index to read"
        case .damaged: "its index is damaged"
        case .locked: "its index is encrypted"
        case .tooLarge: "it lists too many items, or takes too long to read"
        }
    }

    /// What the tool reads as it extracts, for the log.
    private static func whatIsRead(_ entry: Watched) -> String {
        entry.copy == nil ? "the archive" : "what \(entry.tool.displayName) unpacked it into"
    }

    // MARK: Between two files

    private mutating func tick(_ key: Key, isOpen: Bool, now: Double, lines: inout [String]) {
        guard var entry = watched[key] else { return }
        // The Unarchiver's extraction, and Keka's, is over when its work
        // folder is gone, while the tool may still hold the archive.
        if entry.tool.worksBesideResult, entry.work != nil, entry.extraction?.isWaiting == false,
           let end = besideEnding(entry, key: key), entry.lastWriteAt != now {
            settle(key, as: end, now: now, lines: &lines)
            if isOpen { overAndStillOpen.insert(key) }
            return
        }
        // …and until then, where its result will be is the first of its
        // names that is free.
        if entry.tool.worksBesideResult, entry.result == nil, let work = entry.work, let lookup = entry.lookup {
            let names = Self.namesBeside(of: entry.tool, archivePath: key.archive, index: lookup.index,
                                         in: ArchiveName.folder(of: work)).names
            entry.result = names.first { surroundings.fileState($0) == .missing }
        }
        // (Two archives extracted at the same time may hold an item of the
        // same name: each result has a name of its own, and a place that is
        // another extraction's isn't taken for this one's.)
        let taken = Set(watched.filter { $0.key != key }.compactMap(\.value.result))
        // Archive Utility works in a temporary folder and puts the result
        // beside the archive at the end, under the first name that was
        // free; its placeholder holds that name meanwhile. The name is
        // worked out once, at the first look.
        if entry.tool == .archiveUtility, let lookup = entry.lookup {
            if entry.result == nil {
                let expected = Self.resultNames(archivePath: key.archive, index: lookup.index)
                entry.resultIsFile = expected.isFile
                entry.result = resultPlace(among: expected.names.filter { taken.contains($0) == false }, isFile: expected.isFile)
            }
            if entry.sawPlaceholder == false, let result = entry.result,
               surroundings.fileState(result) == (entry.resultIsFile ? .file(size: 0) : .folder(items: 0)) {
                entry.sawPlaceholder = true
            }
        }
        // Without an index the result's name can't be worked out
        // beforehand, but the placeholder is there all the same: an empty
        // file or folder beside the archive, put there as the extraction
        // began, named after what the helper is writing.
        if entry.tool == .archiveUtility, entry.lookup == nil, entry.result == nil,
           let extraction = entry.extraction, let current = entry.current,
           now - extraction.startedAt <= Self.placeholderSearchSeconds,
           let found = placeholderWithoutIndex(archive: key.archive, written: current.path, since: entry.seenAt, taken: taken) {
            entry.result = found.path
            entry.resultIsFile = found.isFile
            entry.sawPlaceholder = true
        }
        if let note = probe(&entry) {
            lines.append("\(ArchiveName.fileName(of: key.archive)): \(note)")
        }
        if entry.lookup == nil, let extraction = entry.extraction {
            let followed = extraction.measuresArchive
            if followReading(&entry), followed == false {
                lines.append("\(extraction.name): followed from now by how far "
                             + "\(Self.whatIsRead(entry)) has been read, "
                             + "of its \(Amount.bytes(entry.extraction?.total ?? 0))")
            }
        }
        if var extraction = entry.extraction {
            if extraction.result == nil, let result = entry.result {
                extraction.result = result
                extraction.revealPaths = [result]
            }
            extraction.pace.note(extraction.written, now: now)
            extraction.secondsLeft = extraction.pace.timeLeft(total: extraction.total, now: now)
            // Under way (the tool still has the archive), and nothing
            // written for a while: stalled (a question the tool is asking,
            // a disk that went away…).
            let quiet = now - extraction.pace.lastGrowthAt
            if extraction.stalledSince == nil, quiet >= Self.stallSeconds, isOpen, extraction.isWaiting == false,
               Self.isAllWritten(extraction) == false {
                extraction.stalledSince = now
                lines.append("\(extraction.name): stalled: nothing written for \(Int(Self.stallSeconds)) s"
                             + (extraction.total.map { " (at \(Amount.percent(extraction.written, of: $0)))" } ?? ""))
            } else if let since = extraction.stalledSince, quiet < Self.stallSeconds {
                extraction.stalledSince = nil
                // (The speed is measured afresh: over the standstill it
                // would give a time left of hours.)
                extraction.pace.startAfresh(now: now)
                extraction.secondsLeft = nil
                lines.append("\(extraction.name): writing again, after \(Amount.seconds(now - since + Self.stallSeconds)) of nothing")
            }
            if now - entry.lastReportAt >= Self.reportEvery, entry.lastReported != extraction.written,
               extraction.isWaiting == false {
                entry.lastReportAt = now
                entry.lastReported = extraction.written
                lines.append(progressLine(extraction))
            }
            entry.extraction = extraction
        }
        watched[key] = entry
    }

    /// Whether nothing is left to write. A tool may hold the archive a
    /// while longer, finishing in its own way: that is no standstill. (Seen
    /// on a real Mac, 12 Oct: MacPacker kept a tar of 150,000 files
    /// open for 45 seconds after the last of them was written.)
    static func isAllWritten(_ extraction: Extraction) -> Bool {
        guard let total = extraction.total else { return false }
        if extraction.measuresArchive {
            return total - min(extraction.written, total) <= max(unreadEnd, total / 100)
        }
        return extraction.written >= total
    }

    // MARK: How far, without catching a file being written

    /// The second way of telling how far an extraction is.
    private enum Probing {
        /// Not tried yet: no file of this extraction was caught so far.
        case untried
        /// In use; the furthest file known written, by its number among the
        /// files of the index (0 for the first).
        case on(furthest: Int)
        /// Not usable here: a file that was caught being written didn't
        /// say so itself.
        case off
    }

    /// Whether what is at `path` was written since the tool was first seen
    /// with the archive open.
    private func isWritten(_ path: String, since seenAt: Double) -> Bool {
        guard let changed = surroundings.changeTime(path) else { return false }
        return changed >= seenAt - Self.writtenMargin
    }

    /// Brings the extraction's place up to date by asking macOS which of
    /// the archive's files are there, written by this extraction.
    ///
    /// The first way, catching a file while the tool has it open, misses
    /// most of them when they are small: MacPacker has such a file open for
    /// a fraction of a millisecond. But both tools write the files in the
    /// index's order, so the furthest one that is there says how far the
    /// extraction is, at every look. It is found in a few questions: from
    /// the last one known, in strides that double, then by halving.
    ///
    /// A file counts when it changed since the extraction began, so that an
    /// earlier copy of the same archive, extracted to the same place,
    /// doesn't. No folder is listed and nothing is opened.
    ///
    /// Returns a line for the log the one time it finds that it can't be
    /// used.
    private func probe(_ entry: inout Watched) -> String? {
        guard let lookup = entry.lookup, let root = entry.extraction?.destination, entry.extraction?.ending == nil,
              lookup.filePlaces.isEmpty == false else { return nil }
        let files = lookup.filePlaces
        let since = entry.seenAt
        func written(_ number: Int) -> Bool {
            number < files.count && isWritten(Self.join(root, lookup.index.entries[files[number]].path), since: since)
        }
        /// Written, or stepped over: a file the tool left out (it does that
        /// for a name it can't write) must not hold everything up.
        func reached(_ number: Int) -> Bool {
            written(number) || written(number + 1) || written(number + 2)
        }

        // Where the first way has got to, as a number among the files.
        let caught = max(0, lookup.fileNumber[entry.place] - 1)
        var low: Int
        switch entry.probing {
        case .off:
            return nil
        case .untried:
            // The file just caught being written must say so itself; where
            // it doesn't (a disk that keeps no such date), this way is off.
            // (Should the file not be found at all, it is tried again at
            // the next look.)
            let caughtPath = Self.join(root, lookup.index.entries[files[caught]].path)
            guard surroundings.changeTime(caughtPath) != nil else { return nil }
            guard written(caught) else {
                entry.probing = .off
                return "the file being written doesn't tell when it was written: its progress is read from the files "
                    + "caught being written only"
            }
            low = caught
        case .on(let furthest):
            low = max(furthest, caught)
            // Nothing new there (or, with Archive Utility at its end, the
            // files have moved to their final place): as it was.
            guard reached(low) else { return nil }
        }

        // In strides that double, as far as files are there…
        var stride = 1
        var high = low + 1
        while high < files.count, reached(high) {
            low = high
            stride *= 2
            high = low + stride
        }
        high = min(high, files.count)
        // …then by halving, down to the furthest.
        while high - low > 1 {
            let middle = (low + high) / 2
            if reached(middle) {
                low = middle
            } else {
                high = middle
            }
        }
        // (`low` may have been stepped over: the furthest truly there.)
        let furthest = [low + 2, low + 1, low].first(where: written) ?? low
        entry.probing = .on(furthest: furthest)

        let place = files[furthest]
        guard place >= entry.place else { return nil }
        let path = Self.join(root, lookup.index.entries[place].path)
        var size: UInt64 = 0
        if case .file(let onDisk) = surroundings.fileState(path) { size = onDisk }
        entry.place = place
        entry.current = (path, size)
        entry.extraction?.fileNumber = lookup.fileNumber[place]
        let done = lookup.bytesDone(place: place, written: size)
        if let extraction = entry.extraction, done > extraction.written {
            entry.extraction?.written = done
        }
        return nil
    }

    // MARK: The archive is let go of

    private mutating func close(_ key: Key, now: Double, lines: inout [String]) {
        guard var entry = watched[key] else { return }
        guard entry.extraction != nil else {
            // Nothing was written: it was only looked into, or the wait for
            // a password. No extraction to speak of.
            watched[key] = nil
            return
        }
        if entry.extraction?.isWaiting == true {
            // Keka's helper may be done before a file of it was caught
            // being written: what it left tells, as for one that was.
            if entry.tool == .keka {
                entry.closedSince = entry.closedSince ?? now
                watched[key] = entry
                guard let end = kekaEnding(entry, key: key, now: now) else { return }
                if end.result != nil {
                    watched[key]?.extraction?.isWaiting = false
                    settle(key, as: end, now: now, lines: &lines)
                    return
                }
            }
            // It waited for its turn and the tool let go of it: never begun.
            watched[key] = nil
            lines.append("\(ArchiveName.fileName(of: key.archive)): let go of without being extracted")
            return
        }
        // The archive is let go of, but one of its files is still being
        // written: not the end yet. Judging now could take the last file,
        // not quite whole, for a stop.
        if entry.lastWriteAt == now { return }
        switch entry.tool {
        case .macPacker:
            let end = macPackerEnding(entry)
            finish(key, as: end.ending, note: end.note, now: now, lines: &lines)
        case .archiveUtility:
            let since = entry.closedSince ?? now
            entry.closedSince = since
            let isGone = entry.result.map { surroundings.fileState($0) == .missing } ?? false
            entry.goneSince = isGone ? (entry.goneSince ?? now) : nil
            watched[key] = entry
            if let ending = archiveUtilityEnding(entry, now: now) {
                finish(key, as: ending, now: now, lines: &lines)
            }
        case .theUnarchiver where Self.writesInPlace(entry):
            // (No work folder: it wrote at the final place, and is judged
            // as MacPacker is.)
            let end = macPackerEnding(entry)
            finish(key, as: end.ending, note: end.note, now: now, lines: &lines)
        case .theUnarchiver:
            // (Let go of with its work folder still there: it didn't get
            // to its end. The program was quit, say.)
            let end = besideEnding(entry, key: key) ?? (.stopped, nil, nil)
            settle(key, as: end, now: now, lines: &lines)
        case .keka:
            entry.closedSince = entry.closedSince ?? now
            watched[key] = entry
            // What the helper wrote last is still read, so that the amount
            // is the whole of it while Keka finishes; and the folder gone
            // ends it there.
            tick(key, isOpen: false, now: now, lines: &lines)
            if let entry = watched[key], let end = kekaEnding(entry, key: key, now: now) {
                settle(key, as: end, now: now, lines: &lines)
            }
        }
    }

    /// Whether the tool writes this archive's files where they are to
    /// stay: MacPacker always; The Unarchiver when it is set never to make
    /// a folder for what it extracts, which leaves it without its hidden
    /// work folder (seen on a real Mac, 12 Oct 2026).
    private static func writesInPlace(_ entry: Watched) -> Bool {
        entry.tool == .macPacker || (entry.tool == .theUnarchiver && entry.work == nil)
    }

    /// Keka's helper is done, or gone. Keka then gives the result its name
    /// and takes its work folder away: a tenth of a second later, or many
    /// seconds later when it first marks every file as downloaded; on a
    /// cancel it empties the folder and leaves nothing (a real Mac,
    /// 12 Oct 2026). Nothing is returned while that folder is still there
    /// and may yet go; past the wait, the end can't be told.
    private func kekaEnding(_ entry: Watched, key: Key, now: Double)
        -> (ending: Extraction.Ending, note: String?, result: String?)? {
        if let end = besideEnding(entry, key: key) { return end }
        let wait = Self.kekaFinishWait(files: entry.lookup?.index.fileCount)
        return now - (entry.closedSince ?? now) >= wait ? (.unknown, nil, nil) : nil
    }

    /// Ends The Unarchiver's or Keka's extraction of an archive, with
    /// where its result is when it has one.
    private mutating func settle(_ key: Key, as end: (ending: Extraction.Ending, note: String?, result: String?),
                                 now: Double, lines: inout [String]) {
        if let result = end.result {
            watched[key]?.extraction?.result = result
            watched[key]?.extraction?.revealPaths = [result]
        } else {
            // Nothing was put in place (a cancel: seen on a real Mac,
            // The Unarchiver takes its work folder away and leaves
            // nothing), or it can't be told: the name the result would
            // have had is no place.
            watched[key]?.extraction?.result = nil
            watched[key]?.extraction?.revealPaths = []
        }
        finish(key, as: end.ending, note: end.note, now: now, lines: &lines)
    }

    /// The Unarchiver extracts into a hidden folder where the result will
    /// go (`.TheUnarchiverTemp0`) and, at the end, gives what is in it its
    /// name there: the folder is gone and the result is there in the same
    /// instant. It may hold the archive for seconds more, or until the
    /// others it was given are done: its letting go says nothing. (Seen
    /// on a real Mac, 12 Oct 2026.)
    ///
    /// Keka does the same in a folder named after the archive
    /// (`photos.kextraction`), once the helper it gave the archive to is
    /// done.
    ///
    /// Nothing is returned while that folder is there: the extraction is
    /// under way. With it gone:
    /// - no result where one would be: stopped (nothing was put in place);
    /// - a result: every file of the index is looked at, as for MacPacker.
    ///   The Unarchiver and Keka too go through a damaged archive to its
    ///   end and put in place what they could read (46 files of 150,000
    ///   missing).
    private func besideEnding(_ entry: Watched, key: Key)
        -> (ending: Extraction.Ending, note: String?, result: String?)? {
        guard let work = entry.work else { return (.unknown, nil, nil) }
        guard surroundings.fileState(work) == .missing else { return nil }
        guard let lookup = entry.lookup else { return (.unknown, nil, nil) }
        let expected = Self.namesBeside(of: entry.tool, archivePath: key.archive, index: lookup.index,
                                        in: ArchiveName.folder(of: work))
        // Of the names the result may have, the one given since this
        // extraction began; of several, the latest.
        var found: (path: String, changed: Double)?
        for name in expected.names + expected.folderNames.filter({ expected.names.contains($0) == false }) {
            guard let changed = surroundings.changeTime(name), changed >= entry.seenAt - Self.writtenMargin else { continue }
            if changed >= (found?.changed ?? -.infinity) {
                found = (name, changed)
            }
        }
        guard let result = found?.path else { return (.stopped, nil, nil) }
        // The archive's one item has the result's name (it may have got a
        // number), or lies in a folder made for it, named after the
        // archive (The Unarchiver set always to make one: seen on a real
        // Mac, 12 Oct 2026). Where both names are the same, where the
        // archive's first file is tells. Several items are always in such
        // a folder.
        var top = expected.top
        if let item = top, expected.folderNames.contains(result) {
            if expected.names.contains(result) == false {
                top = nil
            } else if let first = lookup.filePlaces.first {
                let path = lookup.index.entries[first].path
                if surroundings.fileState(result + path.dropFirst(item.count)) == .missing,
                   surroundings.fileState(Self.join(result, path)) != .missing {
                    top = nil
                }
            }
        }
        var since: Double?
        if case .on = entry.probing { since = entry.seenAt }
        let lacking = filesLacking(lookup, since: since) { path in
            guard let top else { return Self.join(result, path) }
            return result + path.dropFirst(top.count)
        }
        return lacking > 0 ? (.stopped, Self.lackingNote(lacking, of: lookup), result) : (.complete, nil, result)
    }

    /// The names The Unarchiver or Keka may give the result in `folder`:
    /// the archive's one item, or a folder named after the archive when it
    /// holds several; then, when the name is taken, the same with `-1`,
    /// `-2`… for The Unarchiver and with ` 2`, ` 3`… for Keka (a file's
    /// number before its extension). `top` is that one item's name in the
    /// archive, when there is one; `folderNames` are then the names of a
    /// folder named after the archive, which a tool set to always make one
    /// puts that item into.
    static func namesBeside(of tool: Tool, archivePath: String, index: ArchiveIndex, in folder: String)
        -> (names: [String], top: String?, folderNames: [String]) {
        let tops = Set(index.entries.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        let base = ArchiveName.baseName(of: archivePath)
        var item = base
        var isFolder = true
        var top: String?
        if tops.count == 1, let only = tops.first {
            item = only
            top = only
            isFolder = index.entries.contains { $0.path != only || $0.isFolder }
        }
        func numbered(_ item: String, isFolder: Bool) -> [String] {
            var stem = item
            var ending = ""
            if isFolder == false, let dot = item.lastIndex(of: "."), dot != item.startIndex {
                stem = String(item[..<dot])
                ending = String(item[dot...])
            }
            return (0..<resultNamesTried).map { number in
                if number == 0 { return join(folder, item) }
                return join(folder, tool == .keka ? "\(stem) \(number + 1)\(ending)" : "\(stem)-\(number)\(ending)")
            }
        }
        return (numbered(item, isFolder: isFolder), top, top == nil ? [] : numbered(base, isFolder: true))
    }

    /// MacPacker writes at the final place and tidies nothing up: with the
    /// archive let go of, the last file of the index is there, whole, or it
    /// isn't. And when it is, the others are looked at too: seen on a
    /// real Mac (12 Oct), MacPacker goes through a damaged archive to
    /// its end, leaving out the files it can't read.
    private func macPackerEnding(_ entry: Watched) -> (ending: Extraction.Ending, note: String?) {
        guard let lookup = entry.lookup, let root = entry.extraction?.destination else { return (.unknown, nil) }
        guard let last = lookup.lastSizedPlace else { return (.complete, nil) }       // (nothing but empty files)
        let item = lookup.index.entries[last]
        let path = Self.join(root, item.path)
        guard case .file(let size) = surroundings.fileState(path), size == item.size else { return (.stopped, nil) }
        // Whole, but is it this extraction's? Extracted again over an
        // earlier copy and stopped short, the last file is there, whole,
        // from before. Where files tell when they were written (see
        // `probe`), it must have been written by this extraction.
        var since: Double?
        if case .on = entry.probing { since = entry.seenAt }
        if let since, isWritten(path, since: since) == false {
            return (.stopped, nil)
        }
        let lacking = filesLacking(lookup, since: since) { Self.join(root, $0) }
        if lacking > 0 {
            return (.stopped, Self.lackingNote(lacking, of: lookup))
        }
        return (.complete, nil)
    }

    private static func lackingNote(_ lacking: Int, of lookup: IndexLookup) -> String {
        "\(Amount.count(lacking)) of its \(Amount.count(lookup.filePlaces.count)) files \(lacking == 1 ? "is" : "are") "
            + "missing or cut short"
    }

    /// How many of the archive's files aren't where the extraction went,
    /// whole (and, with `since`, written by this extraction). One question
    /// to macOS a file, or two; no folder is listed. Files the archive
    /// holds under a path more than once are left out: they end up as one.
    /// `whereIs` says where a file of the index is on disk.
    private func filesLacking(_ lookup: IndexLookup, since: Double?, whereIs: (String) -> String) -> Int {
        var lacking = 0
        for place in lookup.filePlaces where lookup.sharedPlaces.contains(place) == false {
            let entry = lookup.index.entries[place]
            let path = whereIs(entry.path)
            switch surroundings.fileState(path) {
            case .missing:
                lacking += 1
                continue
            case .file(let size) where size != entry.size && entry.isLink == false:
                lacking += 1
                continue
            case .folder where entry.size > 0:
                lacking += 1
                continue
            default:
                break                                    // there (a link, or an empty file, in any form)
            }
            if let since, isWritten(path, since: since) == false {
                lacking += 1
            }
        }
        return lacking
    }

    /// With its helper done, Archive Utility fills its placeholder, or
    /// takes it away if the extraction was stopped. Nothing is returned
    /// while that can't be told yet.
    private func archiveUtilityEnding(_ entry: Watched, now: Double) -> Extraction.Ending? {
        guard let result = entry.result else { return .unknown }
        let waitIsOver = now - (entry.closedSince ?? now) >= Self.verdictWait
        let holdsNothing = entry.resultIsFile ? entry.extraction?.total == 0 : entry.lookup?.index.entries.isEmpty == true
        switch surroundings.fileState(result) {
        case .file(let size) where entry.resultIsFile && size > 0:
            return .complete
        case .folder(let items) where entry.resultIsFile == false && items != 0:
            return .complete
        case .file(size: 0) where entry.resultIsFile, .folder(items: 0) where entry.resultIsFile == false:
            // Still the placeholder, unless the archive holds nothing.
            if holdsNothing { return .complete }
        case .missing:
            // The placeholder was there and has stayed gone for a moment:
            // stopped. Never seen (the result may go somewhere else): that
            // can't be told.
            if entry.sawPlaceholder, let gone = entry.goneSince, now - gone >= Self.goneWait { return .stopped }
        default:
            break
        }
        return waitIsOver ? .unknown : nil
    }

    private mutating func finish(_ key: Key, as ending: Extraction.Ending, note: String? = nil, now: Double,
                                 lines: inout [String]) {
        guard let entry = watched.removeValue(forKey: key), var extraction = entry.extraction else { return }
        // What was written of the last file since the last look.
        if ending != .complete, let current = entry.current,
           case .file(let size) = surroundings.fileState(current.path) {
            let done = entry.lookup?.bytesDone(place: entry.place, written: size) ?? entry.settled.addingSaturating(size)
            extraction.written = max(extraction.written, done)
        }
        if ending == .complete, let total = extraction.total {
            extraction.written = total
            extraction.fileNumber = extraction.fileCount
        }
        extraction.ending = ending
        // (Archive Utility: it ended when its helper let go of the archive,
        // not when the result was seen in place.)
        extraction.endedAt = entry.closedSince ?? now
        lines.append(endLine(extraction, entry: entry, note: note))
        ended.append(extraction)
        if ended.count > Self.endedKept {
            ended.removeFirst(ended.count - Self.endedKept)
        }
    }

    // MARK: Where Archive Utility's result goes

    /// The names Archive Utility may give the result, beside the archive:
    /// the archive's one item, or a folder named after the archive when it
    /// holds several; then the same with ` 2`, ` 3`… when the name is taken.
    static func resultNames(archivePath: String, index: ArchiveIndex) -> (names: [String], isFile: Bool) {
        let folder = ArchiveName.folder(of: archivePath)
        let tops = Set(index.entries.compactMap { $0.path.split(separator: "/").first.map(String.init) })
        var item = ArchiveName.baseName(of: archivePath)
        var isFolder = true
        if tops.count == 1, let only = tops.first {
            item = only
            isFolder = index.entries.contains { $0.path != only || $0.isFolder }
        }
        // A file's number goes before its extension, a folder's at the end.
        var stem = item
        var ending = ""
        if isFolder == false, let dot = item.lastIndex(of: "."), dot != item.startIndex {
            stem = String(item[..<dot])
            ending = String(item[dot...])
        }
        let names = (1...resultNamesTried).map { number in
            join(folder, number == 1 ? item : "\(stem) \(number)\(ending)")
        }
        return (names, isFolder == false)
    }

    /// Archive Utility's placeholder for an archive without an index. The
    /// helper writes into `…/NSIRD_ArchiveService_XXXXXX/<item>/…`: the
    /// result is named after that item, or after the archive when it holds
    /// several. The placeholder is the one of those names (with ` 2`,
    /// ` 3`… when taken) that is empty and was put there since the
    /// extraction began.
    private func placeholderWithoutIndex(archive: String, written: String, since seenAt: Double, taken: Set<String> = [])
        -> (path: String, isFile: Bool)? {
        let parts = written.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let work = parts.firstIndex(where: { $0.hasPrefix("NSIRD_") }), work + 1 < parts.count else { return nil }
        let folder = ArchiveName.folder(of: archive)
        var bases = [parts[work + 1], ArchiveName.baseName(of: archive)]
        if bases[0] == bases[1] { bases.removeLast() }
        /// The name, if it is the placeholder; nothing if not; and whether
        /// anything is there at all (the names are taken in order: past a
        /// free one there is nothing of this archive's).
        func look(_ name: String) -> (found: (path: String, isFile: Bool)?, isThere: Bool) {
            let path = Self.join(folder, name)
            let state = surroundings.fileState(path)
            if state.isEmptyPlaceholder, isWritten(path, since: seenAt), taken.contains(path) == false {
                return ((path, state == .file(size: 0)), true)
            }
            return (nil, state != .missing)
        }
        for base in bases {
            let plain = look(base)
            if let found = plain.found { return found }
            guard plain.isThere else { continue }
            // Taken: the same with a number, at the end for a folder, before
            // the extension for a file.
            var numbered: [(Int) -> String] = [{ "\(base) \($0)" }]
            if let dot = base.lastIndex(of: "."), dot != base.startIndex {
                numbered.append { "\(base[..<dot]) \($0)\(base[dot...])" }
            }
            for name in numbered {
                for number in 2...Self.resultNamesTried {
                    let next = look(name(number))
                    if let found = next.found { return found }
                    if next.isThere == false { break }
                }
            }
        }
        return nil
    }

    /// The first of those names that is free, or held by Archive Utility's
    /// placeholder when that is already there: an empty file for a result
    /// that is one file, an empty folder otherwise.
    private func resultPlace(among names: [String], isFile: Bool) -> String? {
        names.first { name in
            let state = surroundings.fileState(name)
            return state == .missing || state == (isFile ? .file(size: 0) : .folder(items: 0))
        }
    }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// What an extraction into `root` leaves there, going by the index: its
    /// one item at the top (a file, or a folder), or several. Returns what
    /// Open opens (the one item, or `root` itself, which holds them) and
    /// what Show in Finder selects.
    static func leftBehind(in root: String, index: ArchiveIndex) -> (result: String, reveal: [String]) {
        var tops: [String] = []
        var seen: Set<String> = []
        for entry in index.entries {
            guard let top = entry.path.split(separator: "/").first.map(String.init), seen.insert(top).inserted else { continue }
            tops.append(top)
        }
        if tops.count == 1, let only = tops.first {
            let item = join(root, only)
            return (item, [item])
        }
        return (root, tops.prefix(maxRevealed).map { join(root, $0) })
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    // MARK: The log's lines

    private func startLine(_ extraction: Extraction, index: ArchiveIndex, fromCopy: Bool) -> String {
        var line = "\(extraction.name): \(extraction.tool.displayName) is extracting it: "
            + "\(Amount.bytes(index.totalSize)) in \(files(index.fileCount)) (\(index.format.logName)"
        if fromCopy { line += ", extracted from what \(extraction.tool.displayName) unpacked it into" }
        if index.parts.count > 1 { line += ", \(index.parts.count) parts" }
        if index.needsPassword { line += ", with a password" }
        if index.isWhole == false { line += ", index incomplete" }
        line += ")"
        if let destination = extraction.destination {
            line += ", into \(destination)"
        }
        return line
    }

    private func progressLine(_ extraction: Extraction) -> String {
        var parts: [String] = []
        if let total = extraction.total {
            parts.append(Amount.percent(extraction.written, of: total))
            parts.append("\(Amount.bytes(extraction.written)) of \(Amount.bytes(total))"
                         + (extraction.measuresArchive ? " of the archive read" : ""))
        } else {
            parts.append("\(Amount.bytes(extraction.written)) written")
        }
        let speed = extraction.pace.speed
        if speed > 0 { parts.append(Amount.speed(speed)) }
        if let left = extraction.secondsLeft {
            parts.append("\(left) s left")
        }
        if let number = extraction.fileNumber, let count = extraction.fileCount, count > 1 {
            parts.append("file \(Amount.count(number)) of \(Amount.count(count))")
        }
        return "\(extraction.name): " + parts.joined(separator: " · ")
    }

    private func endLine(_ extraction: Extraction, entry: Watched, note: String?) -> String {
        let took = Amount.seconds((extraction.endedAt ?? extraction.startedAt) - extraction.startedAt)
        var line = "\(extraction.name): "
        switch extraction.ending {
        case .complete where extraction.measuresArchive:
            line += "complete in \(took) (an archive of \(Amount.bytes(extraction.written)))"
        case .complete:
            line += "complete: \(Amount.bytes(extraction.written)) in \(took)"
        case .stopped where note != nil:
            // Gone through to its end, but not all of it is there.
            line += "not complete after \(took): \(note ?? "")"
        case .stopped:
            line += "stopped short"
            if let total = extraction.total {
                line += " at \(Amount.percent(extraction.written, of: total)) "
                    + "(\(Amount.bytes(extraction.written)) of \(Amount.bytes(total))"
                    + (extraction.measuresArchive ? " of the archive read)" : ")")
            } else {
                line += " with \(Amount.bytes(extraction.written)) written"
            }
            line += " after \(took)"
        case .unknown, nil:
            line += "ended after \(took), and whether it got to its end can't be told "
                + "(\(Amount.bytes(extraction.written)) seen written"
            if let total = extraction.total { line += " of \(Amount.bytes(total))" }
            line += ")"
        }
        if let result = extraction.result {
            line += "; at \(result)"
        }
        if extraction.ending == .unknown, entry.tool == .archiveUtility, extraction.result != nil,
           entry.sawPlaceholder == false {
            line += " (Archive Utility's placeholder was never seen there)"
        }
        return line
    }

    private func files(_ count: Int) -> String {
        "\(Amount.count(count)) file\(count == 1 ? "" : "s")"
    }
}
