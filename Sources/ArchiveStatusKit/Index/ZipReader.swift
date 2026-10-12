// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Reads a zip's index: the "central directory" at its end, which lists
/// every item with its size once extracted. Archives over 4 GB (zip64) are
/// read too.
enum ZipReader {
    private static let endSignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let entrySignature: UInt32 = 0x0201_4B50

    /// The end record without its comment, and the longest comment.
    private static let endLength = 22
    private static let maxComment = 65_535
    /// An item's record without its name and the fields that follow it.
    private static let entryLength = 46
    /// How much of the index is read at a time.
    private static let chunk = 1024 * 1024

    static func read(_ source: FileSource) throws(IndexError) -> ArchiveIndex {
        let end = try endRecord(of: source)
        var entries: [ArchiveEntry] = []
        var needsPassword = false
        var listed: UInt64 = 0
        var reader = ChunkedReader(source: source, start: end.directoryOffset,
                                   end: end.directoryOffset + end.directorySize, chunk: chunk)
        while reader.remaining >= UInt64(entryLength) {
            var fixed = ByteCursor(try reader.take(entryLength))
            guard try fixed.u32() == entrySignature else { break }
            let madeBy = try fixed.u16()
            try fixed.skip(2)                        // version needed
            let flags = try fixed.u16()
            try fixed.skip(2 + 2 + 2 + 4)            // method, time, date, checksum
            try fixed.skip(4)                        // size in the archive
            var size = UInt64(try fixed.u32())
            let nameLength = Int(try fixed.u16())
            let extraLength = Int(try fixed.u16())
            let commentLength = Int(try fixed.u16())
            try fixed.skip(2 + 2)                    // disk, internal attributes
            let attributes = try fixed.u32()
            // (the place of the item in the archive follows: not needed)

            let nameBytes = try reader.take(nameLength)
            let extra = try reader.take(extraLength)
            try reader.skip(commentLength)
            listed += 1

            var name = decodedName(nameBytes)
            for field in extraFields(extra) {
                switch field.id {
                case 0x0001 where size == 0xFFFF_FFFF:
                    // zip64: the real size, when it doesn't fit in four bytes.
                    var cursor = ByteCursor(field.data)
                    size = (try? cursor.u64()) ?? size
                case 0x7075:
                    // The name in Unicode, beside one in an old encoding.
                    if field.data.count > 5, field.data.first == 1,
                       let text = utf8Text(field.data.dropFirst(5)) {
                        name = text
                    }
                default:
                    break
                }
            }

            let path = cleanedPath(name)
            // Made on a Unix system (a Mac too): the upper half of the
            // attributes is the file's mode.
            let mode = (madeBy >> 8) == 3 ? UInt32(attributes >> 16) & 0o170000 : 0
            let isFolder = name.hasSuffix("/") || mode == 0o040000 || (attributes & 0x10) != 0
            let isLink = mode == 0o120000
            // What macOS adds beside each file to keep its extra attributes.
            // Unarchivers on a Mac fold it back into the file: nothing of
            // that name is written.
            let isCompanion = path == "__MACOSX" || path.hasPrefix("__MACOSX/")
            if path.isEmpty == false, isCompanion == false {
                guard entries.count < ArchiveIndex.maxEntries else { throw .tooLarge }
                entries.append(ArchiveEntry(path: path, size: isFolder || isLink ? 0 : size, isFolder: isFolder,
                                            isLink: isLink && isFolder == false))
                if flags & 0x0001 != 0, isFolder == false {
                    needsPassword = true
                }
            }
        }
        // Fewer items than announced: the index stops short.
        let isWhole = listed >= end.entryCount
        return ArchiveIndex(format: .zip, entries: entries, parts: [source.path],
                            needsPassword: needsPassword, isWhole: isWhole)
    }

    private struct EndRecord {
        var directoryOffset: UInt64
        var directorySize: UInt64
        var entryCount: UInt64
    }

    /// Finds the record that closes a zip and says where its index is.
    private static func endRecord(of source: FileSource) throws(IndexError) -> EndRecord {
        guard source.size >= UInt64(endLength) else { throw .notAnArchive }
        let tailLength = Int(min(source.size, UInt64(endLength + maxComment)))
        let tailStart = source.size - UInt64(tailLength)
        let tail = try source.bytes(at: tailStart, count: tailLength)

        // The record is at the very end, before a comment of any length:
        // looked for from the end backwards.
        var found: Int?
        var index = tailLength - endLength
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                let comment = Int(tail[index + 20]) | Int(tail[index + 21]) << 8
                if index + endLength + comment <= tailLength {
                    found = index
                    break
                }
            }
            index -= 1
        }
        guard let found else { throw .notAnArchive }

        var cursor = ByteCursor(tail[found...])
        try cursor.skip(4 + 2 + 2 + 2)               // signature, disk numbers, items on this disk
        var entryCount = UInt64(try cursor.u16())
        var directorySize = UInt64(try cursor.u32())
        var directoryOffset = UInt64(try cursor.u32())
        let endOffset = tailStart + UInt64(found)
        var directoryEnd = endOffset

        // zip64: the same numbers in eight bytes, in a record just before.
        if endOffset >= 20 {
            var locator = ByteCursor(try source.bytes(at: endOffset - 20, count: 20))
            if try locator.u32() == zip64LocatorSignature {
                try locator.skip(4)
                let recordOffset = try locator.u64()
                var record = ByteCursor(try source.bytes(at: recordOffset, count: 56))
                guard try record.u32() == zip64EndSignature else { throw .damaged }
                try record.skip(8 + 2 + 2 + 4 + 4 + 8)
                entryCount = try record.u64()
                directorySize = try record.u64()
                directoryOffset = try record.u64()
                directoryEnd = recordOffset
            }
        }

        guard directorySize <= directoryEnd else { throw .damaged }
        if hasEntry(at: directoryOffset, in: source) == false || directoryOffset > directoryEnd - directorySize {
            // Something stands in front of the zip (a self-extracting one):
            // the index is then right before its end record.
            directoryOffset = directoryEnd - directorySize
            if directorySize > 0, hasEntry(at: directoryOffset, in: source) == false { throw .damaged }
        }
        return EndRecord(directoryOffset: directoryOffset, directorySize: directorySize, entryCount: entryCount)
    }

    private static func hasEntry(at offset: UInt64, in source: FileSource) -> Bool {
        guard let bytes = try? source.bytes(at: offset, count: 4) else { return false }
        return bytes == [0x50, 0x4B, 0x01, 0x02]
    }

    /// The numbered fields that follow an item's name.
    private static func extraFields(_ extra: ArraySlice<UInt8>) -> [(id: UInt16, data: ArraySlice<UInt8>)] {
        var fields: [(id: UInt16, data: ArraySlice<UInt8>)] = []
        var cursor = ByteCursor(extra)
        while cursor.remaining >= 4 {
            guard let id = try? cursor.u16(), let length = try? cursor.u16(),
                  let data = try? cursor.take(Int(length)) else { break }
            fields.append((id, data))
        }
        return fields
    }
}

/// Reads a stretch of a file in order, a chunk at a time, so that a long
/// index isn't held in memory whole.
struct ChunkedReader {
    private let source: FileSource
    private let end: UInt64
    private let chunk: Int
    private var buffer: [UInt8] = []
    private var cursor = 0
    /// Where the next read from the file starts.
    private var next: UInt64

    init(source: FileSource, start: UInt64, end: UInt64, chunk: Int) {
        self.source = source
        self.next = min(start, end)
        self.end = end
        self.chunk = chunk
    }

    /// What is left to read of the stretch.
    var remaining: UInt64 { UInt64(buffer.count - cursor) + (end - next) }

    mutating func take(_ count: Int) throws(IndexError) -> ArraySlice<UInt8> {
        guard count >= 0, UInt64(count) <= remaining else { throw .damaged }
        if buffer.count - cursor < count {
            let kept = Array(buffer[cursor...])
            let wanted = max(count - kept.count, chunk)
            let more = try source.bytes(at: next, count: Int(min(UInt64(wanted), end - next)))
            next += UInt64(more.count)
            buffer = kept + more
            cursor = 0
            guard buffer.count >= count else { throw .damaged }
        }
        defer { cursor += count }
        return buffer[cursor..<(cursor + count)]
    }

    mutating func skip(_ count: Int) throws(IndexError) {
        _ = try take(count)
    }
}
