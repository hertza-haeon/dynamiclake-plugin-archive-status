// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin

/// Reads a 7z's index.
///
/// A 7z keeps its index compressed, so reading it takes a decompressor.
/// macOS carries one that knows the format: libarchive, the library behind
/// its own `tar` and Archive Utility. It is asked for the list of items
/// only; it extracts nothing and is given the archive to read, never to
/// write. Where the library can't be loaded, a 7z is followed without a
/// total, like any archive whose index can't be read.
enum SevenZipReader {
    static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]

    static func read(path: String) throws(IndexError) -> ArchiveIndex {
        try read(paths: [path])
    }

    /// `paths`: the archive, or its pieces in order when it is cut into
    /// several.
    static func read(paths: [String]) throws(IndexError) -> ArchiveIndex {
        guard let library = SystemArchiveLibrary.shared else { throw .unreadable }
        guard let archive = library.readNew() else { throw .unreadable }
        defer { _ = library.readFree(archive) }
        guard library.supportSevenZip(archive) == SystemArchiveLibrary.ok else { throw .unreadable }
        guard library.open(archive, paths) == SystemArchiveLibrary.ok else {
            throw paths.allSatisfy(FileSource.isReadable) ? .damaged : .unreadable
        }

        var entries: [ArchiveEntry] = []
        var needsPassword = false
        var isWhole = true
        while true {
            var entry: OpaquePointer?
            let result = library.nextHeader(archive, &entry)
            if result == SystemArchiveLibrary.endOfArchive { break }
            // A warning still gives the item; anything worse ends the list.
            guard result == SystemArchiveLibrary.ok || result == SystemArchiveLibrary.warning, let entry else {
                // Nothing at all could be listed: with an encrypted index
                // that is what happens.
                if entries.isEmpty {
                    throw library.hasEncryptedEntries(archive) > 0 ? .locked : .damaged
                }
                isWhole = false
                break
            }
            guard let name = library.pathnameUTF8(entry).map({ String(cString: $0) }) else { continue }
            let path = cleanedPath(name)
            guard path.isEmpty == false else { continue }
            let kind = UInt32(library.filetype(entry)) & UInt32(S_IFMT)
            let isFolder = kind == UInt32(S_IFDIR)
            let isFile = kind == UInt32(S_IFREG)
            let size = library.sizeIsSet(entry) != 0 ? max(0, library.size(entry)) : 0
            guard entries.count < ArchiveIndex.maxEntries else { throw .tooLarge }
            entries.append(ArchiveEntry(path: path, size: isFile ? UInt64(size) : 0, isFolder: isFolder))
            if library.entryIsEncrypted(entry) != 0 {
                needsPassword = true
            }
        }
        return ArchiveIndex(format: .sevenZip, entries: entries, parts: paths,
                            needsPassword: needsPassword, isWhole: isWhole)
    }
}

extension FileSource {
    /// Whether the file can be opened for reading at all.
    static func isReadable(_ path: String) -> Bool {
        (try? FileSource(path: path)) != nil
    }
}

/// The few functions of macOS's libarchive that listing a 7z or a compressed
/// tar takes, looked up by name when first needed. The library is part of macOS but comes
/// without the files a program normally builds against, so the functions'
/// shapes are written out here, from libarchive's own documentation.
struct SystemArchiveLibrary: Sendable {
    static let ok: Int32 = 0
    static let endOfArchive: Int32 = 1
    static let warning: Int32 = -20

    typealias Archive = OpaquePointer
    typealias Entry = OpaquePointer

    let readNew: @convention(c) () -> Archive?
    let readFree: @convention(c) (Archive?) -> Int32
    let supportSevenZip: @convention(c) (Archive?) -> Int32
    let supportTar: @convention(c) (Archive?) -> Int32
    let supportGzip: @convention(c) (Archive?) -> Int32
    let supportBzip2: @convention(c) (Archive?) -> Int32
    let supportXz: @convention(c) (Archive?) -> Int32
    /// The next piece of the current item's data, unpacked: where it is,
    /// how long, and where it goes in the item.
    let readDataBlock: @convention(c) (Archive?, UnsafeMutablePointer<UnsafeRawPointer?>?, UnsafeMutablePointer<Int>?,
                                       UnsafeMutablePointer<Int64>?) -> Int32
    /// The item's path as the archive has it, byte for byte.
    let pathname: @convention(c) (Entry?) -> UnsafePointer<CChar>?
    /// What a hard link points to; nothing for anything else.
    let hardlink: @convention(c) (Entry?) -> UnsafePointer<CChar>?
    let openFilename: @convention(c) (Archive?, UnsafePointer<CChar>?, Int) -> Int32
    /// The same for several files that are one archive put end to end;
    /// the list of names ends with nothing.
    let openFilenames: @convention(c) (Archive?, UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Int32
    let nextHeader: @convention(c) (Archive?, UnsafeMutablePointer<Entry?>?) -> Int32
    let hasEncryptedEntries: @convention(c) (Archive?) -> Int32
    let pathnameUTF8: @convention(c) (Entry?) -> UnsafePointer<CChar>?
    let size: @convention(c) (Entry?) -> Int64
    let sizeIsSet: @convention(c) (Entry?) -> Int32
    let filetype: @convention(c) (Entry?) -> mode_t
    let entryIsEncrypted: @convention(c) (Entry?) -> Int32

    /// Opens an archive to read: one file, or the pieces of one cut into
    /// several, in order.
    func open(_ archive: Archive?, _ paths: [String]) -> Int32 {
        guard paths.count > 1 else { return openFilename(archive, paths.first, 64 * 1024) }
        let names = paths.map { strdup($0) }
        defer { names.forEach { free($0) } }
        let list = names.map { UnsafePointer($0) } + [nil]
        return list.withUnsafeBufferPointer { openFilenames(archive, $0.baseAddress, 64 * 1024) }
    }

    /// The library, or nothing when it or one of its functions is missing.
    static let shared: SystemArchiveLibrary? = load()

    private static func load() -> SystemArchiveLibrary? {
        guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        func function<Shape>(_ name: String, as shape: Shape.Type) -> Shape? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: shape)
        }
        guard
            let readNew = function("archive_read_new", as: (@convention(c) () -> Archive?).self),
            let readFree = function("archive_read_free", as: (@convention(c) (Archive?) -> Int32).self),
            let supportSevenZip = function("archive_read_support_format_7zip",
                                           as: (@convention(c) (Archive?) -> Int32).self),
            let supportTar = function("archive_read_support_format_tar", as: (@convention(c) (Archive?) -> Int32).self),
            let supportGzip = function("archive_read_support_filter_gzip", as: (@convention(c) (Archive?) -> Int32).self),
            let supportBzip2 = function("archive_read_support_filter_bzip2", as: (@convention(c) (Archive?) -> Int32).self),
            let supportXz = function("archive_read_support_filter_xz", as: (@convention(c) (Archive?) -> Int32).self),
            let readDataBlock = function(
                "archive_read_data_block",
                as: (@convention(c) (Archive?, UnsafeMutablePointer<UnsafeRawPointer?>?, UnsafeMutablePointer<Int>?,
                                     UnsafeMutablePointer<Int64>?) -> Int32).self),
            let pathname = function("archive_entry_pathname", as: (@convention(c) (Entry?) -> UnsafePointer<CChar>?).self),
            let hardlink = function("archive_entry_hardlink", as: (@convention(c) (Entry?) -> UnsafePointer<CChar>?).self),
            let openFilename = function("archive_read_open_filename",
                                        as: (@convention(c) (Archive?, UnsafePointer<CChar>?, Int) -> Int32).self),
            let openFilenames = function(
                "archive_read_open_filenames",
                as: (@convention(c) (Archive?, UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Int32).self),
            let nextHeader = function("archive_read_next_header",
                                      as: (@convention(c) (Archive?, UnsafeMutablePointer<Entry?>?) -> Int32).self),
            let hasEncryptedEntries = function("archive_read_has_encrypted_entries",
                                               as: (@convention(c) (Archive?) -> Int32).self),
            let pathnameUTF8 = function("archive_entry_pathname_utf8",
                                        as: (@convention(c) (Entry?) -> UnsafePointer<CChar>?).self),
            let size = function("archive_entry_size", as: (@convention(c) (Entry?) -> Int64).self),
            let sizeIsSet = function("archive_entry_size_is_set", as: (@convention(c) (Entry?) -> Int32).self),
            let filetype = function("archive_entry_filetype", as: (@convention(c) (Entry?) -> mode_t).self),
            let entryIsEncrypted = function("archive_entry_is_encrypted",
                                            as: (@convention(c) (Entry?) -> Int32).self)
        else {
            dlclose(handle)
            return nil
        }
        return SystemArchiveLibrary(
            readNew: readNew, readFree: readFree, supportSevenZip: supportSevenZip,
            supportTar: supportTar, supportGzip: supportGzip, supportBzip2: supportBzip2, supportXz: supportXz,
            readDataBlock: readDataBlock, pathname: pathname, hardlink: hardlink,
            openFilename: openFilename, openFilenames: openFilenames, nextHeader: nextHeader,
            hasEncryptedEntries: hasEncryptedEntries,
            pathnameUTF8: pathnameUTF8, size: size, sizeIsSet: sizeIsSet, filetype: filetype,
            entryIsEncrypted: entryIsEncrypted)
    }
}
