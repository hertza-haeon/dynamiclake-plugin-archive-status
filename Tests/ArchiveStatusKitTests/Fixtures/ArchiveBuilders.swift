// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Archives written by hand for the tests, byte by byte from the formats'
// published descriptions, so that each test decides exactly what its
// archive says. They hold made-up data only.

extension [UInt8] {
    mutating func le16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func le32(_ value: UInt32) {
        le16(UInt16(truncatingIfNeeded: value))
        le16(UInt16(truncatingIfNeeded: value >> 16))
    }

    mutating func le64(_ value: UInt64) {
        le32(UInt32(truncatingIfNeeded: value))
        le32(UInt32(truncatingIfNeeded: value >> 32))
    }

    /// A RAR5 number: seven bits a byte, the lowest first.
    mutating func vint(_ value: UInt64) {
        var rest = value
        repeat {
            let byte = UInt8(rest & 0x7F)
            rest >>= 7
            append(rest == 0 ? byte : byte | 0x80)
        } while rest != 0
    }
}

/// The checksum zip, RAR and gzip use.
func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return ~crc
}

/// What each byte does to the checksum, worked out once.
private let crcTable: [UInt32] = (0..<256).map { byte in
    var crc = UInt32(byte)
    for _ in 0..<8 {
        crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
    }
    return crc
}

// MARK: zip

struct ZipItem {
    var name: [UInt8]
    /// The size once extracted that the index announces.
    var size: UInt64
    /// Bit 0: encrypted. Bit 11: the name is UTF-8.
    var flags: UInt16 = 0x0800
    /// The system it was made on, in the upper byte: 3 is Unix (a Mac too).
    var madeBy: UInt16 = 0x031E
    var attributes: UInt32 = 0o100644 << 16
    var extra: [UInt8] = []

    init(_ name: String, size: UInt64) {
        self.name = Array(name.utf8)
        self.size = size
    }

    static func folder(_ name: String) -> ZipItem {
        var item = ZipItem(name.hasSuffix("/") ? name : name + "/", size: 0)
        item.attributes = 0o040755 << 16 | 0x10
        return item
    }

    static func link(_ name: String, to target: String) -> ZipItem {
        var item = ZipItem(name, size: UInt64(target.utf8.count))
        item.attributes = 0o120755 << 16
        return item
    }
}

struct ZipOptions {
    /// Bytes in front of the zip, as a self-extracting one has.
    var prefix: [UInt8] = []
    var comment: [UInt8] = []
    /// Write the end of the archive the zip64 way, as archives over 4 GB do.
    var zip64End = false
    /// The number of items the end record announces, when not the real one.
    var announcedCount: UInt64?
}

/// A zip that holds an index and nothing else: its items have no data. That
/// is all an index reader looks at.
func makeZip(_ items: [ZipItem], options: ZipOptions = ZipOptions()) -> [UInt8] {
    var bytes = options.prefix
    let directoryOffset = UInt64(bytes.count)
    for item in items {
        var extra = item.extra
        let needsZip64 = item.size >= 0xFFFF_FFFF
        if needsZip64 {
            extra.le16(0x0001)
            extra.le16(8)
            extra.le64(item.size)
        }
        bytes.le32(0x0201_4B50)
        bytes.le16(item.madeBy)
        bytes.le16(20)
        bytes.le16(item.flags)
        bytes.le16(0)                                  // method: stored
        bytes.le16(0)
        bytes.le16(0)
        bytes.le32(0)                                  // checksum
        bytes.le32(0)                                  // size in the archive
        bytes.le32(needsZip64 ? 0xFFFF_FFFF : UInt32(item.size))
        bytes.le16(UInt16(item.name.count))
        bytes.le16(UInt16(extra.count))
        bytes.le16(0)                                  // comment
        bytes.le16(0)                                  // disk
        bytes.le16(0)                                  // internal attributes
        bytes.le32(item.attributes)
        bytes.le32(0)                                  // place in the archive
        bytes += item.name
        bytes += extra
    }
    let directorySize = UInt64(bytes.count) - directoryOffset
    let count = options.announcedCount ?? UInt64(items.count)
    if options.zip64End {
        let recordOffset = UInt64(bytes.count)
        bytes.le32(0x0606_4B50)
        bytes.le64(44)
        bytes.le16(45)
        bytes.le16(45)
        bytes.le32(0)
        bytes.le32(0)
        bytes.le64(count)
        bytes.le64(count)
        bytes.le64(directorySize)
        bytes.le64(directoryOffset - UInt64(options.prefix.count))
        bytes.le32(0x0706_4B50)
        bytes.le32(0)
        bytes.le64(recordOffset)
        bytes.le32(1)
    }
    bytes.le32(0x0605_4B50)
    bytes.le16(0)
    bytes.le16(0)
    bytes.le16(options.zip64End ? 0xFFFF : UInt16(truncatingIfNeeded: count))
    bytes.le16(options.zip64End ? 0xFFFF : UInt16(truncatingIfNeeded: count))
    bytes.le32(options.zip64End ? 0xFFFF_FFFF : UInt32(directorySize))
    // (Written as if nothing stood in front, as real self-extracting zips are.)
    bytes.le32(options.zip64End ? 0xFFFF_FFFF : UInt32(directoryOffset - UInt64(options.prefix.count)))
    bytes.le16(UInt16(options.comment.count))
    bytes += options.comment
    return bytes
}

// MARK: RAR

struct RarItem {
    var name: [UInt8]
    /// The size once extracted that the header announces.
    var size: UInt64
    /// The item's data in this part.
    var data: [UInt8] = []
    var isFolder = false
    var needsPassword = false
    /// The rest of a file begun in the part before.
    var continuesFromBefore = false
    /// The file goes on in the next part.
    var continuesAfter = false
    /// Old format only: the name is stored twice, the second time in Unicode.
    var unicodeFlag = false

    init(_ name: String, size: UInt64, data: [UInt8] = []) {
        self.name = Array(name.utf8)
        self.size = size
        self.data = data
    }

    static func folder(_ name: String) -> RarItem {
        var item = RarItem(name, size: 0)
        item.isFolder = true
        return item
    }
}

struct RarOptions {
    /// This file is one part of several.
    var isVolume = false
    /// Another part follows.
    var moreParts = false
    /// The headers themselves are encrypted.
    var lockedHeaders = false
    /// Old format only: leave out the record that ends a part.
    var withoutEnd = false
}

/// A RAR in the old format (up to RAR 4), its checksums right.
func makeRar4(_ items: [RarItem], options: RarOptions = RarOptions()) -> [UInt8] {
    func block(type: UInt8, flags: UInt16, body: [UInt8]) -> [UInt8] {
        var rest: [UInt8] = [type]
        rest.le16(flags)
        rest.le16(UInt16(7 + body.count))
        rest += body
        var bytes: [UInt8] = []
        bytes.le16(UInt16(truncatingIfNeeded: crc32(rest)))
        return bytes + rest
    }

    var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    var mainFlags: UInt16 = 0
    if options.isVolume { mainFlags |= 0x0001 | 0x0010 }
    if options.lockedHeaders { mainFlags |= 0x0080 }
    bytes += block(type: 0x73, flags: mainFlags, body: [UInt8](repeating: 0, count: 6))
    for item in items {
        var flags: UInt16 = 0x8000
        if item.continuesFromBefore { flags |= 0x0001 }
        if item.continuesAfter { flags |= 0x0002 }
        if item.needsPassword { flags |= 0x0004 }
        if item.isFolder { flags |= 0x00E0 }
        if item.unicodeFlag { flags |= 0x0200 }
        let large = item.size > 0xFFFF_FFFF
        if large { flags |= 0x0100 }
        var body: [UInt8] = []
        body.le32(UInt32(item.data.count))
        body.le32(UInt32(truncatingIfNeeded: item.size))
        body.append(3)                                 // made on Unix
        body.le32(crc32(item.data))
        body.le32(0x5A21_0000)                         // a date
        body.append(29)
        body.append(0x30)                              // stored, not compressed
        body.le16(UInt16(item.name.count))
        body.le32(item.isFolder ? 0o040755 : 0o100644)
        if large {
            body.le32(0)
            body.le32(UInt32(truncatingIfNeeded: item.size >> 32))
        }
        body += item.name
        bytes += block(type: 0x74, flags: flags, body: body)
        bytes += item.data
    }
    if options.withoutEnd == false {
        bytes += block(type: 0x7B, flags: 0x4000 | (options.moreParts ? 0x0001 : 0), body: [])
    }
    return bytes
}

/// A RAR in the new format (RAR5), its checksums right.
func makeRar5(_ items: [RarItem], options: RarOptions = RarOptions()) -> [UInt8] {
    func block(type: UInt64, flags: UInt64, dataSize: UInt64? = nil, extra: [UInt8] = [], body: [UInt8]) -> [UInt8] {
        var header: [UInt8] = []
        header.vint(type)
        header.vint(flags | (extra.isEmpty ? 0 : 0x0001) | (dataSize == nil ? 0 : 0x0002))
        if extra.isEmpty == false { header.vint(UInt64(extra.count)) }
        if let dataSize { header.vint(dataSize) }
        header += body
        header += extra
        var sized: [UInt8] = []
        sized.vint(UInt64(header.count))
        sized += header
        var bytes: [UInt8] = []
        bytes.le32(crc32(sized))
        return bytes + sized
    }

    var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
    if options.lockedHeaders {
        // The record that says every header after it is encrypted.
        var body: [UInt8] = []
        body.vint(0)
        body.vint(0)
        body.append(15)
        body += [UInt8](repeating: 0xAB, count: 16)
        bytes += block(type: 4, flags: 0, body: body)
        return bytes + [UInt8](repeating: 0x5C, count: 64)
    }
    var main: [UInt8] = []
    main.vint(options.isVolume ? 0x0001 : 0)
    bytes += block(type: 1, flags: 0, body: main)
    for item in items {
        var body: [UInt8] = []
        body.vint(item.isFolder ? 0x0001 : 0)
        body.vint(item.size)
        body.vint(item.isFolder ? 0o040755 : 0o100644)
        body.vint(0)                                   // stored, not compressed
        body.vint(1)                                   // made on Unix
        body.vint(UInt64(item.name.count))
        body += item.name
        var extra: [UInt8] = []
        if item.needsPassword {
            // The record that says this file is encrypted.
            var record: [UInt8] = []
            record.vint(0x01)
            record.vint(0)
            record.vint(0)
            record.append(15)
            record += [UInt8](repeating: 0xCD, count: 32)
            extra.vint(UInt64(record.count))
            extra += record
        }
        var flags: UInt64 = 0
        if item.continuesFromBefore { flags |= 0x0008 }
        if item.continuesAfter { flags |= 0x0010 }
        bytes += block(type: 2, flags: flags, dataSize: UInt64(item.data.count), extra: extra, body: body)
        bytes += item.data
    }
    var end: [UInt8] = []
    end.vint(options.moreParts ? 0x0001 : 0)
    bytes += block(type: 5, flags: 0, body: end)
    return bytes
}

// MARK: A folder for one test

// MARK: tar

/// One header of a tar, and the data after it.
struct TarItem {
    var name: [UInt8]
    /// The size its header announces.
    var size: UInt64
    /// What it is: `0` a file, `5` a folder, `2` a link, `x` and `L` say
    /// something of the item that follows.
    var kind: UInt8 = UInt8(ascii: "0")
    /// The start of a long path, in the standard form's own field.
    var prefix: [UInt8] = []
    /// `ustar` and a zero (the standard form), or `ustar` and two spaces
    /// (GNU's).
    var magic: [UInt8] = Array("ustar".utf8) + [0, 0x30, 0x30]
    /// What follows the header; zeros of the announced size when nothing
    /// is given.
    var data: [UInt8]?
    /// The size written as a plain binary number, as GNU does past 8 GB.
    var sizeIsBinary = false
    /// What a link points to.
    var linkTarget: [UInt8] = []

    init(_ name: String, size: UInt64) {
        self.name = Array(name.utf8)
        self.size = size
    }

    static func folder(_ name: String) -> TarItem {
        var item = TarItem(name.hasSuffix("/") ? name : name + "/", size: 0)
        item.kind = UInt8(ascii: "5")
        return item
    }

    static func link(_ name: String) -> TarItem {
        var item = TarItem(name, size: 0)
        item.kind = UInt8(ascii: "2")
        return item
    }

    /// An extended header: says the path and the size of the item after it.
    static func extended(path: String? = nil, size: UInt64? = nil, others: [String] = []) -> TarItem {
        var records: [UInt8] = []
        for others in others {
            records += tarRecord(others)
        }
        if let path { records += tarRecord("path=\(path)") }
        if let size { records += tarRecord("size=\(size)") }
        var item = TarItem("PaxHeader/item", size: UInt64(records.count))
        item.kind = UInt8(ascii: "x")
        item.data = records
        return item
    }

    /// GNU's way of giving the next item a long name.
    static func longName(_ name: String) -> TarItem {
        let data = Array(name.utf8) + [0]
        var item = TarItem("././@LongLink", size: UInt64(data.count))
        item.kind = UInt8(ascii: "L")
        item.magic = Array("ustar  ".utf8) + [0]
        item.data = data
        return item
    }
}

/// One record of an extended header: its own length, a space, `key=value`
/// and a line end.
func tarRecord(_ body: String) -> [UInt8] {
    let rest = " \(body)\n".utf8.count
    var length = rest + 1
    while "\(length)".utf8.count + rest != length {
        length = "\(length)".utf8.count + rest
    }
    return Array("\(length) \(body)\n".utf8)
}

/// The 512 bytes of a tar header.
func tarHeader(_ item: TarItem) -> [UInt8] {
    var header = [UInt8](repeating: 0, count: 512)
    func put(_ bytes: [UInt8], at place: Int, length: Int) {
        header.replaceSubrange(place..<place + min(bytes.count, length), with: bytes.prefix(length))
    }
    func octal(_ value: UInt64, digits: Int) -> [UInt8] {
        let text = String(value, radix: 8)
        return Array((String(repeating: "0", count: max(0, digits - text.count)) + text).utf8)
    }
    put(item.name, at: 0, length: 100)
    put(octal(0o644, digits: 7), at: 100, length: 8)
    put(octal(0, digits: 7), at: 108, length: 8)
    put(octal(0, digits: 7), at: 116, length: 8)
    if item.sizeIsBinary {
        var field: [UInt8] = [0x80, 0, 0, 0]
        for shift in stride(from: 56, through: 0, by: -8) {
            field.append(UInt8(truncatingIfNeeded: item.size >> UInt64(shift)))
        }
        put(field, at: 124, length: 12)
    } else {
        put(octal(item.size, digits: 11), at: 124, length: 12)
    }
    put(octal(0, digits: 11), at: 136, length: 12)
    header[156] = item.kind
    put(item.linkTarget, at: 157, length: 100)
    put(item.magic, at: 257, length: 8)
    put(item.prefix, at: 345, length: 155)
    // What the header adds up to, its own figure counted as spaces.
    put([UInt8](repeating: 0x20, count: 8), at: 148, length: 8)
    let sum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
    put(octal(sum, digits: 6) + [0, 0x20], at: 148, length: 8)
    return header
}

/// A tar: each item's header, its data filled up to whole blocks, and the
/// two empty blocks of the end. `dataWritten` false leaves the data of
/// plain files out, for a tar that says more than it holds.
func makeTar(_ items: [TarItem], withEnd: Bool = true) -> [UInt8] {
    var bytes: [UInt8] = []
    for item in items {
        bytes += tarHeader(item)
        let isPlain = item.kind == UInt8(ascii: "0") || item.kind == 0
        let data = item.data ?? [UInt8](repeating: 0x41, count: isPlain ? Int(item.size) : 0)
        bytes += data
        bytes += [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
    }
    if withEnd {
        bytes += [UInt8](repeating: 0, count: 1024)
    }
    return bytes
}

/// A gzip file holding `bytes`, written by hand: the data is kept as it
/// is, in the blocks gzip has for data it doesn't compress.
func makeGzip(_ bytes: [UInt8]) -> [UInt8] {
    // The signature, "deflate", no extras, no date, made on Unix.
    var gzip: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]
    var rest = bytes[...]
    repeat {
        let piece = rest.prefix(0xFFFF)
        rest = rest.dropFirst(piece.count)
        gzip.append(rest.isEmpty ? 0x01 : 0x00)         // the last block says so
        gzip.le16(UInt16(piece.count))
        gzip.le16(~UInt16(piece.count))
        gzip += piece
    } while rest.isEmpty == false
    gzip.le32(crc32(bytes))
    gzip.le32(UInt32(truncatingIfNeeded: bytes.count))
    return gzip
}

/// A folder of its own for one test, removed when the test is over.
final class ScratchFolder {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "ArchiveStatusTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Writes a file into the folder and returns its path.
    @discardableResult
    func write(_ bytes: [UInt8], as name: String) throws -> String {
        let file = path + "/" + name
        let folder = (file as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data(bytes).write(to: URL(filePath: file))
        return file
    }
}
