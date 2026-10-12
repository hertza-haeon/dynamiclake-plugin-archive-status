// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

struct TarReaderTests {
    let scratch: ScratchFolder

    init() throws {
        scratch = try ScratchFolder()
    }

    private func index(of bytes: [UInt8], named name: String = "test.tar") throws -> ArchiveIndex {
        try ArchiveIndex.read(at: scratch.write(bytes, as: name))
    }

    @Test func itemsComeInTheirOrderWithTheirSizes() throws {
        let index = try index(of: makeTar([
            .folder("photos"),
            TarItem("photos/one.jpg", size: 10),
            TarItem("photos/deeper/two.jpg", size: 2_000),
            TarItem("notes.txt", size: 513),
        ]))
        #expect(index.format == .tar)
        #expect(index.entries == [
            ArchiveEntry(path: "photos", size: 0, isFolder: true),
            ArchiveEntry(path: "photos/one.jpg", size: 10),
            ArchiveEntry(path: "photos/deeper/two.jpg", size: 2_000),
            ArchiveEntry(path: "notes.txt", size: 513),
        ])
        #expect(index.totalSize == 2_523)
        #expect(index.fileCount == 3)
        #expect(index.isWhole)
        #expect(index.needsPassword == false)
    }

    /// The plugin goes by what is inside, not by the name: MacPacker's
    /// unpacked copy of a `tar.gz` is called `unknown`.
    @Test func aTarUnderAnyNameIsRead() throws {
        let index = try index(of: makeTar([TarItem("a.txt", size: 7)]), named: "unknown")
        #expect(index.format == .tar)
        #expect(index.entries == [ArchiveEntry(path: "a.txt", size: 7)])
    }

    @Test func aLinkCountsForNothingAndHasNoData() throws {
        var hard = TarItem("copy.txt", size: 700)       // (a hard link may announce its target's size)
        hard.kind = UInt8(ascii: "1")
        let index = try index(of: makeTar([
            TarItem("one.txt", size: 700),
            .link("latest"),
            hard,
            TarItem("after.txt", size: 3),
        ]))
        #expect(index.entries == [
            ArchiveEntry(path: "one.txt", size: 700),
            ArchiveEntry(path: "latest", size: 0, isLink: true),
            ArchiveEntry(path: "copy.txt", size: 0, isLink: true),
            ArchiveEntry(path: "after.txt", size: 3),
        ])
        #expect(index.totalSize == 703)
    }

    @Test func theStartOfALongPathIsPutBackInFront() throws {
        var item = TarItem("deep/file.txt", size: 5)
        item.prefix = Array("a/long/way/down".utf8)
        let index = try index(of: makeTar([item]))
        #expect(index.entries.map(\.path) == ["a/long/way/down/deep/file.txt"])
    }

    /// GNU's form uses that field for other things.
    @Test func inGNUsFormThatFieldIsNotAPath() throws {
        var item = TarItem("file.txt", size: 5)
        item.magic = Array("ustar  ".utf8) + [0]
        item.prefix = Array("12345670000".utf8)
        let index = try index(of: makeTar([item]))
        #expect(index.entries.map(\.path) == ["file.txt"])
    }

    @Test func anExtendedHeaderGivesTheNextItemItsPathAndSize() throws {
        let long = String(repeating: "long name ", count: 30) + "été.bin"
        var big = TarItem("short", size: 0)
        big.data = []                                    // (its 9 GB aren't in the test's tar)
        let index = try index(of: makeTar([
            .extended(path: "folder/" + long, others: ["mtime=1760000000.123", "comment=path=wrong"]),
            TarItem("folder/cut-short-na", size: 4),
            TarItem("plain.txt", size: 2),
            .extended(size: 9_000_000_000),
            big,
        ], withEnd: false))
        #expect(index.entries == [
            ArchiveEntry(path: "folder/" + long, size: 4),
            ArchiveEntry(path: "plain.txt", size: 2),
            ArchiveEntry(path: "short", size: 9_000_000_000),
        ])
        // (The last one's data isn't there: the tar is cut short.)
        #expect(index.isWhole == false)
    }

    @Test func gnusLongNameGoesToTheNextItem() throws {
        let long = String(repeating: "x", count: 150) + "/file.bin"
        var item = TarItem("xxxxxxxx", size: 9)
        item.magic = Array("ustar  ".utf8) + [0]
        let index = try index(of: makeTar([.longName(long), item, TarItem("next.txt", size: 1)]))
        #expect(index.entries == [ArchiveEntry(path: long, size: 9), ArchiveEntry(path: "next.txt", size: 1)])
    }

    @Test func aSizeWrittenInBinaryIsRead() throws {
        var item = TarItem("huge.bin", size: 70_000_000_000)
        item.sizeIsBinary = true
        item.data = []
        let index = try index(of: makeTar([TarItem("small.txt", size: 1), item], withEnd: false))
        #expect(index.entries.last == ArchiveEntry(path: "huge.bin", size: 70_000_000_000))
        #expect(index.isWhole == false)
    }

    @Test func whatMacOSAddsBesideEachFileIsLeftOut() throws {
        let index = try index(of: makeTar([
            TarItem("./._report.pdf", size: 176),
            TarItem("./report.pdf", size: 4_000),
            TarItem("notes/._hidden", size: 9),
            TarItem("notes/a._b", size: 7),
        ]))
        #expect(index.entries == [ArchiveEntry(path: "report.pdf", size: 4_000), ArchiveEntry(path: "notes/a._b", size: 7)])
    }

    @Test func pathsAreMadeSafeToCompare() throws {
        let index = try index(of: makeTar([
            TarItem("/absolute/file.txt", size: 1),
            TarItem("./here//there/../file.txt", size: 2),
            .folder("./"),
        ]))
        #expect(index.entries.map(\.path) == ["absolute/file.txt", "here/there/file.txt"])
    }

    @Test func otherKindsOfItemAreSteppedOver() throws {
        var global = TarItem("pax_global_header", size: 52)
        global.kind = UInt8(ascii: "g")
        global.data = tarRecord("comment=0123456789abcdef0123456789abcdef01234567")
        var device = TarItem("dev/null", size: 0)
        device.kind = UInt8(ascii: "3")
        var old = TarItem("old.txt", size: 6)
        old.kind = 0                                     // (how files were marked before `0`)
        let index = try index(of: makeTar([global, device, old]))
        #expect(index.entries == [ArchiveEntry(path: "old.txt", size: 6)])
        #expect(index.isWhole)
    }

    @Test func anEmptyTarHoldsNothing() throws {
        // (Nothing says it is a tar: it reads as no archive at all.)
        let path = try scratch.write(makeTar([]), as: "empty.tar")
        #expect(throws: IndexError.notAnArchive) {
            try ArchiveIndex.read(at: path)
        }
    }

    @Test func aTarWithoutItsEndIsNotWhole() throws {
        let index = try index(of: makeTar([TarItem("a.txt", size: 600)], withEnd: false))
        #expect(index.entries == [ArchiveEntry(path: "a.txt", size: 600)])
        #expect(index.isWhole == false)
    }

    @Test func aTarCutInAFilesDataIsNotWhole() throws {
        let whole = makeTar([TarItem("a.txt", size: 600), TarItem("b.txt", size: 5_000), TarItem("c.txt", size: 1)])
        let index = try index(of: Array(whole.prefix(512 + 1024 + 512 + 2_000)))
        #expect(index.entries.map(\.path) == ["a.txt", "b.txt"])
        #expect(index.isWhole == false)
    }

    @Test func somethingElseAfterTheFirstItemsEndsTheIndexThere() throws {
        var bytes = makeTar([TarItem("a.txt", size: 3)], withEnd: false)
        bytes += [UInt8](repeating: 0x55, count: 2_048)
        let index = try index(of: bytes)
        #expect(index.entries.map(\.path) == ["a.txt"])
        #expect(index.isWhole == false)
    }

    /// Reading the headers of very many items takes seconds: past its
    /// patience the reader gives up, and the archive is followed as one
    /// without an index.
    @Test func aTarThatTakesTooLongIsGivenUp() throws {
        let items = (0..<1_200).map { TarItem("file \($0).txt", size: 0) }
        let source = try FileSource(path: scratch.write(makeTar(items), as: "many.tar"))
        var asked = 0
        #expect(throws: IndexError.tooLarge) {
            try TarReader.read(source) {
                asked += 1
                return asked >= 2
            }
        }
        #expect(asked == 2)
        let patient = try TarReader.read(source) { false }
        #expect(patient.fileCount == 1_200)
    }

    /// A tar cut at any length must end in an answer, never in a crash:
    /// archives come from anywhere.
    @Test(.tags(.damagedInput))
    func aTarCutAnywhereIsHandled() throws {
        let whole = sample()
        for length in 0..<whole.count {
            let path = try scratch.write(Array(whole.prefix(length)), as: "cut.tar")
            _ = try? ArchiveIndex.read(at: path)
        }
    }

    /// The same with each byte in turn set wrong.
    @Test(.tags(.damagedInput), arguments: [UInt8(0x00), 0xFF, 0x39])
    func aTarWithAnyByteWrongIsHandled(wrong: UInt8) throws {
        let whole = sample()
        for position in 0..<whole.count {
            var garbled = whole
            garbled[position] = wrong
            let path = try scratch.write(garbled, as: "garbled-\(wrong).tar")
            _ = try? ArchiveIndex.read(at: path)
            // (And straight to the tar reader: with a byte of its first
            // header wrong, the file no longer says "tar".)
            _ = try? TarReader.read(FileSource(path: path)) { false }
        }
    }

    /// Extended headers that say nonsense: lengths that are wrong, too
    /// short for their own digits, or missing.
    @Test(.tags(.damagedInput), arguments: [
        "1 path=a\n", "2 \n", "0 path=a\n", "999 path=a\n", "-5 path=a\n", "path=a\n", " ", "", "12 path", "7 =\n\n", "3 a",
        "18446744073709551616 path=a\n", "9 size=x\n", "10 size=-1\n",
    ])
    func anExtendedHeaderThatSaysNonsenseIsHandled(records: String) throws {
        var extended = TarItem("PaxHeader/item", size: UInt64(records.utf8.count))
        extended.kind = UInt8(ascii: "x")
        extended.data = Array(records.utf8)
        let index = try index(of: makeTar([extended, TarItem("kept-name.txt", size: 3)]))
        #expect(index.entries.count == 1)
        #expect(index.entries.first?.size == 3)
    }

    private func sample() -> [UInt8] {
        var prefixed = TarItem("deep/file.txt", size: 5)
        prefixed.prefix = Array("a/long/way".utf8)
        var gnu = TarItem("xxxx", size: 9)
        gnu.magic = Array("ustar  ".utf8) + [0]
        return makeTar([
            .folder("a"),
            .extended(path: "a/" + String(repeating: "n", count: 120), size: 3),
            TarItem("a/short", size: 3),
            prefixed,
            .longName(String(repeating: "g", count: 130)),
            gnu,
            .link("a/link"),
        ])
    }

    /// Against real tars, made by macOS's own `tar` from real files, in
    /// each of the forms it writes.
    @Test(.tags(.systemTools), arguments: ["pax", "ustar", "gnutar"])
    func aTarMadeByMacOSItselfIsReadRight(form: String) throws {
        let long = String(repeating: "a long folder name ", count: 5) + "/" + String(repeating: "and a long file name ", count: 3) + ".txt"
        try scratch.write([UInt8](repeating: 0x41, count: 70_000), as: "source/first.txt")
        try scratch.write([UInt8](repeating: 0x42, count: 123), as: "source/sub/second été.txt")
        try scratch.write([], as: "source/sub/empty.txt")
        try scratch.write([0x43], as: "source/" + long)
        let archive = scratch.path + "/made-as-\(form).tar"
        let process = Process()
        process.currentDirectoryURL = URL(filePath: scratch.path)
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["-c", "--format", form, "-f", archive, "source"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "tar couldn't make the test archive")

        let index = try ArchiveIndex.read(at: archive)
        let files = Dictionary(uniqueKeysWithValues: index.entries.filter { $0.isFolder == false }.map { ($0.path, $0.size) })
        #expect(files == [
            "source/first.txt": 70_000, "source/sub/second été.txt": 123, "source/sub/empty.txt": 0, "source/" + long: 1,
        ])
        #expect(index.format == .tar)
        #expect(index.totalSize == 70_124)
        #expect(index.isWhole)
    }
}
