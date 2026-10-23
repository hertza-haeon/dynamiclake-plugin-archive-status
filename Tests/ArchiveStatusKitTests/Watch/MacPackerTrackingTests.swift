// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// What MacPacker was seen to do on a real Mac,
/// replayed look by look.
struct MacPackerTrackingTests {
    let mac = FakeMac()
    let archive = "/Users/me/Downloads/big.rar"

    @Test func oneBigFileIsFollowedToItsEnd() throws {
        mac.setIndex([ArchiveEntry(path: "game.nsp", size: 2_559_400_215)], format: .rar4, for: archive)
        var tracker = mac.tracker()
        let written = "/Users/me/Downloads/big/game.nsp"

        // MacPacker has the archive open, and writes nothing yet.
        #expect(tracker.step(now: 0, processes: [macPacker([reading(archive)])]).isEmpty)
        #expect(tracker.extractions.isEmpty)

        // It writes at the final place: a folder named after the archive.
        var lines = tracker.step(now: 0.5, processes: [macPacker([reading(archive), writing(written, size: 155_000_000)])])
        #expect(lines == [
            "big.rar: MacPacker is extracting it: 2.56 GB in 1 file (rar (old format)), into /Users/me/Downloads/big",
            "big.rar: 6 % · 155.0 MB of 2.56 GB",
        ])
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.tool == .macPacker)
        #expect(extraction.total == 2_559_400_215)
        #expect(extraction.written == 155_000_000)
        #expect(extraction.destination == "/Users/me/Downloads/big")

        // A steady 155 MB a second.
        for tenth in 6...100 {
            let now = Double(tenth) / 10
            lines = tracker.step(now: now, processes: [
                macPacker([reading(archive), writing(written, size: UInt64(now * 310_000_000) - 0)]),
            ])
        }
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 2_559_400_215, "what is written never counts for more than the index says")

        // The archive is let go of, and the file is there, whole.
        mac.put(.file(size: 2_559_400_215), at: written)
        lines = tracker.step(now: 16.5, processes: [macPacker([])])
        #expect(lines == ["big.rar: complete: 2.56 GB in 16.0 s; at /Users/me/Downloads/big/game.nsp"])
        #expect(tracker.extractions.isEmpty)
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .complete)
        #expect(ended.written == 2_559_400_215)
        #expect(tracker.attention == .none)
    }

    /// Seen on a real Mac (12 Oct): reading the index of 150,000
    /// items took 1.4 s, the look it was read in had grown old by as much,
    /// and what was written meanwhile counted as written in an instant
    /// later: a speed of 2.2 MB a second where 40 was true.
    @Test func theTimeAnIndexTakesToBeReadIsNotTimeSpentExtracting() throws {
        mac.setIndex((0..<12_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 10_000) }, for: archive)
        mac.indexReadSeconds = 1.4
        var tracker = mac.tracker()
        // 4,000 files a second, 40 MB: the first one caught at 10.0, the
        // index read by 11.4, and looks every tenth of a second from then.
        func look(_ now: Double, file: Int) {
            _ = tracker.step(now: now, processes: [
                macPacker([reading(archive), writing("/Users/me/Downloads/many/file \(file).bin", size: 10_000)]),
            ])
        }
        look(10, file: 100)
        var extraction = try #require(tracker.extractions.first)
        #expect(abs(extraction.startedAt - 11.4) < 0.001, "seen from when the index was read")
        #expect(mac.indexReads.count == 1)
        for tenth in 1...15 {
            look(11.4 + Double(tenth) / 10, file: 100 + tenth * 400)
        }
        extraction = try #require(tracker.extractions.first)
        #expect(abs(extraction.speed - 40_000_000) < 2_000_000, "\(extraction.speed)")
        #expect(mac.indexReads.count == 1)
    }

    @Test func lookingIntoAnArchiveIsNoExtraction() {
        mac.setIndex([ArchiveEntry(path: "a.txt", size: 10)], for: archive)
        var tracker = mac.tracker()
        // Open for 2.6 seconds with nothing written, as seen on the real Mac.
        for tenth in 0...26 {
            #expect(tracker.step(now: Double(tenth) / 10, processes: [macPacker([reading(archive)])]).isEmpty)
        }
        #expect(tracker.attention == .close)
        #expect(tracker.step(now: 2.7, processes: [macPacker([])]).isEmpty)
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.ended.isEmpty)
        #expect(tracker.attention == .none)
        // (Kept open past one look, it is read once, to look for its first
        // files: see "MacPacker's beginning" below.)
        #expect(mac.indexReads == [archive])
    }

    @Test func anArchiveOpenForAMomentToListItIsNotReadByThePlugin() {
        mac.setIndex([ArchiveEntry(path: "a.txt", size: 10)], for: archive)
        var tracker = mac.tracker()
        #expect(tracker.step(now: 0, processes: [macPacker([reading(archive)])]).isEmpty)
        #expect(tracker.step(now: 0.1, processes: [macPacker([])]).isEmpty)
        #expect(mac.indexReads.isEmpty)
        #expect(tracker.extractions.isEmpty)
    }

    // MARK: MacPacker's beginning (found on 12 Oct 2026: the pill took too long to appear)

    /// MacPacker has a small file open for a fraction of a millisecond: of
    /// very many small ones, the first to be caught being written may come
    /// seconds into the extraction. The archive's first files, found where
    /// MacPacker puts them, tell the beginning without that.
    @Test(arguments: [
        "/Users/me/Downloads",                    // beside the archive (and Downloads)
        "/Users/me/Downloads/big",                // in a folder named after the archive
    ])
    func theBeginningIsToldByTheFirstFilesWithoutOneBeingCaught(root: String) throws {
        mac.setIndex([ArchiveEntry(path: "many", size: 0, isFolder: true)]
            + (0..<12_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 100) }, for: archive)
        var tracker = mac.tracker()
        // MacPacker opens the archive; nothing is written yet.
        #expect(tracker.step(now: 0, processes: [macPacker([reading(archive)])]).isEmpty)
        #expect(tracker.step(now: 0.1, processes: [macPacker([reading(archive)])]).isEmpty)
        #expect(tracker.extractions.isEmpty)
        // Its first files are there, and no look catches one being written.
        for file in 0..<40 {
            mac.put(.file(size: 100), at: "\(root)/many/file \(file).bin")
        }
        let lines = tracker.step(now: 0.2, processes: [macPacker([reading(archive)])])
        #expect(lines.first == "big.rar: MacPacker is extracting it: 1.2 MB in 12,000 files (zip), into \(root)")
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.startedAt == 0.2)
        #expect(extraction.destination == root)
        #expect(extraction.result == "\(root)/many")
        // And from there the progress is read from the files that are there.
        #expect(extraction.written == 4_000)
        for file in 40..<600 {
            mac.put(.file(size: 100), at: "\(root)/many/file \(file).bin")
        }
        _ = tracker.step(now: 0.3, processes: [macPacker([reading(archive)])])
        #expect(tracker.extractions.first?.written == 60_000)
        #expect(mac.indexReads == [archive], "read once")
    }

    @Test func theBeginningIsLookedForWhereMacPackerExtractedLast() throws {
        let other = "/Volumes/Disk/archives/second.zip"
        mac.setIndex([ArchiveEntry(path: "game.nsp", size: 1_000)], format: .rar4, for: archive)
        mac.setIndex((0..<500).map { ArchiveEntry(path: "small/file \($0).bin", size: 100) }, for: other)
        var tracker = mac.tracker()
        // A first extraction, into a folder chosen in MacPacker.
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/Users/me/Documents/out/game.nsp", size: 400)])])
        mac.put(.file(size: 1_000), at: "/Users/me/Documents/out/game.nsp")
        _ = tracker.step(now: 1, processes: [macPacker([])])
        #expect(tracker.ended.last?.ending == .complete)
        // The next one, of another archive elsewhere, goes there too.
        _ = tracker.step(now: 5, processes: [macPacker([reading(other)])])
        mac.put(.file(size: 100), at: "/Users/me/Documents/out/small/file 0.bin")
        _ = tracker.step(now: 5.1, processes: [macPacker([reading(other)])])
        #expect(tracker.extractions.first?.destination == "/Users/me/Documents/out")
    }

    /// What was there before MacPacker opened the archive is no beginning:
    /// an earlier copy, or anything else of that name.
    @Test func filesThatWereThereBeforeAreNoBeginning() {
        mac.setIndex((0..<500).map { ArchiveEntry(path: "many/file \($0).bin", size: 100) }, for: archive)
        for file in 0..<500 {
            mac.put(.file(size: 100), at: "/Users/me/Downloads/many/file \(file).bin", changedAt: mac.clock - 60)
        }
        var tracker = mac.tracker()
        for tenth in 0...30 {
            #expect(tracker.step(now: Double(tenth) / 10, processes: [macPacker([reading(archive)])]).isEmpty)
        }
        #expect(tracker.extractions.isEmpty)
    }

    /// A compressed tar isn't read just because MacPacker has it open: it
    /// has to be unpacked for that, which can take seconds. It begins with
    /// the first file caught, as before.
    @Test(arguments: ["/Users/me/Downloads/sources.tar.gz", "/Users/me/Downloads/sources.tgz"])
    func aCompressedTarIsNotReadBeforeAFileOfItIsCaught(tar: String) {
        mac.setIndex([ArchiveEntry(path: "src/main.c", size: 100)], format: .tar, for: tar)
        mac.put(.file(size: 100), at: "/Users/me/Downloads/src/main.c")
        var tracker = mac.tracker()
        for tenth in 0...10 {
            _ = tracker.step(now: Double(tenth) / 10, processes: [macPacker([reading(tar)])])
        }
        #expect(mac.indexReads.isEmpty)
        #expect(tracker.extractions.isEmpty)
    }

    /// Seen on a real Mac, 13 Oct 2026: a tar of 60,000 files extracted
    /// with MacPacker showed its pill at 65 % (the first file caught was
    /// the 39,574th). A plain tar's list is its every header: it is read
    /// once MacPacker keeps the tar open, and the beginning is then told
    /// by its first files, as for a zip.
    @Test func aPlainTarIsReadOnceMacPackerKeepsItOpenAndBeginsWithItsFirstFiles() throws {
        let tar = "/Users/me/Downloads/sources.tar"
        mac.setIndex([ArchiveEntry(path: "src/main.c", size: 100), ArchiveEntry(path: "src/util.c", size: 300)],
                     format: .tar, for: tar)
        var tracker = mac.tracker()
        #expect(tracker.step(now: 0, processes: [macPacker([reading(tar)])]).isEmpty)
        #expect(mac.indexReads.isEmpty, "not for a look into it")
        #expect(tracker.step(now: 0.1, processes: [macPacker([reading(tar)])]).isEmpty)
        #expect(mac.indexReads == [tar])
        #expect(tracker.extractions.isEmpty)
        // Its first file is there, and none was caught being written.
        mac.put(.file(size: 100), at: "/Users/me/Downloads/src/main.c")
        let lines = tracker.step(now: 2, processes: [macPacker([reading(tar)])])
        #expect(lines.first == "sources.tar: MacPacker is extracting it: 400 bytes in 2 files (tar), into /Users/me/Downloads")
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.startedAt == 2)
        #expect(extraction.written == 100)
    }

    @Test func theWaitForAPasswordIsNoExtraction() {
        // MacPacker asks for the password with the archive open and nothing
        // written: 13.7 seconds on the real Mac. Then it lets go of it.
        var tracker = mac.tracker()
        for second in 0...13 {
            #expect(tracker.step(now: Double(second), processes: [macPacker([reading(archive)])]).isEmpty)
        }
        #expect(tracker.step(now: 14, processes: [macPacker([])]).isEmpty)
        #expect(tracker.ended.isEmpty)
    }

    @Test func aCancelLeavesThePartialFileAndIsReportedStopped() throws {
        mac.setIndex([ArchiveEntry(path: "one big file.txt", size: 3_520_833_340)], for: archive)
        var tracker = mac.tracker()
        let written = "/Users/me/Downloads/one big file.txt"
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing(written, size: 10_000_000)])])
        _ = tracker.step(now: 5.6, processes: [macPacker([reading(archive), writing(written, size: 930_000_000)])])
        // Cancelled: the archive is let go of, the partial file stays.
        mac.put(.file(size: 944_766_976), at: written)
        let lines = tracker.step(now: 5.7, processes: [macPacker([])])
        #expect(lines == [
            "big.rar: stopped short at 26 % (944.8 MB of 3.52 GB) after 5.7 s; at /Users/me/Downloads/one big file.txt",
        ])
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .stopped)
        #expect(ended.written == 944_766_976, "the size is read once more at the end")
    }

    @Test func theArchiveLetGoOfBeforeTheLastFileIsWholeIsNotAStop() throws {
        // Should MacPacker let go of the archive while it still writes the
        // last of what it read, that isn't the end yet.
        mac.setIndex([ArchiveEntry(path: "a.bin", size: 1_000), ArchiveEntry(path: "b.bin", size: 9_000)], for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/d/out/b.bin", size: 6_000)])])
        mac.put(.file(size: 7_000), at: "/d/out/b.bin")
        #expect(tracker.step(now: 1.5, processes: [macPacker([writing("/d/out/b.bin", size: 7_000)])]) == [
            "big.rar: 80 % · 8.0 KB of 10.0 KB · 667 bytes/s · file 2 of 2",
        ])
        #expect(tracker.extractions.count == 1)
        mac.put(.file(size: 1_000), at: "/d/out/a.bin")
        mac.put(.file(size: 9_000), at: "/d/out/b.bin")
        #expect(tracker.step(now: 1.6, processes: [macPacker([])]) == ["big.rar: complete: 10.0 KB in 1.6 s; at /d/out"])
    }

    @Test func manySmallFilesAreFollowedByTheirPlaceInTheIndex() throws {
        let entries = (0..<12_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 100) }
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        func look(_ now: Double, file: Int, size: UInt64) -> [String] {
            tracker.step(now: now, processes: [
                macPacker([reading(archive), writing("/Users/me/Downloads/many/file \(file).bin", size: size)]),
            ])
        }
        // Places 258, 897, 1,229 … as caught on the real Mac: always forward.
        var lines = look(0.0, file: 257, size: 40)
        #expect(lines.last == "big.rar: 2 % · 25.7 KB of 1.2 MB · file 258 of 12,000")
        lines = look(1.1, file: 896, size: 100)
        #expect(lines == ["big.rar: 7 % · 89.7 KB of 1.2 MB · 58.1 KB/s · file 897 of 12,000"])
        lines = look(2.2, file: 11_813, size: 0)
        #expect(lines == ["big.rar: 98 % · 1.2 MB of 1.2 MB · 525.3 KB/s · file 11,814 of 12,000"])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.fileNumber == 11_814)
        #expect(extraction.fileCount == 12_000)

        for file in 0..<12_000 {
            mac.put(.file(size: 100), at: "/Users/me/Downloads/many/file \(file).bin")
        }
        #expect(tracker.step(now: 2.5, processes: [macPacker([])]).first?.hasPrefix("big.rar: complete: 1.2 MB in 2.5 s") == true)
        #expect(tracker.ended.last?.fileNumber == 12_000)
    }

    @Test func aMultiPartArchiveIsOneExtraction() throws {
        let parts = (1...4).map { "/Volumes/Disk/TLOZ.part\($0).rar" }
        mac.setIndex([ArchiveEntry(path: "game.nsp", size: 17_150_648_656), ArchiveEntry(path: "info.txt", size: 192)],
                     format: .rar4, for: parts[0], parts: parts)
        var tracker = mac.tracker()
        // MacPacker has all four parts open together, from the first second on.
        let open = parts.map { reading($0, size: 4_404_019_200) }
        #expect(tracker.step(now: 0, processes: [macPacker(open)]).isEmpty)
        let lines = tracker.step(now: 1, processes: [
            macPacker(open + [writing("/Volumes/Disk/TLOZ.part1/game.nsp", size: 157_000_000)]),
        ])
        #expect(lines.first == "TLOZ.part1.rar: MacPacker is extracting it: 17.15 GB in 2 files "
            + "(rar (old format), 4 parts), into /Volumes/Disk/TLOZ.part1")
        #expect(tracker.extractions.count == 1)
        #expect(mac.indexReads == [parts[0]], "the index is read once, from the first part")

        mac.put(.file(size: 17_150_648_656), at: "/Volumes/Disk/TLOZ.part1/game.nsp")
        mac.put(.file(size: 192), at: "/Volumes/Disk/TLOZ.part1/info.txt")
        #expect(tracker.step(now: 109, processes: [macPacker([])]).last?.hasPrefix("TLOZ.part1.rar: complete: 17.15 GB") == true)
    }

    @Test func whatMacPackerWritesInItsOwnFoldersIsNoExtraction() {
        mac.setIndex([ArchiveEntry(path: "photo.jpg", size: 5_000)], for: archive)
        var tracker = mac.tracker()
        // Showing a file of the archive without extracting it, or MacPacker's
        // own records: written under its own Library folder or a temporary one.
        for path in [
            "/Users/me/Library/Containers/com.sarensx.MacPacker/Data/tmp/preview/photo.jpg",
            "/private/var/folders/2f/x/T/com.sarensx.MacPacker/photo.jpg",
            "/var/folders/2f/x/T/photo.jpg",
        ] {
            #expect(tracker.step(now: 0, processes: [macPacker([reading(archive), writing(path, size: 2_000)])]).isEmpty)
        }
        #expect(tracker.extractions.isEmpty)
        #expect(mac.indexReads == [archive], "read once, when it stayed open; no extraction comes of it")
    }

    /// Seen on the real Mac (extractions of 11 Oct): MacPacker
    /// has files of its own open for writing all the while, in its own
    /// folders. They are no part of an extraction, with an index or without.
    @Test(arguments: [true, false])
    func macPackersOwnOpenFilesDoNotDisturbAnExtraction(hasIndex: Bool) throws {
        let own = [
            writing("/private/var/folders/2f/x/C/com.sarensx.MacPacker/com.sarensx.MacPacker/com.apple.metal/16777235_530/functions.data", size: 16_384),
            writing("/Users/me/Library/Containers/com.sarensx.MacPacker/Data/Library/HTTPStorages/com.sarensx.MacPacker/httpstorages.sqlite", size: 4_096),
        ]
        if hasIndex {
            mac.setIndex([ArchiveEntry(path: "a folder of files/file 001.bin", size: 20_000)], for: archive)
        } else {
            mac.setIndexFailure(.locked, for: archive)
        }
        var tracker = mac.tracker()
        // Open, its own files being written, nothing extracted: no extraction.
        #expect(tracker.step(now: 0, processes: [macPacker([reading(archive)] + own)]).isEmpty)
        #expect(tracker.extractions.isEmpty)
        #expect(mac.indexReads.isEmpty)
        // The extraction itself counts only its own file.
        _ = tracker.step(now: 1, processes: [
            macPacker([reading(archive), writing("/Users/me/Downloads/a folder of files/file 001.bin", size: 5_000)] + own),
        ])
        #expect(try #require(tracker.extractions.first).written == 5_000)
    }

    @Test func aFileTheArchiveDoesNotHoldIsNotCounted() {
        mac.setIndex([ArchiveEntry(path: "photo.jpg", size: 5_000)], for: archive)
        var tracker = mac.tracker()
        let lines = tracker.step(now: 0, processes: [
            macPacker([reading(archive), writing("/Users/me/Documents/unrelated notes.txt", size: 2_000)]),
        ])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.isEmpty)
    }

    @Test func withoutAnIndexWhatIsWrittenIsAddedUp() throws {
        mac.setIndexFailure(.locked, for: archive)
        var tracker = mac.tracker()
        var lines = tracker.step(now: 0, processes: [
            macPacker([reading(archive), writing("/Users/me/Downloads/out/a.bin", size: 400)]),
        ])
        #expect(lines == [
            "big.rar: MacPacker is extracting it; total unknown (its index is encrypted)",
            "big.rar: 400 bytes written",
        ])
        _ = tracker.step(now: 1, processes: [macPacker([reading(archive), writing("/Users/me/Downloads/out/a.bin", size: 1_000)])])
        // Another file: the one before is taken as done at the size last seen.
        lines = tracker.step(now: 2.5, processes: [macPacker([reading(archive), writing("/Users/me/Downloads/out/b.bin", size: 250)])])
        // (850 bytes in the 2.5 seconds since the first reading.)
        #expect(lines == ["big.rar: 1.3 KB written · 340 bytes/s"])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.total == nil)
        #expect(extraction.written == 1_250)

        // Without an index, whether it got to its end can't be told.
        mac.put(.file(size: 300), at: "/Users/me/Downloads/out/b.bin")
        lines = tracker.step(now: 3, processes: [macPacker([])])
        #expect(lines == [
            "big.rar: ended after 3.0 s, and whether it got to its end can't be told (1.3 KB seen written)",
        ])
        #expect(tracker.ended.last?.ending == .unknown)
        #expect(tracker.ended.last?.written == 1_300)
    }

    @Test func withTwoArchivesOpenAFileGoesToTheOneThatListsIt() throws {
        let other = "/Users/me/Downloads/other.zip"
        mac.setIndex([ArchiveEntry(path: "docs/readme.txt", size: 500)], for: archive)
        mac.setIndex([ArchiveEntry(path: "readme.txt", size: 900), ArchiveEntry(path: "song.mp3", size: 8_000)], for: other)
        var tracker = mac.tracker()
        // "readme.txt" is in both; the folder above it tells which.
        var lines = tracker.step(now: 0, processes: [
            macPacker([reading(archive), reading(other), writing("/Users/me/Desktop/docs/readme.txt", size: 100)]),
        ])
        #expect(lines.first?.hasPrefix("big.rar: MacPacker is extracting it") == true)
        lines = tracker.step(now: 1, processes: [
            macPacker([reading(archive), reading(other), writing("/Users/me/Desktop/song.mp3", size: 100)]),
        ])
        #expect(lines.first?.hasPrefix("other.zip: MacPacker is extracting it") == true)
        #expect(tracker.extractions.map(\.name).sorted() == ["big.rar", "other.zip"])
    }

    @Test func progressNeverGoesBack() throws {
        mac.setIndex((0..<10).map { ArchiveEntry(path: "f\($0)", size: 100) }, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/d/out/f7", size: 50)])])
        // A file from earlier in the index: said once in the log, and the
        // progress keeps to the furthest seen.
        var lines = tracker.step(now: 2, processes: [macPacker([reading(archive), writing("/d/out/f2", size: 50)])])
        #expect(lines == [
            "big.rar: a file from earlier in the index is being written (place 3 after 8): the progress keeps to the furthest seen",
        ])
        lines = tracker.step(now: 4, processes: [macPacker([reading(archive), writing("/d/out/f1", size: 50)])])
        #expect(lines.isEmpty)
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 750)
        #expect(extraction.fileNumber == 8)
    }

    @Test func theLogGetsOneProgressLineASecondAndNoneWhenNothingMoves() {
        mac.setIndex([ArchiveEntry(path: "a.bin", size: 1_000_000)], for: archive)
        var tracker = mac.tracker()
        var progressLines = 0
        // Ten looks a second for three seconds, the file growing all along.
        for tenth in 0..<30 {
            let lines = tracker.step(now: Double(tenth) / 10, processes: [
                macPacker([reading(archive), writing("/d/a.bin", size: UInt64(tenth) * 10_000)]),
            ])
            progressLines += lines.count { $0.contains(" of ") }
        }
        #expect(progressLines == 3)
        // Then nothing more is written for ten seconds: the last amount is
        // said once, and that is all.
        let last = tracker.step(now: 3.05, processes: [macPacker([reading(archive), writing("/d/a.bin", size: 290_000)])])
        #expect(last.count == 1)
        #expect(last.first?.hasPrefix("big.rar: 29 % · 290.0 KB of 1.0 MB") == true)
        for second in 4..<14 {
            let lines = tracker.step(now: Double(second) + 0.05, processes: [
                macPacker([reading(archive), writing("/d/a.bin", size: 290_000)]),
            ])
            #expect(lines.isEmpty)
        }
    }

    @Test func aLookThatCannotBeReadIsNotTakenForTheEnd() throws {
        mac.setIndex([ArchiveEntry(path: "a.bin", size: 1_000)], for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/d/a.bin", size: 100)])])
        // macOS gave nothing for this look: neither open nor closed.
        #expect(tracker.step(now: 0.1, processes: [macPacker(nil)]).isEmpty)
        #expect(tracker.extractions.count == 1)
        // MacPacker itself is gone: that is the end.
        mac.put(.file(size: 400), at: "/d/a.bin")
        let lines = tracker.step(now: 0.2, processes: [])
        #expect(lines == ["big.rar: stopped short at 40 % (400 bytes of 1.0 KB) after 0.2 s; at /d/a.bin"])
    }

    @Test func anArchiveInsideTheArchiveIsAFileLikeAnother() throws {
        mac.setIndex([ArchiveEntry(path: "inner.zip", size: 9_000), ArchiveEntry(path: "notes.txt", size: 1_000)], for: archive)
        var tracker = mac.tracker()
        let lines = tracker.step(now: 0, processes: [
            macPacker([reading(archive), writing("/d/out/inner.zip", size: 4_500)]),
        ])
        #expect(lines.last == "big.rar: 45 % · 4.5 KB of 10.0 KB · file 1 of 2")
    }

    @Test func anArchiveOfEmptyFilesOnlyIsCompleteWhenLetGoOf() {
        mac.setIndex([ArchiveEntry(path: "empty one", size: 0), ArchiveEntry(path: "empty two", size: 0)], for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/d/empty two", size: 0)])])
        #expect(tracker.step(now: 0.1, processes: [macPacker([])]) == ["big.rar: complete: 0 bytes in 0.1 s; at /d"])
    }

    @Test func whatIsLeftBehindIsTheOneItemOrTheFolderThatHoldsSeveral() throws {
        // One item at the top (a folder here): that item, for Open and for Show in Finder.
        mac.setIndex([ArchiveEntry(path: "album/one.jpg", size: 10), ArchiveEntry(path: "album/two.jpg", size: 10)], for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/Users/me/Desktop/album/one.jpg", size: 5)])])
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.result == "/Users/me/Desktop/album")
        #expect(extraction.revealPaths == ["/Users/me/Desktop/album"])

        // Several: Open opens the folder they are in, Show in Finder selects them.
        let other = "/Users/me/Downloads/loose.zip"
        mac.setIndex([ArchiveEntry(path: "a.txt", size: 10), ArchiveEntry(path: "dir/b.txt", size: 10),
                      ArchiveEntry(path: "dir/c.txt", size: 10)], for: other)
        tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(other), writing("/Users/me/Desktop/dir/b.txt", size: 5)])])
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.result == "/Users/me/Desktop")
        #expect(extraction.revealPaths == ["/Users/me/Desktop/a.txt", "/Users/me/Desktop/dir"])
    }

    @Test func eachExtractionHasANumberOfItsOwn() {
        mac.setIndex([ArchiveEntry(path: "a.bin", size: 10)], for: archive)
        mac.put(.file(size: 10), at: "/d/a.bin")
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/d/a.bin", size: 5)])])
        _ = tracker.step(now: 1, processes: [macPacker([])])
        _ = tracker.step(now: 2, processes: [macPacker([reading(archive), writing("/d/a.bin", size: 5)])])
        #expect(tracker.ended.map(\.id) == [1])
        #expect(tracker.extractions.map(\.id) == [2])
    }

    // MARK: Gone through to the end, but not all of it there

    /// A run of 12 Oct: an archive damaged in its middle.
    /// MacPacker went through it to its end and left out the 47 files it
    /// couldn't read. The last file being there, that was reported complete.
    @Test func goneThroughToTheEndWithFilesLeftOutIsNotComplete() throws {
        mac.setIndex((0..<1_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 100) }, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/d/many/file 3.bin", size: 50)])])
        for file in 0..<1_000 where (600..<647).contains(file) == false {
            mac.put(.file(size: 100), at: "/d/many/file \(file).bin")
        }
        let lines = tracker.step(now: 9, processes: [macPacker([])])
        #expect(lines.last == "big.rar: not complete after 9.0 s: 47 of its 1,000 files are missing or cut short; at /d/many")
        #expect(tracker.ended.last?.ending == .incomplete)
    }

    @Test func aFileCutShortInTheMiddleIsNotComplete() throws {
        mac.setIndex((0..<10).map { ArchiveEntry(path: "f\($0)", size: 100) }, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/d/f0", size: 50)])])
        for file in 0..<10 {
            mac.put(.file(size: file == 4 ? 60 : 100), at: "/d/f\(file)")
        }
        let lines = tracker.step(now: 2, processes: [macPacker([])])
        #expect(lines.last == "big.rar: not complete after 2.0 s: 1 of its 10 files is missing or cut short; at /d")
    }

    @Test func whatEndsUpAsOneFileOrIsNoPlainFileIsNotCountedMissing() throws {
        mac.setIndex([
            ArchiveEntry(path: "Readme.txt", size: 10),
            ArchiveEntry(path: "README.TXT", size: 20),          // the same file, on a Mac
            ArchiveEntry(path: "twice.bin", size: 5),
            ArchiveEntry(path: "twice.bin", size: 7),            // held twice
            ArchiveEntry(path: "link", size: 0),                 // a link: there, but no plain file
            ArchiveEntry(path: "empty", size: 0),
            ArchiveEntry(path: "last.bin", size: 100),
        ], for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/d/last.bin", size: 50)])])
        mac.put(.file(size: 20), at: "/d/README.TXT")
        mac.put(.file(size: 7), at: "/d/twice.bin")
        mac.put(.other, at: "/d/link")
        mac.put(.file(size: 0), at: "/d/empty")
        mac.put(.file(size: 100), at: "/d/last.bin")
        #expect(tracker.step(now: 1, processes: [macPacker([])]).last?.hasPrefix("big.rar: complete") == true)
    }

    @Test func twoMacPackersEachHaveTheirOwnExtraction() {
        mac.setIndex([ArchiveEntry(path: "a.bin", size: 1_000)], for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [
            macPacker([reading(archive), writing("/d/one/a.bin", size: 100)], pid: 500),
            macPacker([reading(archive), writing("/d/two/a.bin", size: 300)], pid: 501),
        ])
        #expect(tracker.extractions.map(\.written).sorted() == [100, 300])
        #expect(tracker.extractions.compactMap(\.destination).sorted() == ["/d/one", "/d/two"])
    }

    @Test func onlyTheLastEndedExtractionsAreKept() {
        mac.setIndex([ArchiveEntry(path: "a.bin", size: 10)], for: archive)
        var tracker = mac.tracker()
        mac.put(.file(size: 10), at: "/d/a.bin")
        for round in 0..<30 {
            let now = Double(round)
            _ = tracker.step(now: now, processes: [macPacker([reading(archive), writing("/d/a.bin", size: 5)])])
            _ = tracker.step(now: now + 0.5, processes: [macPacker([])])
        }
        #expect(tracker.ended.count == Tracker.endedKept)
        #expect(tracker.ended.allSatisfy { $0.ending == .complete })
    }
}
