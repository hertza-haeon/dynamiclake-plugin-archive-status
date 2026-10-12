// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

struct CompressedTarReaderTests {
    let scratch: ScratchFolder

    init() throws {
        scratch = try ScratchFolder()
    }

    private func index(of tar: [UInt8], named name: String = "test.tar.gz") throws -> ArchiveIndex {
        try ArchiveIndex.read(at: scratch.write(makeGzip(tar), as: name))
    }

    @Test func itemsComeInTheirOrderWithTheirSizes() throws {
        let index = try index(of: makeTar([
            .folder("photos"),
            TarItem("photos/one.jpg", size: 10),
            TarItem("photos/deeper/two.jpg", size: 70_000),
            TarItem("notes.txt", size: 513),
        ]))
        #expect(index.format == .compressedTar)
        #expect(index.entries == [
            ArchiveEntry(path: "photos", size: 0, isFolder: true),
            ArchiveEntry(path: "photos/one.jpg", size: 10),
            ArchiveEntry(path: "photos/deeper/two.jpg", size: 70_000),
            ArchiveEntry(path: "notes.txt", size: 513),
        ])
        #expect(index.totalSize == 70_523)
        #expect(index.fileCount == 3)
        #expect(index.isWhole)
        #expect(index.needsPassword == false)
    }

    /// The plugin goes by what is inside, not by the name.
    @Test func aCompressedTarUnderAnyNameIsRead() throws {
        let index = try index(of: makeTar([TarItem("a.txt", size: 7)]), named: "download")
        #expect(index.entries == [ArchiveEntry(path: "a.txt", size: 7)])
    }

    @Test func linksCountForNothing() throws {
        var hard = TarItem("copy.txt", size: 0)
        hard.kind = UInt8(ascii: "1")
        hard.linkTarget = Array("one.txt".utf8)
        var soft = TarItem.link("latest")
        soft.linkTarget = Array("one.txt".utf8)
        let index = try index(of: makeTar([TarItem("one.txt", size: 700), soft, hard, TarItem("after.txt", size: 3)]))
        #expect(index.entries == [
            ArchiveEntry(path: "one.txt", size: 700),
            ArchiveEntry(path: "latest", size: 0, isLink: true),
            ArchiveEntry(path: "copy.txt", size: 0, isLink: true),
            ArchiveEntry(path: "after.txt", size: 3),
        ])
        #expect(index.totalSize == 703)
    }

    @Test func longNamesInEachFormAreRead() throws {
        let long = String(repeating: "long name ", count: 30) + "été.bin"
        let gnuLong = String(repeating: "x", count: 150) + "/file.bin"
        var prefixed = TarItem("deep/file.txt", size: 5)
        prefixed.prefix = Array("a/long/way/down".utf8)
        var gnu = TarItem("xxxxxxxx", size: 9)
        gnu.magic = Array("ustar  ".utf8) + [0]
        let index = try index(of: makeTar([
            .extended(path: "folder/" + long),
            TarItem("folder/cut-short-na", size: 4),
            prefixed,
            .longName(gnuLong),
            gnu,
        ]))
        #expect(index.entries == [
            ArchiveEntry(path: "folder/" + long, size: 4),
            ArchiveEntry(path: "a/long/way/down/deep/file.txt", size: 5),
            ArchiveEntry(path: gnuLong, size: 9),
        ])
    }

    @Test func whatMacOSAddsBesideEachFileIsLeftOutAndPathsAreMadeSafe() throws {
        let index = try index(of: makeTar([
            TarItem("./report.pdf", size: 4_000),
            TarItem("notes/._hidden", size: 9),
            TarItem("/absolute/file.txt", size: 1),
            TarItem("./here//there/../file.txt", size: 2),
        ]))
        #expect(index.entries.map(\.path) == ["report.pdf", "absolute/file.txt", "here/there/file.txt"])
    }

    @Test func somethingCompressedThatHoldsNoTarIsNoArchive() throws {
        let path = try scratch.write(makeGzip(Array("Just a letter, compressed, and no archive at all.".utf8)), as: "letter.txt.gz")
        #expect(throws: IndexError.notAnArchive) {
            try ArchiveIndex.read(at: path)
        }
    }

    @Test func aCompressedTarCutShortIsNotWhole() throws {
        let whole = makeGzip(makeTar([TarItem("a.txt", size: 600), TarItem("b.txt", size: 400_000), TarItem("c.txt", size: 1)]))
        let index = try ArchiveIndex.read(at: scratch.write(Array(whole.prefix(200_000)), as: "cut.tar.gz"))
        #expect(index.entries.map(\.path) == ["a.txt", "b.txt"])
        #expect(index.isWhole == false)
    }

    /// Cut before anything of it could be listed, it reads as no archive:
    /// either way it is followed without an index.
    @Test func aCompressedTarCutAtItsBeginningListsNothing() throws {
        let whole = makeGzip(makeTar([TarItem("a.txt", size: 600), TarItem("b.txt", size: 5_000)]))
        let path = try scratch.write(Array(whole.prefix(3_000)), as: "cut.tar.gz")
        #expect(throws: IndexError.notAnArchive) {
            try ArchiveIndex.read(at: path)
        }
    }

    /// Unpacking takes time in proportion to what is inside: past its
    /// patience the reader gives up, also in the middle of a large item,
    /// and the archive is followed as one without an index.
    @Test(arguments: [1, 2, 5])
    func aCompressedTarThatTakesTooLongIsGivenUp(askedBeforeOverdue: Int) throws {
        let path = try scratch.write(Self.large, as: "large.tar.gz")
        var asked = 0
        #expect(throws: IndexError.tooLarge) {
            try CompressedTarReader.read(path: path) {
                asked += 1
                return asked > askedBeforeOverdue
            }
        }
        #expect(asked == askedBeforeOverdue + 1)
        let patient = try CompressedTarReader.read(path: path) { false }
        #expect(patient.entries.map(\.size) == [2_200_000, 2_200_000, 100])
    }

    /// Two items large enough for the time to be looked at inside each.
    private static let large = makeGzip(makeTar([
        TarItem("first.bin", size: 2_200_000),
        TarItem("second.bin", size: 2_200_000),
        TarItem("third.bin", size: 100),
    ]))

    /// A compressed tar cut at any length must end in an answer, never in
    /// a crash: archives come from anywhere.
    @Test(.tags(.damagedInput))
    func aCompressedTarCutAnywhereIsHandled() throws {
        let whole = makeGzip(sample())
        for length in stride(from: 0, to: whole.count, by: 7) {
            let path = try scratch.write(Array(whole.prefix(length)), as: "cut.tar.gz")
            _ = try? ArchiveIndex.read(at: path)
        }
    }

    /// The same with bytes set wrong, in the compression's own parts and
    /// in the tar inside.
    @Test(.tags(.damagedInput), arguments: [UInt8(0x00), 0xFF, 0x39])
    func aCompressedTarWithAByteWrongIsHandled(wrong: UInt8) throws {
        let whole = makeGzip(sample())
        for position in stride(from: 0, to: whole.count, by: 5) {
            var garbled = whole
            garbled[position] = wrong
            let path = try scratch.write(garbled, as: "garbled-\(wrong).tar.gz")
            _ = try? ArchiveIndex.read(at: path)
            _ = try? CompressedTarReader.read(path: path) { false }
        }
    }

    private func sample() -> [UInt8] {
        var prefixed = TarItem("deep/file.txt", size: 5)
        prefixed.prefix = Array("a/long/way".utf8)
        return makeTar([
            .folder("a"),
            .extended(path: "a/" + String(repeating: "n", count: 120), size: 3),
            TarItem("a/short", size: 3),
            prefixed,
            .link("a/link"),
        ])
    }

    /// Against real archives, made by macOS's own `tar` from real files,
    /// with each compression.
    @Test(.tags(.systemTools), arguments: [("z", "tar.gz"), ("z", "tgz"), ("j", "tar.bz2"), ("J", "tar.xz")])
    func aCompressedTarMadeByMacOSItselfIsReadRight(option: String, ending: String) throws {
        let long = String(repeating: "a long folder name ", count: 5) + "/" + String(repeating: "and a long file name ", count: 3) + ".txt"
        try scratch.write([UInt8](repeating: 0x41, count: 70_000), as: "source/first.txt")
        try scratch.write([UInt8](repeating: 0x42, count: 123), as: "source/sub/second été.txt")
        try scratch.write([], as: "source/sub/empty.txt")
        try scratch.write([0x43], as: "source/" + long)
        let archive = scratch.path + "/made.\(ending)"
        let process = Process()
        process.currentDirectoryURL = URL(filePath: scratch.path)
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["-c", "-\(option)", "-f", archive, "source"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "tar couldn't make the test archive")

        let index = try ArchiveIndex.read(at: archive)
        let files = Dictionary(uniqueKeysWithValues: index.entries.filter { $0.isFolder == false }.map { ($0.path, $0.size) })
        #expect(files == [
            "source/first.txt": 70_000, "source/sub/second été.txt": 123, "source/sub/empty.txt": 0, "source/" + long: 1,
        ])
        #expect(index.format == .compressedTar)
        #expect(index.totalSize == 70_124)
        #expect(index.isWhole)
    }
}
