// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

extension Tag {
    /// Tests that run a program of macOS's own (`zip`, `ditto`, `bsdtar`).
    @Tag static var systemTools: Self
    /// Tests that feed the readers archives that are cut short or garbled.
    @Tag static var damagedInput: Self
}

struct ZipReaderTests {
    let scratch: ScratchFolder

    init() throws {
        scratch = try ScratchFolder()
    }

    private func index(of bytes: [UInt8], named name: String = "test.zip") throws -> ArchiveIndex {
        try ArchiveIndex.read(at: scratch.write(bytes, as: name))
    }

    /// Seen on a real Mac, 13 Oct 2026: a zip cut into `.001`, `.002`…
    /// (its pieces put end to end are the zip) was extracted by The
    /// Unarchiver, and not known to the plugin.
    @Test func aZipCutIntoNumberedPiecesIsReadAsOne() throws {
        let items = [ZipItem("a.txt", size: 10), ZipItem("folder/b.bin", size: 2_000), ZipItem("folder/c.dat", size: 300_000)]
        let whole = makeZip(items)
        let cut = [0, whole.count / 3, whole.count / 3 + 1, whole.count - 20, whole.count]
        var pieces: [String] = []
        for number in 1..<cut.count {
            pieces.append(try scratch.write(Array(whole[cut[number - 1]..<cut[number]]), as: "cut.zip.00\(number)"))
        }
        let index = try ArchiveIndex.read(at: pieces[0])
        #expect(index.format == .zip)
        #expect(index.entries == [
            ArchiveEntry(path: "a.txt", size: 10),
            ArchiveEntry(path: "folder/b.bin", size: 2_000),
            ArchiveEntry(path: "folder/c.dat", size: 300_000),
        ])
        #expect(index.parts == pieces)
        // With a piece missing the rest is no zip: refused, never guessed.
        try FileManager.default.removeItem(atPath: pieces[3])
        #expect(throws: IndexError.self) { try ArchiveIndex.read(at: pieces[0]) }
    }

    @Test func itemsComeInTheOrderOfTheIndexWithTheirSizes() throws {
        let index = try index(of: makeZip([
            ZipItem("a.txt", size: 10),
            ZipItem("folder/b.bin", size: 2_000),
            ZipItem("folder/deeper/c.dat", size: 300_000),
        ]))
        #expect(index.format == .zip)
        #expect(index.entries == [
            ArchiveEntry(path: "a.txt", size: 10),
            ArchiveEntry(path: "folder/b.bin", size: 2_000),
            ArchiveEntry(path: "folder/deeper/c.dat", size: 300_000),
        ])
        #expect(index.totalSize == 302_010)
        #expect(index.fileCount == 3)
        #expect(index.isWhole)
        #expect(index.needsPassword == false)
        #expect(index.parts.count == 1)
    }

    @Test func foldersAndLinksCountForNothing() throws {
        let index = try index(of: makeZip([
            .folder("photos"),
            ZipItem("photos/one.jpg", size: 500),
            .link("photos/latest", to: "one.jpg"),
        ]))
        #expect(index.entries == [
            ArchiveEntry(path: "photos", size: 0, isFolder: true),
            ArchiveEntry(path: "photos/one.jpg", size: 500),
            ArchiveEntry(path: "photos/latest", size: 0, isLink: true),
        ])
        #expect(index.totalSize == 500)
        #expect(index.fileCount == 2)
    }

    @Test func whatMacOSAddsBesideEachFileIsLeftOut() throws {
        let index = try index(of: makeZip([
            ZipItem("report.pdf", size: 4_000),
            .folder("__MACOSX"),
            ZipItem("__MACOSX/._report.pdf", size: 176),
            ZipItem("notes/__MACOSX.txt", size: 7),
        ]))
        #expect(index.entries.map(\.path) == ["report.pdf", "notes/__MACOSX.txt"])
        #expect(index.totalSize == 4_007)
    }

    @Test func aFileOverFourGigabytesKeepsItsRealSize() throws {
        let index = try index(of: makeZip([
            ZipItem("small.txt", size: 12),
            ZipItem("big.iso", size: 17_150_648_656),
        ]))
        #expect(index.entries.map(\.size) == [12, 17_150_648_656])
        #expect(index.totalSize == 17_150_648_668)
    }

    @Test func theEndWrittenTheZip64WayIsRead() throws {
        var options = ZipOptions()
        options.zip64End = true
        let index = try index(of: makeZip([ZipItem("a", size: 1), ZipItem("b", size: 2)], options: options))
        #expect(index.entries.map(\.path) == ["a", "b"])
        #expect(index.isWhole)
    }

    @Test func aCommentAtTheEndIsSteppedOver() throws {
        var options = ZipOptions()
        options.comment = Array("made on a Tuesday, PK\u{05}\u{06} and all".utf8)
        let index = try index(of: makeZip([ZipItem("a.txt", size: 9)], options: options))
        #expect(index.entries == [ArchiveEntry(path: "a.txt", size: 9)])
    }

    @Test func aProgramInFrontOfTheZipIsSteppedOver() throws {
        var options = ZipOptions()
        options.prefix = [UInt8](repeating: 0x90, count: 5_000)
        let index = try index(of: makeZip([ZipItem("inside.txt", size: 77)], options: options), named: "setup.zip")
        #expect(index.entries == [ArchiveEntry(path: "inside.txt", size: 77)])
    }

    @Test func aNameInTheOldDOSCharactersIsRead() throws {
        var item = ZipItem("", size: 5)
        item.name = [0x82, 0x74, 0x82, 0x2E, 0x74, 0x78, 0x74]        // "été.txt" in code page 437
        item.flags = 0
        let index = try index(of: makeZip([item]))
        #expect(index.entries.map(\.path) == ["été.txt"])
    }

    @Test func theUnicodeNameBesideAnOldOneWins() throws {
        var item = ZipItem("", size: 5)
        item.name = Array("r?sum?.txt".utf8)
        item.flags = 0
        var extra: [UInt8] = []
        let unicode = Array("résumé.txt".utf8)
        extra.le16(0x7075)
        extra.le16(UInt16(5 + unicode.count))
        extra.append(1)
        extra.le32(0)
        extra += unicode
        item.extra = extra
        let index = try index(of: makeZip([item]))
        #expect(index.entries.map(\.path) == ["résumé.txt"])
    }

    @Test func pathsAreMadeSafeToCompare() throws {
        let index = try index(of: makeZip([
            ZipItem("./a/./b.txt", size: 1),
            ZipItem("/rooted/c.txt", size: 2),
            ZipItem("../../escape.txt", size: 3),
            ZipItem("d//e.txt", size: 4),
        ]))
        #expect(index.entries.map(\.path) == ["a/b.txt", "rooted/c.txt", "escape.txt", "d/e.txt"])
    }

    @Test func anEncryptedFileSaysItNeedsAPassword() throws {
        var secret = ZipItem("secret.txt", size: 40)
        secret.flags |= 0x0001
        let index = try index(of: makeZip([ZipItem("open.txt", size: 4), secret]))
        #expect(index.needsPassword)
        // Its name and size are readable all the same.
        #expect(index.entries.last == ArchiveEntry(path: "secret.txt", size: 40))
    }

    @Test func anEmptyZipHoldsNothing() throws {
        let index = try index(of: makeZip([]))
        #expect(index.entries.isEmpty)
        #expect(index.totalSize == 0)
        #expect(index.isWhole)
    }

    @Test func anIndexShorterThanAnnouncedIsNotWhole() throws {
        var options = ZipOptions()
        options.announcedCount = 5
        let index = try index(of: makeZip([ZipItem("a", size: 1), ZipItem("b", size: 2)], options: options))
        #expect(index.entries.count == 2)
        #expect(index.isWhole == false)
    }

    @Test func aFileThatIsNoZipIsRefused() throws {
        let path = try scratch.write(Array("Just some text, long enough to hold an end record.".utf8), as: "notes.zip")
        #expect(throws: IndexError.notAnArchive) {
            try ArchiveIndex.read(at: path)
        }
    }

    @Test func aMissingFileIsUnreadable() {
        #expect(throws: IndexError.unreadable) {
            try ArchiveIndex.read(at: scratch.path + "/nothing-here.zip")
        }
    }

    @Test func aFolderIsUnreadable() {
        #expect(throws: IndexError.unreadable) {
            try ArchiveIndex.read(at: scratch.path)
        }
    }

    /// A zip cut at any length must end in an answer, never in a crash:
    /// archives come from anywhere.
    @Test(.tags(.damagedInput))
    func aZipCutAnywhereIsHandled() throws {
        var options = ZipOptions()
        options.zip64End = true
        var named = ZipItem("with-extra.bin", size: 5_000_000_000)
        named.extra = [0x75, 0x70, 0x03, 0x00, 0x01, 0x00, 0x00]
        let whole = makeZip([ZipItem("a/b/c.txt", size: 10), named, .folder("d")], options: options)
        for length in 0..<whole.count {
            let path = try scratch.write(Array(whole.prefix(length)), as: "cut.zip")
            _ = try? ArchiveIndex.read(at: path)
        }
    }

    /// The same with each byte in turn set wrong.
    @Test(.tags(.damagedInput), arguments: [UInt8(0x00), 0xFF, 0x50])
    func aZipWithAnyByteWrongIsHandled(wrong: UInt8) throws {
        var options = ZipOptions()
        options.zip64End = true
        let whole = makeZip([ZipItem("a/b/c.txt", size: 10), ZipItem("big", size: 5_000_000_000)], options: options)
        for position in 0..<whole.count {
            var garbled = whole
            garbled[position] = wrong
            let path = try scratch.write(garbled, as: "garbled-\(wrong).zip")
            _ = try? ArchiveIndex.read(at: path)
        }
    }

    /// Against real zips, made by macOS's own tools from real files.
    @Test(.tags(.systemTools), arguments: ["zip", "ditto"])
    func aZipMadeByMacOSItselfIsReadRight(tool: String) throws {
        let folder = scratch.path + "/source"
        try scratch.write([UInt8](repeating: 0x41, count: 70_000), as: "source/first.txt")
        try scratch.write([UInt8](repeating: 0x42, count: 123), as: "source/sub/second été.txt")
        try scratch.write([], as: "source/sub/empty.txt")
        let archive = scratch.path + "/made-by-\(tool).zip"
        let process = Process()
        process.currentDirectoryURL = URL(filePath: scratch.path)
        if tool == "zip" {
            process.executableURL = URL(filePath: "/usr/bin/zip")
            process.arguments = ["-q", "-r", archive, "source"]
        } else {
            process.executableURL = URL(filePath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder, archive]
        }
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(tool) couldn't make the test archive")

        let index = try ArchiveIndex.read(at: archive)
        let files = Dictionary(uniqueKeysWithValues: index.entries.filter { $0.isFolder == false }.map { ($0.path, $0.size) })
        #expect(files == ["source/first.txt": 70_000, "source/sub/second été.txt": 123, "source/sub/empty.txt": 0])
        #expect(index.totalSize == 70_123)
        #expect(index.isWhole)
    }
}
