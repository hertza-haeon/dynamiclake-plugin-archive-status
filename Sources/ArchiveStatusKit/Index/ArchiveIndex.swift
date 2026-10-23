// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The kinds of archive whose index this plugin reads.
public enum ArchiveFormat: String, Sendable, Equatable {
    case zip
    case rar4
    case rar5
    case sevenZip
    /// A plain tar, not compressed.
    case tar
    /// A tar inside a compression: `tar.gz`, `tar.bz2`, `tar.xz`.
    case compressedTar

    /// The type as the pill shows it: `zip`, `rar`, `7z`.
    public var typeName: String {
        switch self {
        case .zip: "zip"
        case .rar4, .rar5: "rar"
        case .sevenZip: "7z"
        case .tar, .compressedTar: "tar"
        }
    }

    /// The format as the log names it.
    public var logName: String {
        switch self {
        case .zip: "zip"
        case .rar4: "rar (old format)"
        case .rar5: "rar (RAR5)"
        case .sevenZip: "7z"
        case .tar: "tar"
        case .compressedTar: "compressed tar"
        }
    }
}

/// One item of an archive, as its index describes it.
public struct ArchiveEntry: Sendable, Hashable {
    /// Where the item goes, relative to the place the archive is extracted
    /// to, with `/` between folders.
    public var path: String
    /// Its size once extracted. 0 for a folder or a link.
    public var size: UInt64
    public var isFolder: Bool
    /// A link to another item: on disk it is no plain file of its own.
    public var isLink: Bool

    public init(path: String, size: UInt64, isFolder: Bool = false, isLink: Bool = false) {
        self.path = path
        self.size = size
        self.isFolder = isFolder
        self.isLink = isLink
    }
}

/// Why an index couldn't be read. None of these is an error for the plugin:
/// the extraction is then followed without a total.
public enum IndexError: Error, Equatable, Sendable {
    /// The file can't be opened or read.
    case unreadable
    /// It holds no index of a kind this reader knows.
    case notAnArchive
    /// It is cut short, or isn't what its format says.
    case damaged
    /// The index itself is encrypted: nothing can be read without the password.
    case locked
    /// It lists more items than this reader keeps.
    case tooLarge
}

/// What an archive holds, read from its index alone: nothing is extracted,
/// and the archive is only ever opened for reading.
public struct ArchiveIndex: Sendable, Equatable {
    public var format: ArchiveFormat
    /// The items in the order of the index, which is the order unarchivers
    /// extract them in.
    public var entries: [ArchiveEntry]
    /// The files that make the archive: one, or every part of a multi-part
    /// archive that was found, the first one first.
    public var parts: [String]
    /// At least one item needs a password.
    public var needsPassword: Bool
    /// False when a part is missing or the index stops short: the total may
    /// then be too low.
    public var isWhole: Bool
    /// The size of everything once extracted.
    public var totalSize: UInt64
    /// The number of items that are files.
    public var fileCount: Int

    public init(format: ArchiveFormat, entries: [ArchiveEntry], parts: [String],
                needsPassword: Bool = false, isWhole: Bool = true) {
        self.format = format
        self.entries = entries
        self.parts = parts
        self.needsPassword = needsPassword
        self.isWhole = isWhole
        self.totalSize = entries.reduce(0) { $0.addingSaturating($1.size) }
        self.fileCount = entries.count { $0.isFolder == false }
    }

    /// The most items an index may list. Beyond it the archive is followed
    /// without a total rather than held in memory.
    static let maxEntries = 1_000_000

    /// Reads the index of the archive at `path`. For a multi-part RAR any
    /// part may be given; for an archive cut into numbered pieces
    /// (`photos.7z.001`…), its first piece.
    public static func read(at path: String) throws(IndexError) -> ArchiveIndex {
        let isInPieces = ArchiveName.numberedPart(path) != nil
        let source = try isInPieces ? FileSource(numberedFrom: path) : FileSource(path: path)
        let head = try source.bytes(at: 0, count: Int(min(source.size, 8)))
        if head.starts(with: RarReader.signature5) || head.starts(with: RarReader.signature4) {
            // (A RAR has parts of its own kind, each with its headers; one
            // cut into numbered pieces on top of that isn't read.)
            guard isInPieces == false else { throw .notAnArchive }
            return try RarReader.read(anyPart: path)
        }
        if head.starts(with: SevenZipReader.signature) {
            return try SevenZipReader.read(paths: source.paths)
        }
        if TarReader.isTar(try source.bytes(at: 0, upTo: 512)) {
            return try TarReader.read(source)
        }
        if CompressedTarReader.isCompressed(head) {
            return try CompressedTarReader.read(paths: source.paths)
        }
        // A zip is recognised by its end, not by its beginning: it may have
        // something else in front (a self-extracting one has a program).
        return try ZipReader.read(source)
    }
}

extension UInt64 {
    /// The sum, or the largest number there is when it doesn't fit.
    func addingSaturating(_ other: UInt64) -> UInt64 {
        let (sum, overflowed) = addingReportingOverflow(other)
        return overflowed ? .max : sum
    }
}

/// An item's path as the index gives it, made safe to compare with a path
/// on disk: `/` between folders, and no empty, `.` or `..` part.
func cleanedPath(_ raw: String, backslashIsSeparator: Bool = false) -> String {
    let unified = backslashIsSeparator ? raw.replacing("\\", with: "/") : raw
    return unified
        .split(separator: "/", omittingEmptySubsequences: true)
        .filter { $0 != "." && $0 != ".." }
        .joined(separator: "/")
}
