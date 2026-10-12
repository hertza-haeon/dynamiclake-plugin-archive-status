// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Reads a RAR's index, in the old format (up to RAR 4) and the new (RAR5).
///
/// A RAR has no index in one place: each item is announced by a header just
/// before its data. The headers are read and the data stepped over, so
/// nothing is decompressed. A multi-part archive is walked part by part.
enum RarReader {
    static let signature4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    static let signature5: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

    /// The most parts of one archive that are walked.
    private static let maxParts = 1_000
    /// How much is read at a header's place before its length is known.
    private static let probe = 512
    /// The longest header that is read.
    private static let maxHeader = 2 * 1024 * 1024

    /// What one part told, beyond its items.
    private struct PartSummary {
        var format: ArchiveFormat
        /// The archive goes on in another part.
        var continues = false
        /// The part ended where its format says it should.
        var endedCleanly = true
    }

    static func read(anyPart path: String) throws(IndexError) -> ArchiveIndex {
        var entries: [ArchiveEntry] = []
        var needsPassword = false
        var parts: [String] = []
        var isWhole = true
        var format: ArchiveFormat?

        // Start from the first part when it is there; else from the one given.
        var first = RarVolumeName.firstPart(of: path)
        if first != path, FileManager.default.fileExists(atPath: first) == false {
            first = path
            isWhole = false
        }

        var current: String? = first
        while let part = current, parts.count < maxParts {
            let summary: PartSummary
            do {
                summary = try readPart(part, into: &entries, needsPassword: &needsPassword)
            } catch {
                // The first part decides; a later one that can't be read
                // only leaves the index short.
                if parts.isEmpty { throw error }
                isWhole = false
                break
            }
            parts.append(part)
            format = format ?? summary.format
            if summary.endedCleanly == false { isWhole = false }
            guard summary.continues else { break }
            guard let next = RarVolumeName.nextPart(after: part),
                  FileManager.default.fileExists(atPath: next) else {
                isWhole = false
                break
            }
            current = next
        }
        guard let format else { throw .notAnArchive }
        return ArchiveIndex(format: format, entries: entries, parts: parts,
                            needsPassword: needsPassword, isWhole: isWhole)
    }

    private static func readPart(_ path: String, into entries: inout [ArchiveEntry],
                                 needsPassword: inout Bool) throws(IndexError) -> PartSummary {
        let source = try FileSource(path: path)
        let head = try source.bytes(at: 0, upTo: 8)
        if head.starts(with: signature5) {
            return try readPart5(source, into: &entries, needsPassword: &needsPassword)
        }
        if head.starts(with: signature4) {
            return try readPart4(source, into: &entries, needsPassword: &needsPassword)
        }
        throw .notAnArchive
    }

    // MARK: The old format

    private static func readPart4(_ source: FileSource, into entries: inout [ArchiveEntry],
                                  needsPassword: inout Bool) throws(IndexError) -> PartSummary {
        var summary = PartSummary(format: .rar4)
        var isVolume = false
        var lastFileContinues = false
        var sawEnd = false
        var offset = UInt64(signature4.count)

        while offset < source.size {
            guard source.size - offset >= 7 else {
                summary.endedCleanly = false
                break
            }
            var header = try source.bytes(at: offset, upTo: probe)
            var cursor = ByteCursor(header)
            try cursor.skip(2)                           // checksum
            let type = try cursor.u8()
            let flags = try cursor.u16()
            let headerSize = Int(try cursor.u16())
            guard headerSize >= 7 else {
                summary.endedCleanly = false
                break
            }
            if headerSize > header.count {
                header = try source.bytes(at: offset, count: headerSize)
            }
            cursor = ByteCursor(header[..<headerSize])
            try cursor.skip(7)

            // What follows the header and is stepped over: an item's data.
            var dataSize: UInt64 = 0
            switch type {
            case 0x73:                                   // the archive's own header
                // Its headers are encrypted: nothing more can be read.
                if flags & 0x0080 != 0 { throw .locked }
                isVolume = flags & 0x0001 != 0
            case 0x74, 0x7A:                             // a file; a service record laid out the same
                let packedLow = UInt64(try cursor.u32())
                let sizeLow = UInt64(try cursor.u32())
                try cursor.skip(1 + 4 + 4 + 1 + 1)       // system, checksum, date, version, method
                let nameLength = Int(try cursor.u16())
                try cursor.skip(4)                       // attributes
                var packedHigh: UInt64 = 0
                var sizeHigh: UInt64 = 0
                if flags & 0x0100 != 0 {                 // over 4 GB
                    packedHigh = UInt64(try cursor.u32())
                    sizeHigh = UInt64(try cursor.u32())
                }
                let nameBytes = try cursor.take(nameLength)
                dataSize = packedLow | packedHigh << 32
                if type == 0x74 {
                    lastFileContinues = flags & 0x0002 != 0
                    // The rest of a file begun in the part before: already counted.
                    if flags & 0x0001 == 0 {
                        let name = flags & 0x0200 != 0 ? unicodeName4(nameBytes) : decodedName(nameBytes)
                        let path = cleanedPath(name, backslashIsSeparator: true)
                        let isFolder = flags & 0x00E0 == 0x00E0
                        if path.isEmpty == false {
                            guard entries.count < ArchiveIndex.maxEntries else { throw .tooLarge }
                            entries.append(ArchiveEntry(path: path, size: isFolder ? 0 : sizeLow | sizeHigh << 32,
                                                        isFolder: isFolder))
                            if flags & 0x0004 != 0, isFolder == false {
                                needsPassword = true
                            }
                        }
                    }
                }
            case 0x7B:                                   // the end of this part
                sawEnd = true
                summary.continues = flags & 0x0001 != 0
            default:
                if flags & 0x8000 != 0 {
                    dataSize = UInt64(try cursor.u32())
                }
            }
            if sawEnd { break }

            let (step, overflowed) = UInt64(headerSize).addingReportingOverflow(dataSize)
            guard overflowed == false, step <= source.size - offset else {
                // The data runs past the end of the file: the part is cut short.
                summary.endedCleanly = false
                break
            }
            offset += step
        }
        // Parts made by old versions have no end record: the last file says
        // whether it goes on.
        if sawEnd == false, isVolume, lastFileContinues {
            summary.continues = true
        }
        return summary
    }

    /// A name of the old format when it is stored twice: plain, then a zero
    /// byte, then the same in Unicode, packed against the plain one.
    static func unicodeName4(_ bytes: ArraySlice<UInt8>) -> String {
        guard let zero = bytes.firstIndex(of: 0) else {
            return decodedName(bytes)                    // (no second form: the name is UTF-8)
        }
        let plain = Array(bytes[..<zero])
        let packed = Array(bytes[(zero + 1)...])
        guard packed.isEmpty == false else { return decodedName(plain[...]) }

        var units: [UInt16] = []
        var position = 0
        let high = UInt16(packed[position])
        position += 1
        var flags: UInt8 = 0
        var flagBits = 0
        let limit = 4_096
        while position < packed.count, units.count < limit {
            if flagBits == 0 {
                flags = packed[position]
                position += 1
                flagBits = 8
                if position >= packed.count { break }
            }
            switch flags >> 6 {
            case 0:
                units.append(UInt16(packed[position]))
                position += 1
            case 1:
                units.append(UInt16(packed[position]) | high << 8)
                position += 1
            case 2:
                guard position + 1 < packed.count else { return String(decoding: units, as: UTF16.self) }
                units.append(UInt16(packed[position]) | UInt16(packed[position + 1]) << 8)
                position += 2
            default:
                var length = Int(packed[position])
                position += 1
                if length & 0x80 != 0 {
                    guard position < packed.count else { return String(decoding: units, as: UTF16.self) }
                    let correction = packed[position]
                    position += 1
                    length = (length & 0x7F) + 2
                    while length > 0, units.count < plain.count, units.count < limit {
                        units.append(UInt16(plain[units.count] &+ correction) | high << 8)
                        length -= 1
                    }
                } else {
                    length += 2
                    while length > 0, units.count < plain.count, units.count < limit {
                        units.append(UInt16(plain[units.count]))
                        length -= 1
                    }
                }
            }
            flags <<= 2
            flagBits -= 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: RAR5

    private static func readPart5(_ source: FileSource, into entries: inout [ArchiveEntry],
                                  needsPassword: inout Bool) throws(IndexError) -> PartSummary {
        var summary = PartSummary(format: .rar5)
        var sawEnd = false
        var offset = UInt64(signature5.count)

        while offset < source.size {
            var block = try source.bytes(at: offset, upTo: probe)
            var cursor = ByteCursor(block)
            guard (try? cursor.skip(4)) != nil, let headerSize64 = try? cursor.vint() else {
                summary.endedCleanly = false
                break
            }
            // The header's length counts what follows the length itself.
            let prefix = cursor.offset
            guard headerSize64 > 0, headerSize64 <= UInt64(maxHeader) else {
                summary.endedCleanly = false
                break
            }
            let headerSize = Int(headerSize64)
            if prefix + headerSize > block.count {
                block = try source.bytes(at: offset, count: prefix + headerSize)
            }
            cursor = ByteCursor(block[prefix..<(prefix + headerSize)])

            let type = try cursor.vint()
            let flags = try cursor.vint()
            var extraSize: UInt64 = 0
            var dataSize: UInt64 = 0
            if flags & 0x0001 != 0 { extraSize = try cursor.vint() }
            if flags & 0x0002 != 0 { dataSize = try cursor.vint() }

            switch type {
            case 2:                                      // a file or a folder
                let fileFlags = try cursor.vint()
                let size = try cursor.vint()
                _ = try cursor.vint()                    // attributes
                if fileFlags & 0x0002 != 0 { try cursor.skip(4) }    // date
                if fileFlags & 0x0004 != 0 { try cursor.skip(4) }    // checksum
                _ = try cursor.vint()                    // compression
                _ = try cursor.vint()                    // system
                let nameLength = try cursor.vint()
                guard nameLength <= UInt64(headerSize) else { throw .damaged }
                let nameBytes = try cursor.take(Int(nameLength))
                // The rest of a file begun in the part before: already counted.
                if flags & 0x0008 == 0 {
                    let path = cleanedPath(decodedName(nameBytes))
                    let isFolder = fileFlags & 0x0001 != 0
                    if path.isEmpty == false {
                        guard entries.count < ArchiveIndex.maxEntries else { throw .tooLarge }
                        entries.append(ArchiveEntry(path: path, size: isFolder ? 0 : size, isFolder: isFolder))
                        if isFolder == false, extraSize > 0, extraSize <= UInt64(cursor.remaining),
                           hasEncryptionRecord(block[(prefix + headerSize - Int(extraSize))..<(prefix + headerSize)]) {
                            needsPassword = true
                        }
                    }
                }
            case 4:                                      // every header that follows is encrypted
                throw .locked
            case 5:                                      // the end of this part
                sawEnd = true
                let endFlags = try cursor.vint()
                summary.continues = endFlags & 0x0001 != 0
            default:                                     // the archive's own header, service records
                break
            }
            if sawEnd { break }

            let step = UInt64(prefix + headerSize).addingSaturating(dataSize)
            guard step <= source.size - offset else {
                summary.endedCleanly = false
                break
            }
            offset += step
        }
        if sawEnd == false { summary.endedCleanly = false }
        return summary
    }

    /// Whether the extra records of a file's header include the one that
    /// says the file is encrypted.
    private static func hasEncryptionRecord(_ extra: ArraySlice<UInt8>) -> Bool {
        var cursor = ByteCursor(extra)
        while cursor.remaining > 0 {
            guard let size = try? cursor.vint(), size > 0, size <= UInt64(cursor.remaining) else { return false }
            let start = cursor.offset
            guard let type = try? cursor.vint() else { return false }
            if type == 0x01 { return true }
            let used = cursor.offset - start
            guard (try? cursor.skip(Int(size) - used)) != nil else { return false }
        }
        return false
    }
}

/// The names of the parts of a multi-part RAR: `name.part1.rar`,
/// `name.part2.rar`… or, the older way, `name.rar`, `name.r00`, `name.r01`…
enum RarVolumeName {
    /// The first part of the set `path` belongs to, going by its name alone.
    static func firstPart(of path: String) -> String {
        let (folder, name) = split(path)
        if let match = name.wholeMatch(of: #/(?i)(.*\.part)(\d+)(\.rar)/#) {
            return folder + String(match.1) + padded(1, to: match.2.count) + String(match.3)
        }
        if let match = name.wholeMatch(of: #/(?i)(.*)\.[r-z]\d\d/#) {
            return folder + String(match.1) + ".rar"
        }
        return path
    }

    /// The part that follows `path`, going by its name alone.
    static func nextPart(after path: String) -> String? {
        let (folder, name) = split(path)
        if let match = name.wholeMatch(of: #/(?i)(.*\.part)(\d+)(\.rar)/#) {
            guard let number = Int(match.2), number < 99_999 else { return nil }
            return folder + String(match.1) + padded(number + 1, to: match.2.count) + String(match.3)
        }
        if let match = name.wholeMatch(of: #/(?i)(.*)\.rar/#) {
            return folder + String(match.1) + ".r00"
        }
        if let match = name.wholeMatch(of: #/(?i)(.*)\.([r-z])(\d\d)/#) {
            guard let number = Int(match.3), let letter = match.2.unicodeScalars.first else { return nil }
            if number < 99 {
                return folder + String(match.1) + "." + String(match.2) + padded(number + 1, to: 2)
            }
            // .r99 is followed by .s00, and so on to .z99
            guard letter != "z", letter != "Z", let following = UnicodeScalar(letter.value + 1) else { return nil }
            return folder + String(match.1) + "." + String(Character(following)) + "00"
        }
        return nil
    }

    private static func split(_ path: String) -> (folder: String, name: Substring) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path[...]) }
        return (String(path[...slash]), path[path.index(after: slash)...])
    }

    private static func padded(_ number: Int, to width: Int) -> String {
        let text = String(number)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
