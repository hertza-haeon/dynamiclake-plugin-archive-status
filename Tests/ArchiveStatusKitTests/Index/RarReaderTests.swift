// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

/// The two RAR formats, written by the same test wherever they should
/// behave alike.
enum RarKind: String, CaseIterable, CustomTestStringConvertible {
    case old
    case rar5

    var testDescription: String { rawValue }

    var format: ArchiveFormat { self == .old ? .rar4 : .rar5 }

    func make(_ items: [RarItem], options: RarOptions = RarOptions()) -> [UInt8] {
        self == .old ? makeRar4(items, options: options) : makeRar5(items, options: options)
    }
}

struct RarReaderTests {
    let scratch: ScratchFolder

    init() throws {
        scratch = try ScratchFolder()
    }

    @Test(arguments: RarKind.allCases)
    func itemsComeInOrderWithTheirSizes(kind: RarKind) throws {
        let path = try scratch.write(kind.make([
            RarItem("readme.txt", size: 12, data: Array("hello, world".utf8)),
            .folder("data"),
            RarItem("data/first.bin", size: 4, data: [1, 2, 3, 4]),
            RarItem("data/sub/second.bin", size: 0),
        ]), as: "test.rar")
        let index = try ArchiveIndex.read(at: path)
        #expect(index.format == kind.format)
        #expect(index.entries == [
            ArchiveEntry(path: "readme.txt", size: 12),
            ArchiveEntry(path: "data", size: 0, isFolder: true),
            ArchiveEntry(path: "data/first.bin", size: 4),
            ArchiveEntry(path: "data/sub/second.bin", size: 0),
        ])
        #expect(index.totalSize == 16)
        #expect(index.fileCount == 3)
        #expect(index.isWhole)
        #expect(index.parts == [path])
    }

    @Test(arguments: RarKind.allCases)
    func aFileOverFourGigabytesKeepsItsRealSize(kind: RarKind) throws {
        // (The header announces the size; the data needn't be there for the index.)
        let path = try scratch.write(kind.make([RarItem("game.nsp", size: 17_150_648_656)]), as: "big.rar")
        let index = try ArchiveIndex.read(at: path)
        #expect(index.entries == [ArchiveEntry(path: "game.nsp", size: 17_150_648_656)])
    }

    @Test(arguments: RarKind.allCases)
    func anEncryptedFileSaysItNeedsAPassword(kind: RarKind) throws {
        var secret = RarItem("secret.txt", size: 40)
        secret.needsPassword = true
        let path = try scratch.write(kind.make([RarItem("open.txt", size: 4), secret]), as: "protected.rar")
        let index = try ArchiveIndex.read(at: path)
        #expect(index.needsPassword)
        #expect(index.entries.map(\.path) == ["open.txt", "secret.txt"])
    }

    @Test(arguments: RarKind.allCases)
    func anIndexThatIsItselfEncryptedIsLocked(kind: RarKind) throws {
        var options = RarOptions()
        options.lockedHeaders = true
        let path = try scratch.write(kind.make([RarItem("hidden.txt", size: 4)], options: options), as: "locked.rar")
        #expect(throws: IndexError.locked) {
            try ArchiveIndex.read(at: path)
        }
    }

    @Test func oldNamesWithBackslashesBecomePaths() throws {
        let path = try scratch.write(makeRar4([RarItem("Folder\\Sub\\file.txt", size: 3)]), as: "windows.rar")
        #expect(try ArchiveIndex.read(at: path).entries.map(\.path) == ["Folder/Sub/file.txt"])
    }

    @Test func anOldNameStoredTwiceIsReadInUnicode() throws {
        // "é中.txt": plain bytes, a zero, then the Unicode form packed
        // against them (one byte, one byte, two bytes, then four copied).
        var item = RarItem("", size: 1)
        item.name = Array("__.txt".utf8) + [0x00] + [0x00, 0b0010_1100, 0xE9, 0x2D, 0x4E, 0x02]
        item.unicodeFlag = true
        let path = try scratch.write(makeRar4([item]), as: "unicode.rar")
        #expect(try ArchiveIndex.read(at: path).entries.map(\.path) == ["é中.txt"])
    }

    @Test func theUnicodeFormOfAnOldNameIsUnpacked() {
        // High byte 0x04 (Cyrillic): "Привет" as six low bytes with the high byte.
        let low: [UInt8] = [0x1F, 0x40, 0x38, 0x32, 0x35, 0x42]
        let packed: [UInt8] = [0x04, 0b0101_0101, low[0], low[1], low[2], low[3], 0b0101_0000, low[4], low[5]]
        let bytes = Array("______".utf8) + [0x00] + packed
        #expect(RarReader.unicodeName4(bytes[...]) == "Привет")
        // No second form: the name is plain UTF-8.
        #expect(RarReader.unicodeName4(Array("plain.txt".utf8)[...]) == "plain.txt")
        // A second form that is cut short gives what it has, without crashing.
        #expect(RarReader.unicodeName4((Array("ab".utf8) + [0x00, 0x00, 0b1000_0000, 0x41])[...]) == "")
    }

    // MARK: Several parts

    /// A two-file archive in three parts: the big file runs through all
    /// three, the small one is in the last.
    private func writeParts(_ kind: RarKind, names: [String], leaveOut: Int? = nil) throws -> [String] {
        var first = RarItem("big.bin", size: 9, data: [1, 2, 3])
        first.continuesAfter = true
        var middle = RarItem("big.bin", size: 9, data: [4, 5, 6])
        middle.continuesFromBefore = true
        middle.continuesAfter = true
        var last = RarItem("big.bin", size: 9, data: [7, 8, 9])
        last.continuesFromBefore = true
        let small = RarItem("small.txt", size: 2, data: [0x6F, 0x6B])

        var more = RarOptions()
        more.isVolume = true
        more.moreParts = true
        var final = RarOptions()
        final.isVolume = true
        let contents = [kind.make([first], options: more), kind.make([middle], options: more),
                        kind.make([last, small], options: final)]
        var paths: [String] = []
        for (number, name) in names.enumerated() where number != leaveOut {
            paths.append(try scratch.write(contents[number], as: name))
        }
        return paths
    }

    @Test(arguments: RarKind.allCases)
    func aMultiPartArchiveIsOneArchive(kind: RarKind) throws {
        let parts = try writeParts(kind, names: ["set.part1.rar", "set.part2.rar", "set.part3.rar"])
        let index = try ArchiveIndex.read(at: parts[0])
        // The file that runs through the parts is counted once, whole.
        #expect(index.entries == [ArchiveEntry(path: "big.bin", size: 9), ArchiveEntry(path: "small.txt", size: 2)])
        #expect(index.parts == parts)
        #expect(index.isWhole)
    }

    @Test(arguments: RarKind.allCases)
    func anyPartGivesTheSameIndex(kind: RarKind) throws {
        let parts = try writeParts(kind, names: ["set.part01.rar", "set.part02.rar", "set.part03.rar"])
        let fromFirst = try ArchiveIndex.read(at: parts[0])
        #expect(try ArchiveIndex.read(at: parts[1]) == fromFirst)
        #expect(try ArchiveIndex.read(at: parts[2]) == fromFirst)
    }

    @Test func theOlderNamesOfPartsAreFollowed() throws {
        let parts = try writeParts(.old, names: ["set.rar", "set.r00", "set.r01"])
        let index = try ArchiveIndex.read(at: parts[2])
        #expect(index.entries.map(\.path) == ["big.bin", "small.txt"])
        #expect(index.parts == parts)
        #expect(index.isWhole)
    }

    @Test(arguments: RarKind.allCases)
    func aMissingPartLeavesTheIndexShort(kind: RarKind) throws {
        let parts = try writeParts(kind, names: ["set.part1.rar", "set.part2.rar", "set.part3.rar"], leaveOut: 2)
        let index = try ArchiveIndex.read(at: parts[0])
        // The big file is announced whole by the first part; the small one
        // is listed in the part that is missing.
        #expect(index.entries == [ArchiveEntry(path: "big.bin", size: 9)])
        #expect(index.parts == parts)
        #expect(index.isWhole == false)
    }

    @Test(arguments: RarKind.allCases)
    func withoutItsFirstPartTheIndexIsShort(kind: RarKind) throws {
        let parts = try writeParts(kind, names: ["set.part1.rar", "set.part2.rar", "set.part3.rar"], leaveOut: 0)
        let index = try ArchiveIndex.read(at: parts[0])
        #expect(index.isWhole == false)
        #expect(index.entries.map(\.path) == ["small.txt"])
    }

    @Test func oldPartsWithoutAnEndRecordAreFollowedByTheirLastFile() throws {
        var first = RarItem("big.bin", size: 6, data: [1, 2, 3])
        first.continuesAfter = true
        var last = RarItem("big.bin", size: 6, data: [4, 5, 6])
        last.continuesFromBefore = true
        var options = RarOptions()
        options.isVolume = true
        options.withoutEnd = true
        let one = try scratch.write(makeRar4([first], options: options), as: "old.part1.rar")
        let two = try scratch.write(makeRar4([last, RarItem("tail.txt", size: 1, data: [0x21])], options: options),
                                    as: "old.part2.rar")
        let index = try ArchiveIndex.read(at: one)
        #expect(index.entries.map(\.path) == ["big.bin", "tail.txt"])
        #expect(index.parts == [one, two])
    }

    @Test(arguments: [
        ("/d/set.part1.rar", "/d/set.part1.rar"),
        ("/d/set.part7.rar", "/d/set.part1.rar"),
        ("/d/set.part012.rar", "/d/set.part001.rar"),
        ("/d/Set.PART03.RAR", "/d/Set.PART01.RAR"),
        ("/d/set.r00", "/d/set.rar"),
        ("/d/set.s14", "/d/set.rar"),
        ("/d/set.rar", "/d/set.rar"),
        ("/d/plain.zip", "/d/plain.zip"),
        ("/d/my.part2.notes.rar", "/d/my.part2.notes.rar"),
        ("set.part2.rar", "set.part1.rar"),
    ])
    func theFirstPartIsKnownByItsName(path: String, first: String) {
        #expect(RarVolumeName.firstPart(of: path) == first)
    }

    @Test(arguments: [
        ("/d/set.part1.rar", "/d/set.part2.rar"),
        ("/d/set.part09.rar", "/d/set.part10.rar"),
        ("/d/set.part99.rar", "/d/set.part100.rar"),
        ("/d/set.rar", "/d/set.r00"),
        ("/d/set.r00", "/d/set.r01"),
        ("/d/set.r99", "/d/set.s00"),
        ("/d/set.z99", nil),
        ("/d/set.zip", nil),
    ] as [(String, String?)])
    func theNextPartIsKnownByItsName(path: String, next: String?) {
        #expect(RarVolumeName.nextPart(after: path) == next)
    }

    // MARK: Damaged archives

    @Test(.tags(.damagedInput), arguments: RarKind.allCases)
    func aRarCutAnywhereIsHandled(kind: RarKind) throws {
        var secret = RarItem("dir/secret.txt", size: 5_000_000_000, data: [9, 9, 9])
        secret.needsPassword = true
        let whole = kind.make([RarItem("a.txt", size: 3, data: [1, 2, 3]), .folder("dir"), secret])
        for length in 0..<whole.count {
            let path = try scratch.write(Array(whole.prefix(length)), as: "cut.rar")
            _ = try? ArchiveIndex.read(at: path)
        }
    }

    @Test(.tags(.damagedInput), arguments: RarKind.allCases, [UInt8(0x00), 0xFF, 0x80])
    func aRarWithAnyByteWrongIsHandled(kind: RarKind, wrong: UInt8) throws {
        var secret = RarItem("dir/secret.txt", size: 5_000_000_000, data: [9, 9, 9])
        secret.needsPassword = true
        let whole = kind.make([RarItem("a.txt", size: 3, data: [1, 2, 3]), .folder("dir"), secret])
        for position in 0..<whole.count {
            var garbled = whole
            garbled[position] = wrong
            let path = try scratch.write(garbled, as: "garbled-\(kind.rawValue)-\(wrong).rar")
            _ = try? ArchiveIndex.read(at: path)
        }
    }

    @Test func aCutPartIsNotWhole() throws {
        let whole = makeRar5([RarItem("a.txt", size: 3, data: [1, 2, 3]), RarItem("b.txt", size: 3, data: [4, 5, 6])])
        // Cut inside the second file's data: the first is listed, the end is missing.
        let path = try scratch.write(Array(whole.prefix(whole.count - 9)), as: "cut.rar")
        let index = try ArchiveIndex.read(at: path)
        #expect(index.entries.first == ArchiveEntry(path: "a.txt", size: 3))
        #expect(index.isWhole == false)
    }

    // MARK: Against macOS's own reader

    /// macOS's `bsdtar` (libarchive, written by others) reads the hand-made
    /// archives and lists what this plugin's reader lists: the builders
    /// write real archives, and the reader reads them as an independent one
    /// does. It also extracts them, which checks every checksum.
    @Test(.tags(.systemTools), arguments: RarKind.allCases)
    func macOSsOwnReaderAgreesOnAHandMadeRar(kind: RarKind) throws {
        var items: [RarItem] = [.folder("made up")]
        var expected: [String: UInt64] = [:]
        for number in 1...40 {
            let data = [UInt8](repeating: UInt8(number), count: number * 37)
            items.append(RarItem("made up/file \(number).bin", size: UInt64(data.count), data: data))
            expected["made up/file \(number).bin"] = UInt64(data.count)
        }
        let path = try scratch.write(kind.make(items), as: "hand-made.rar")

        let index = try ArchiveIndex.read(at: path)
        let listed = Dictionary(uniqueKeysWithValues: index.entries.filter { $0.isFolder == false }.map { ($0.path, $0.size) })
        #expect(listed == expected)

        let listing = try bsdtar(["-tf", path])
        try #require(listing.status == 0, "bsdtar refused the hand-made archive: \(listing.errors)")
        let names = listing.output.split(separator: "\n").map { $0.hasSuffix("/") ? String($0.dropLast()) : String($0) }
        #expect(names == index.entries.map(\.path))

        let out = scratch.path + "/extracted"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let extraction = try bsdtar(["-xf", path, "-C", out])
        #expect(extraction.status == 0, "bsdtar couldn't extract the hand-made archive: \(extraction.errors)")
        for (name, size) in expected {
            let attributes = try FileManager.default.attributesOfItem(atPath: out + "/" + name)
            #expect(attributes[.size] as? UInt64 == size)
        }
    }

    private func bsdtar(_ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let complaints = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text, complaints)
    }
}
