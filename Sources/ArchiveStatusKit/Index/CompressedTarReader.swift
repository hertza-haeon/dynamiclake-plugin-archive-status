// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin

/// Reads the index of a compressed tar: `tar.gz`, `tar.bz2`, `tar.xz` and
/// their short forms.
///
/// A tar's headers lie before each item, and here all of that is inside
/// the compression: reaching them means unpacking the whole archive.
/// macOS's libarchive does it, in memory: what is unpacked is looked at
/// and dropped, and nothing is written anywhere. That takes time in
/// proportion to what the archive unpacks to, so it is given `patience`:
/// past that the archive is followed as one without an index.
enum CompressedTarReader {
    /// How long the reading may take, the plugin doing nothing else
    /// meanwhile.
    static let patience = Duration.seconds(3)
    /// The time is looked at once in this many pieces of unpacked data
    /// (a megabyte or so).
    private static let piecesBetweenChecks = 16

    /// What gzip, bzip2 and xz files begin with.
    private static let signatures: [[UInt8]] = [
        [0x1F, 0x8B],
        [0x42, 0x5A, 0x68],
        [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00],
    ]

    /// Whether these are the first bytes of something compressed one of
    /// those ways. (Whether a tar is inside shows when it is read.)
    static func isCompressed(_ head: [UInt8]) -> Bool {
        signatures.contains { head.starts(with: $0) }
    }

    static func read(path: String) throws(IndexError) -> ArchiveIndex {
        let start = ContinuousClock.now
        return try read(path: path, isOverdue: { ContinuousClock.now - start > patience })
    }

    /// `isOverdue` says whether the reading has taken too long.
    static func read(path: String, isOverdue: () -> Bool) throws(IndexError) -> ArchiveIndex {
        guard let library = SystemArchiveLibrary.shared, let archive = library.readNew() else { throw .unreadable }
        defer { _ = library.readFree(archive) }
        // (Anything but "ok" would mean the library has no decompressor of
        // its own and wants to start a program for it: never.)
        let ok = SystemArchiveLibrary.ok
        guard library.supportTar(archive) == ok, library.supportGzip(archive) == ok,
              library.supportBzip2(archive) == ok, library.supportXz(archive) == ok else { throw .unreadable }
        guard library.openFilename(archive, path, 64 * 1024) == ok else {
            throw FileSource.isReadable(path) ? .notAnArchive : .unreadable
        }

        var entries: [ArchiveEntry] = []
        var isWhole = true
        var pieces = 0
        reading: while true {
            if isOverdue() { throw .tooLarge }
            var entry: OpaquePointer?
            let result = library.nextHeader(archive, &entry)
            if result == SystemArchiveLibrary.endOfArchive { break }
            // A warning still gives the item; anything worse ends the list.
            guard result == ok || result == SystemArchiveLibrary.warning, let entry else {
                // Nothing at all could be listed: no tar in there.
                if entries.isEmpty { throw .notAnArchive }
                isWhole = false
                break
            }
            if let item = item(entry, library) {
                guard entries.count < ArchiveIndex.maxEntries else { throw .tooLarge }
                entries.append(item)
            }
            // The item's data: unpacked a piece at a time and dropped, so
            // that the time can be looked at on the way through a large one.
            while true {
                var data: UnsafeRawPointer?
                var length = 0
                var offset: Int64 = 0
                let step = library.readDataBlock(archive, &data, &length, &offset)
                if step == SystemArchiveLibrary.endOfArchive { break }
                guard step == ok || step == SystemArchiveLibrary.warning else {
                    isWhole = false                          // cut short, or damaged
                    break reading
                }
                pieces += 1
                if pieces % piecesBetweenChecks == 0, isOverdue() { throw .tooLarge }
            }
        }
        return ArchiveIndex(format: .compressedTar, entries: entries, parts: [path], isWhole: isWhole)
    }

    /// One item as the index keeps it; nothing for what it leaves out.
    private static func item(_ entry: OpaquePointer, _ library: SystemArchiveLibrary) -> ArchiveEntry? {
        // The name as text where the library can give it; else byte for
        // byte, as the archive has it.
        var name = library.pathnameUTF8(entry).map { String(cString: $0) }
        if name == nil, let raw = library.pathname(entry) {
            name = decodedName(Array(UnsafeBufferPointer(start: raw, count: strlen(raw))).map { UInt8(bitPattern: $0) }[...])
        }
        guard let name else { return nil }
        let path = cleanedPath(name)
        // What macOS adds beside a file to keep its extra attributes
        // (`._name`): folded back into the file, never written under that
        // name.
        guard path.isEmpty == false, ArchiveName.fileName(of: path).hasPrefix("._") == false else { return nil }
        let kind = UInt32(library.filetype(entry)) & UInt32(S_IFMT)
        let isFolder = kind == UInt32(S_IFDIR)
        let isLink = kind == UInt32(S_IFLNK) || library.hardlink(entry) != nil
        let isFile = kind == UInt32(S_IFREG) && isLink == false
        guard isFolder || isFile || isLink else { return nil }
        let size = isFile && library.sizeIsSet(entry) != 0 ? UInt64(max(0, library.size(entry))) : 0
        return ArchiveEntry(path: path, size: size, isFolder: isFolder, isLink: isLink)
    }
}
