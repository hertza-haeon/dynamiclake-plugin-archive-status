// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin

/// The unarchivers this plugin follows.
public enum Tool: String, Sendable, CaseIterable {
    case macPacker
    case archiveUtility
    case theUnarchiver
    case keka

    /// The tool's name as people know it.
    public var displayName: String {
        switch self {
        case .macPacker: "MacPacker"
        case .archiveUtility: "Archive Utility"
        case .theUnarchiver: "The Unarchiver"
        case .keka: "Keka"
        }
    }

    /// The name of the program that does the extracting. MacPacker and The
    /// Unarchiver extract by themselves; Archive Utility hands the work to
    /// a helper. Keka hands each archive to a helper of its own, named
    /// after what it runs (`kekaunar`, `keka7zz`, `kekatar`…): for Keka,
    /// this is how those names begin.
    var processName: String {
        switch self {
        case .macPacker: "MacPacker"
        case .archiveUtility: "ArchiveService"
        case .theUnarchiver: "The Unarchiver"
        case .keka: "keka"
        }
    }

    /// Whether the tool has an archive open only to extract it. MacPacker
    /// also opens one to show what is in it, and Keka's helpers compress
    /// too, reading whatever they compress.
    var opensOnlyToExtract: Bool {
        self == .archiveUtility || self == .theUnarchiver
    }

    /// Whether the tool has every archive it was given open from the
    /// start, and extracts them one after the other: an archive it has
    /// open then waits for its turn, and is known before it is begun. The
    /// Unarchiver does (a real Mac, 12 Oct 2026). Archive Utility's
    /// helper extracts them all at once, and also reads archives it only
    /// compresses.
    var queuesWhatItOpens: Bool {
        self == .theUnarchiver
    }

    /// Whether the tool extracts into a folder of its own where the result
    /// will go, and gives the result its name there at the end: that folder
    /// gone is then the end of the extraction. The Unarchiver and Keka do
    /// (a real Mac, 12 Oct 2026).
    var worksBesideResult: Bool {
        self == .theUnarchiver || self == .keka
    }

    /// The folder a tool works in for one archive, from a file it writes
    /// there: Archive Utility's helper has
    /// `…/TemporaryItems/NSIRD_ArchiveService_XXXXXX`, The Unarchiver a
    /// hidden `.TheUnarchiverTemp0` where the result will go, Keka
    /// `photos.kextraction` there. Nothing for a file written anywhere
    /// else, and for MacPacker, which writes at the final place.
    func workFolder(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        let work: Int?
        switch self {
        case .macPacker: work = nil
        case .archiveUtility: work = parts.firstIndex { $0.hasPrefix("NSIRD_") }
        case .theUnarchiver: work = parts.firstIndex { $0.hasPrefix(".TheUnarchiverTemp") }
        case .keka: work = parts.firstIndex { $0.hasSuffix(Self.kekaWorkEnding) && $0.count > Self.kekaWorkEnding.count }
        }
        guard let work else { return nil }
        return "/" + parts[...work].joined(separator: "/")
    }

    private static let kekaWorkEnding = ".kextraction"
    /// The folder in there that a helper writes what it extracts into.
    static let kekaWritesInto = "Operation"

    /// The folder Keka makes for an archive before it starts the helper
    /// that extracts it, when the result goes beside the archive: the
    /// archive's name with `.kextraction` for its last extension
    /// (`photos.zip` has `photos.kextraction`, `photos.tar.gz`
    /// `photos.tar.kextraction`).
    static func kekaWorkFolder(for archive: String) -> String {
        var name = ArchiveName.fileName(of: archive)
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            name = String(name[..<dot])
        }
        let folder = ArchiveName.folder(of: archive)
        return (folder.hasSuffix("/") ? folder : folder + "/") + name + kekaWorkEnding
    }

    static func named(_ processName: String) -> Tool? {
        // (The Keka app itself is `Keka`, with a capital.)
        if processName.hasPrefix(Tool.keka.processName) { return .keka }
        return allCases.first { $0.processName == processName }
    }

    /// Whether a file is a copy the tool makes for itself, to work from.
    /// MacPacker doesn't extract a compressed tar as it is: when the
    /// archive is opened, it unpacks it into a plain tar in its own folders,
    /// `…/Caches/ta/<a folder of its own>/<name>`, and whatever it extracts
    /// later comes from there (its source, and a real Mac, 12 Oct 2026).
    func keepsCopy(at path: String) -> Bool {
        guard self == .macPacker else { return false }
        let parts = path.split(separator: "/")
        return parts.count >= 4 && parts[parts.count - 3] == "ta" && parts[parts.count - 4] == "Caches"
    }

    /// Programs that start just before an unarchiver does: the Archive
    /// Utility and Keka apps themselves, which then start their helpers.
    /// While one has just appeared, it pays to look often.
    static let heralds: Set<String> = ["Archive Utility", "Keka"]
}

/// A file a program has open, as macOS reports it.
public struct OpenFile: Sendable, Equatable {
    public var path: String
    /// The file's size at this moment.
    public var size: UInt64
    public var isReadable: Bool
    public var isWritable: Bool
    /// How far into the file the program is, when it reads or writes it
    /// from one end to the other; 0 when it doesn't.
    public var position: UInt64

    public init(path: String, size: UInt64, isReadable: Bool = true, isWritable: Bool = false, position: UInt64 = 0) {
        self.path = path
        self.size = size
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.position = position
    }
}

/// An unarchiver that is running, and the files it has open.
public struct ToolProcess: Sendable, Equatable {
    public var pid: Int32
    public var tool: Tool
    /// Nothing when they couldn't be read this time (the program is on its
    /// way out, say): that is neither "open" nor "closed".
    public var files: [OpenFile]?

    public init(pid: Int32, tool: Tool, files: [OpenFile]?) {
        self.pid = pid
        self.tool = tool
        self.files = files
    }
}

/// Finds the unarchivers among the running programs.
///
/// Asking macOS for the list of running programs is one cheap question. A
/// program's name is asked for when it first shows up, and a few looks
/// more: a helper such as Archive Utility's is started under another name
/// (`xpcproxy`, or the name of the app that starts it) and only takes its
/// own a moment later. After that the name is taken as settled, so that a
/// look costs next to nothing while nothing new has started.
public struct ToolScanner: Sendable {
    /// How many looks a program's name is asked for before it is taken as
    /// not being an unarchiver.
    static let looksBeforeSettled = 5

    /// What a running program is to this plugin.
    private enum Kind: Sendable {
        case tool(Tool)
        case herald
        case other
    }

    /// Every program seen at the last look: what it is, and how many times
    /// its name was asked.
    private var known: [pid_t: (kind: Kind, asked: Int)] = [:]
    /// Whether a herald (see `Tool.heralds`) was running at the last look.
    public private(set) var heraldIsRunning = false
    private let runningPrograms: @Sendable () -> [pid_t]
    private let nameOf: @Sendable (pid_t) -> String?

    /// Stand-ins take the place of macOS's two answers in tests.
    public init(runningPrograms: @escaping @Sendable () -> [pid_t] = ToolScanner.runningPrograms,
                nameOf: @escaping @Sendable (pid_t) -> String? = ToolScanner.name(of:)) {
        self.runningPrograms = runningPrograms
        self.nameOf = nameOf
    }

    /// The unarchivers running right now.
    public mutating func scan() -> [(pid: pid_t, tool: Tool)] {
        var seen: [pid_t: (kind: Kind, asked: Int)] = [:]
        var tools: [(pid: pid_t, tool: Tool)] = []
        var herald = false
        for pid in runningPrograms() where pid > 0 {
            var entry = known[pid] ?? (.other, 0)
            // (A helper may also start under its app's name: Keka's are
            // `Keka` for a few milliseconds. Seen on a real Mac,
            // 12 Oct 2026: asked once, just then, one stayed invisible.)
            var isSettled = entry.asked >= Self.looksBeforeSettled
            if case .tool = entry.kind { isSettled = true }
            if isSettled == false {
                entry = (Self.kind(of: nameOf(pid)), entry.asked + 1)
            }
            seen[pid] = entry
            switch entry.kind {
            case .tool(let tool): tools.append((pid, tool))
            case .herald: herald = true
            case .other: break
            }
        }
        // (A number that is gone is forgotten: the next program to get it
        // is asked afresh.)
        known = seen
        heraldIsRunning = herald
        return tools
    }

    private static func kind(of name: String?) -> Kind {
        guard let name else { return .other }
        if let tool = Tool.named(name) { return .tool(tool) }
        return Tool.heralds.contains(name) ? .herald : .other
    }

    public static func runningPrograms() -> [pid_t] {
        let wanted = proc_listallpids(nil, 0)
        guard wanted > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(wanted) + 64)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return found > 0 ? Array(pids.prefix(Int(found))) : []
    }

    public static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Reads which files another program has open. macOS answers this for the
/// programs of the same user; nothing is opened and nothing is changed.
public enum OpenFiles {
    /// The plain files `pid` has open, or nothing when that can't be read.
    public static func list(of pid: pid_t) -> [OpenFile]? {
        let wanted = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard wanted > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // (Some room more, for files opened meanwhile.)
        var table = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(wanted) / stride + 64)
        let got = table.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return nil }

        var files: [OpenFile] = []
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for entry in table.prefix(Int(got) / stride) where entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let status = info.pvip.vip_vi.vi_stat
            guard UInt32(status.vst_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            guard path.isEmpty == false else { continue }
            files.append(OpenFile(path: path, size: UInt64(max(0, status.vst_size)),
                                  isReadable: info.pfi.fi_openflags & UInt32(FREAD) != 0,
                                  isWritable: info.pfi.fi_openflags & UInt32(FWRITE) != 0,
                                  position: UInt64(max(0, info.pfi.fi_offset))))
        }
        return files
    }
}
