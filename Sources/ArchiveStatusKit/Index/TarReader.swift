// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Reads the index of a plain `tar`: one that isn't compressed.
///
/// A tar has no index in one place: each item is announced by a header of
/// 512 bytes just before its data. The headers are read and the data
/// stepped over. (A `tar.gz` can't be read this way: its headers are
/// inside the compression. `CompressedTarReader` reads those.)
enum TarReader {
    private static let block = 512
    /// Reading the headers of very many items takes seconds, during which
    /// the plugin does nothing else: past this long it gives up, and the
    /// archive is followed as one without an index.
    static let patience = Duration.seconds(3)
    /// The time is looked at once in this many headers.
    private static let headersBetweenChecks = 512

    /// Whether these are the first bytes of a tar: a header that adds up,
    /// with the word `ustar` at its place.
    static func isTar(_ head: [UInt8]) -> Bool {
        guard head.count >= block, Array(head[257..<262]) == Array("ustar".utf8) else { return false }
        let first = Array(head[..<block])
        return number(first[148..<156]) == checksum(first)
    }

    static func read(_ source: FileSource) throws(IndexError) -> ArchiveIndex {
        let start = ContinuousClock.now
        return try read(source, isOverdue: { ContinuousClock.now - start > patience })
    }

    /// `isOverdue` says whether the reading has taken too long.
    static func read(_ source: FileSource, isOverdue: () -> Bool) throws(IndexError) -> ArchiveIndex {
        var blocks = Blocks(source: source)
        var entries: [ArchiveEntry] = []
        var isWhole = true
        var offset: UInt64 = 0
        var headers = 0
        // What a header just before says of the next item: a long name, a
        // size too large for the usual field.
        var nextPath: [UInt8]?
        var nextSize: UInt64?

        while true {
            guard source.size - offset >= UInt64(block) else {
                isWhole = false                              // no end marker
                break
            }
            headers += 1
            if headers % headersBetweenChecks == 0, isOverdue() { throw .tooLarge }
            let header = Array(try blocks.bytes(at: offset, count: block))
            let sum = checksum(header)
            if sum == 0 { break }                            // the end: an empty block
            guard number(header[148..<156]) == sum else {
                if entries.isEmpty { throw .damaged }
                isWhole = false
                break
            }
            let kind = header[156]
            var size = number(header[124..<136])
            offset += UInt64(block)

            switch kind {
            case UInt8(ascii: "x"), UInt8(ascii: "L"):
                // Says something of the item that follows.
                guard size <= 1024 * 1024, size <= source.size - offset else { throw .damaged }
                let data = try blocks.bytes(at: offset, count: Int(size))
                if kind == UInt8(ascii: "L") {
                    nextPath = Array(text(data))
                } else {
                    let said = extended(data)
                    nextPath = said.path ?? nextPath
                    nextSize = said.size ?? nextSize
                }
            case UInt8(ascii: "g"), UInt8(ascii: "K"):
                break                                        // nothing the index needs
            default:
                var path = Array(text(header[0..<100]))
                // (Only the standard form keeps the start of a long path
                // in a field of its own.)
                let isPosix = Array(header[257..<263]) == Array("ustar".utf8) + [0]
                if isPosix, nextPath == nil {
                    let prefix = text(header[345..<500])
                    if prefix.isEmpty == false { path = prefix + [slash] + path }
                }
                path = nextPath ?? path
                size = nextSize ?? size
                nextPath = nil
                nextSize = nil
                let isFolder = kind == UInt8(ascii: "5") || path.last == slash
                let isFile = kind == 0 || kind == UInt8(ascii: "0") || kind == UInt8(ascii: "7")
                let isLink = kind == UInt8(ascii: "1") || kind == UInt8(ascii: "2")
                let cleaned = cleanedPath(path)
                // What macOS adds beside a file to keep its extra
                // attributes (`._name`): folded back into the file, never
                // written under that name.
                let isCompanion = cleaned.bytes[cleaned.name...].starts(with: "._".utf8)
                if cleaned.bytes.isEmpty == false, isCompanion == false, isFolder || isFile || isLink {
                    guard entries.count < ArchiveIndex.maxEntries else { throw .tooLarge }
                    entries.append(ArchiveEntry(path: decodedName(cleaned.bytes[...]), size: isFile && isFolder == false ? size : 0,
                                                isFolder: isFolder, isLink: isLink))
                }
                // (A link has no data, whatever its header says.)
                if isLink || isFolder { size = 0 }
            }

            // The data, in whole blocks.
            let (padded, overflowed) = size.addingReportingOverflow(UInt64(block) - 1)
            let step = overflowed ? UInt64.max : padded / UInt64(block) * UInt64(block)
            guard step <= source.size - offset else {
                isWhole = false                              // cut short
                break
            }
            offset += step
        }
        return ArchiveIndex(format: .tar, entries: entries, parts: source.paths, isWhole: isWhole)
    }

    /// The file, read a few blocks at a time: the headers of one item (a
    /// long name, then the item's own) lie one after the other, and so do
    /// those of small items.
    private struct Blocks {
        static let ahead = 8 * TarReader.block

        let source: FileSource
        private var start: UInt64 = 0
        private var held: [UInt8] = []

        init(source: FileSource) {
            self.source = source
        }

        mutating func bytes(at offset: UInt64, count: Int) throws(IndexError) -> ArraySlice<UInt8> {
            if offset >= start, offset - start <= UInt64(held.count), UInt64(count) <= UInt64(held.count) - (offset - start) {
                let from = Int(offset - start)
                return held[from..<from + count]
            }
            guard offset <= source.size, UInt64(count) <= source.size - offset else { throw .damaged }
            held = try source.bytes(at: offset, upTo: max(count, Self.ahead))
            start = offset
            return held[0..<count]
        }
    }

    private static let slash = UInt8(ascii: "/")

    /// Text in a header's field: up to its first zero byte.
    private static func text(_ field: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        field.prefix { $0 != 0 }
    }

    /// A path without what an archive shouldn't say (`/` in front, `.` and
    /// `..` among its parts), as `cleanedPath` does it, and where its last
    /// part, the name, begins. Done on the bytes: with very many items,
    /// taking each path apart as text is what takes the time.
    private static func cleanedPath(_ raw: [UInt8]) -> (bytes: [UInt8], name: Int) {
        var cleaned: [UInt8] = []
        cleaned.reserveCapacity(raw.count)
        var name = 0
        for part in raw.split(separator: slash, omittingEmptySubsequences: true)
        where part.elementsEqual(".".utf8) == false && part.elementsEqual("..".utf8) == false {
            if cleaned.isEmpty == false { cleaned.append(slash) }
            name = cleaned.count
            cleaned.append(contentsOf: part)
        }
        return (cleaned, name)
    }

    /// A number in a header's field: written in base eight, or, for a size
    /// too large for that, in plain binary with the top bit set.
    private static func number(_ field: ArraySlice<UInt8>) -> UInt64 {
        guard let first = field.first else { return 0 }
        if first & 0x80 != 0 {
            return field.dropFirst().suffix(8).reduce(0) { $0 << 8 | UInt64($1) }
        }
        var value: UInt64 = 0
        for byte in field {
            guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) else {
                if value == 0, byte == UInt8(ascii: " ") { continue }       // leading spaces
                break
            }
            let (shifted, overflowed) = value.multipliedReportingOverflow(by: 8)
            guard overflowed == false else { return .max }
            value = shifted + UInt64(byte - UInt8(ascii: "0"))
        }
        return value
    }

    /// What a header's bytes add up to, its own figure counted as spaces:
    /// a header says that of itself, which is how something that isn't a
    /// header is told. 0 for an empty block.
    private static func checksum(_ header: [UInt8]) -> UInt64 {
        // (512 bytes can't add up to more than fits.)
        var sum: UInt64 = 0
        for byte in header { sum &+= UInt64(byte) }
        guard sum > 0 else { return 0 }
        for byte in header[148..<156] { sum &-= UInt64(byte) }
        return sum + 8 * 32
    }

    /// What an extended header says of the item that follows, as far as
    /// the index needs it. Its records are `<length> <key>=<value>\n`, one
    /// after the other.
    private static func extended(_ data: ArraySlice<UInt8>) -> (path: [UInt8]?, size: UInt64?) {
        var path: [UInt8]?
        var size: UInt64?
        var rest = data
        while let space = rest.firstIndex(of: UInt8(ascii: " ")),
              let length = Int(String(decoding: rest[..<space], as: UTF8.self)),
              length > space - rest.startIndex + 1, length <= rest.count {
            let body = rest.prefix(length)[(space + 1)...].dropLast()       // without its line end
            rest = rest.dropFirst(length)
            guard let equals = body.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let value = body[(equals + 1)...]
            if body[..<equals].elementsEqual("path".utf8) {
                path = Array(value)
            } else if body[..<equals].elementsEqual("size".utf8) {
                size = UInt64(String(decoding: value, as: UTF8.self))
            }
        }
        return (path, size)
    }
}
