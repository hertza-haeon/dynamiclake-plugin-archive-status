// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// MacPacker and a compressed tar (`tar.gz` and the like), as seen on a
/// real Mac on 12 Oct 2026 and in MacPacker's source: when the archive is
/// opened, MacPacker unpacks it into a plain tar among its own files, and
/// whatever it extracts later comes from that copy, whose name says nothing.
/// (macOS doesn't let the plugin read that copy: what is in the archive is
/// read from the archive itself.)
struct MacPackerCopyTrackingTests {
    let mac = FakeMac()
    let archive = "/Users/me/Downloads/6 no index.tar.gz"
    let copy = "/Users/me/Library/Containers/com.sarensx.MacPacker/Data/Library/Caches/ta/5B11BA9C-A1B2-4998-B832-59CDEEA02A4A/unknown"
    let copySize: UInt64 = 1_613_187_584
    let entries = (0..<1_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 8_192) }

    /// The archive is opened: MacPacker reads it through and writes its
    /// copy, in 2.2 seconds on the real Mac. Returns the lines for the log.
    private func unpack(_ tracker: inout Tracker, _ archive: String, into copy: String, from start: Double = 0,
                        pid: Int32 = 500) -> [String] {
        var lines: [String] = []
        for look in 0...21 {
            lines += tracker.step(now: start + Double(look) / 10, processes: [macPacker([
                reading(archive, size: 11_344_275, at: UInt64(min(look / 2 + 1, 10)) * 1_048_576),
                writing(copy, size: UInt64(look + 1) * 73_000_000),
            ], pid: pid)])
        }
        lines += tracker.step(now: start + 2.2, processes: [macPacker([], pid: pid)])
        return lines
    }

    private func file(_ number: Int) -> String {
        "/Users/me/Downloads/many/file \(number).bin"
    }

    @Test func theCopyBeingMadeIsNoExtraction() {
        mac.setIndex(entries, format: .compressedTar, for: archive)
        var tracker = mac.tracker()
        #expect(unpack(&tracker, archive, into: copy).isEmpty)
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.ended.isEmpty)
        #expect(tracker.attention == .none)
        #expect(mac.indexReads.isEmpty)
    }

    @Test func whatIsExtractedFromTheCopyGoesByTheArchivesName() throws {
        mac.setIndex(entries, format: .compressedTar, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)

        // A minute later the extraction is asked for: MacPacker reads its
        // copy, first through its headers, and writes nothing yet.
        #expect(tracker.step(now: 60, processes: [macPacker([reading(copy, size: copySize, at: 900_000_000)])]).isEmpty)
        #expect(tracker.attention == .close)
        #expect(mac.indexReads.isEmpty)

        // The first file caught being written: the archive's index is read.
        var lines = tracker.step(now: 60.3, processes: [
            macPacker([reading(copy, size: copySize, at: 131_072), writing(file(9), size: 4_000)]),
        ])
        #expect(lines == [
            "6 no index.tar.gz: MacPacker is extracting it: 8.2 MB in 1,000 files (compressed tar, extracted from what "
                + "MacPacker unpacked it into), into /Users/me/Downloads",
            "6 no index.tar.gz: 0 % · 77.7 KB of 8.2 MB · file 10 of 1,000",
        ])
        #expect(mac.indexReads == [archive])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.name == "6 no index.tar.gz")
        #expect(extraction.archivePath == archive)
        #expect(extraction.tool == .macPacker)
        #expect(extraction.total == 8_192_000)
        #expect(extraction.fileCount == 1_000)
        #expect(extraction.measuresArchive == false)
        #expect(extraction.result == "/Users/me/Downloads/many")

        lines = tracker.step(now: 61.5, processes: [
            macPacker([reading(copy, size: copySize, at: 800_000_000), writing(file(499), size: 8_192)]),
        ])
        #expect(lines == ["6 no index.tar.gz: 50 % · 4.1 MB of 8.2 MB · 3.3 MB/s · file 500 of 1,000"])

        // The copy is let go of, and every file is there, whole.
        for number in 0..<1_000 {
            mac.put(.file(size: 8_192), at: file(number))
        }
        lines = tracker.step(now: 63, processes: [macPacker([])])
        #expect(lines.last == "6 no index.tar.gz: complete: 8.2 MB in 2.7 s; at /Users/me/Downloads/many")
        #expect(tracker.ended.last?.ending == .complete)
        #expect(tracker.attention == .none)
    }

    @Test func aCancelWhileExtractingFromTheCopyIsStopped() throws {
        mac.setIndex(entries, format: .compressedTar, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        _ = tracker.step(now: 60, processes: [macPacker([reading(copy, size: copySize), writing(file(0), size: 100)])])
        for number in 0..<300 {
            mac.put(.file(size: 8_192), at: file(number))
        }
        let lines = tracker.step(now: 62, processes: [macPacker([])])
        #expect(lines.last?.hasPrefix("6 no index.tar.gz: stopped short at ") == true)
        #expect(tracker.ended.last?.ending == .stopped)
    }

    /// The extraction asked for a second time is one of its own.
    @Test func theCopyServesMoreThanOneExtraction() throws {
        mac.setIndex(entries, format: .compressedTar, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        for start in [60.0, 120.0] {
            _ = tracker.step(now: start, processes: [macPacker([reading(copy, size: copySize), writing(file(0), size: 100)])])
            for number in 0..<1_000 {
                mac.put(.file(size: 8_192), at: file(number))
            }
            _ = tracker.step(now: start + 5, processes: [macPacker([])])
        }
        #expect(tracker.ended.map(\.name) == ["6 no index.tar.gz", "6 no index.tar.gz"])
        #expect(tracker.ended.map(\.ending) == [.complete, .complete])
        #expect(Set(tracker.ended.map(\.id)).count == 2)
    }

    /// Seen on a real Mac, 13 Oct 2026: a `tar.bz2` of 492 MB opened in
    /// MacPacker, then extracted from MacPacker's copy in under a second,
    /// showed nothing (no list: the card came and went in one look). Its
    /// list is read beside the loop from the moment MacPacker unpacks it,
    /// kept while MacPacker keeps its copy, and there when the extraction
    /// is asked for.
    @Test func aLargeArchivesListIsReadBesideTheLoopWhileMacPackerUnpacksIt() throws {
        mac.setIndexFailure(.tooLarge, for: archive)
        var tracker = mac.tracker()
        #expect(unpack(&tracker, archive, into: copy).isEmpty)
        #expect(mac.laterBegun == [archive])
        #expect(mac.indexReads.isEmpty, "the loop didn't stand still for it")
        #expect(mac.laterDropped.isEmpty, "kept: MacPacker has its copy to extract from")
        // The list is read meanwhile. A minute later the extraction is
        // asked for, and its first files are there.
        mac.finishLaterIndex(entries, for: archive)
        mac.clock += 60
        mac.put(.file(size: 8_192), at: file(0))
        mac.put(.file(size: 8_192), at: file(1))
        var lines = tracker.step(now: 60, processes: [macPacker([reading(copy, size: copySize, at: 900_000_000)])])
        #expect(lines.first == "6 no index.tar.gz: its list of contents is read: 8.2 MB in 1,000 files (compressed tar)")
        lines += tracker.step(now: 60.1, processes: [macPacker([reading(copy, size: copySize, at: 900_000_000)])])
        #expect(lines.contains { $0.hasPrefix("6 no index.tar.gz: MacPacker is extracting it: 8.2 MB in 1,000 files (compressed tar") })
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.total == 8_192_000)
        #expect(extraction.measuresArchive == false)
        // All of it written, the copy still held: complete.
        for number in 0..<1_000 {
            mac.put(.file(size: 8_192), at: file(number))
        }
        _ = tracker.step(now: 61, processes: [macPacker([reading(copy, size: copySize, at: copySize)])])
        _ = tracker.step(now: 62, processes: [macPacker([])])
        #expect(tracker.ended.last?.ending == .complete)
    }

    /// MacPacker gone, its copy is gone with it: the list isn't read on.
    @Test func theListIsGivenUpWhenMacPackerIsGone() {
        mac.setIndexFailure(.tooLarge, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        #expect(mac.laterDropped.isEmpty)
        _ = tracker.step(now: 10, processes: [])
        _ = tracker.step(now: 11, processes: [])
        #expect(mac.laterDropped == [archive])
    }

    /// The archive may take too long to read, or hold no tar: then how
    /// far MacPacker has read into its copy is the measure, of the copy's
    /// size.
    @Test(arguments: [
        (IndexError.tooLarge, "it takes long to read: its list is being read meanwhile"),
        (.notAnArchive, "this kind of archive has no index to read"),
        (.unreadable, "the archive can't be read"),
    ])
    func withoutAnIndexTheCopysReadingIsFollowed(error: IndexError, why: String) throws {
        mac.setIndexFailure(error, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        var lines = tracker.step(now: 60, processes: [
            macPacker([reading(copy, size: copySize, at: 161_318_758), writing(file(3), size: 100)]),
        ])
        #expect(lines == [
            "6 no index.tar.gz: MacPacker is extracting it; no total to read (\(why)), "
                + "so it is followed by how far what MacPacker unpacked it into has been read, of its 1.61 GB",
            "6 no index.tar.gz: 9 % · 161.3 MB of 1.61 GB of the archive read",
        ])
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.name == "6 no index.tar.gz")
        #expect(extraction.measuresArchive)
        #expect(extraction.total == copySize)
        #expect(extraction.written == 161_318_758)

        // Nothing caught being written at this look: the reading goes on.
        _ = tracker.step(now: 61, processes: [macPacker([reading(copy, size: copySize, at: 806_593_792)])])
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 806_593_792)

        // Without an index, whether it got to its end can't be told. (A
        // list being read beside the loop is waited for first.)
        lines = tracker.step(now: 62, processes: [macPacker([])])
        if error == .tooLarge {
            #expect(tracker.ended.isEmpty, "the list may yet come")
            mac.clock += Tracker.listWait + 1
            lines = tracker.step(now: 83, processes: [macPacker([])])
        }
        #expect(tracker.ended.last?.ending == .unknown)
    }

    /// Seen on a real Mac, 13 Oct 2026: MacPacker opened a `tar.bz2`
    /// (sixteen seconds to unpack into its copy), and the extraction from
    /// the copy was asked for at once and over in under a second, four
    /// seconds before the plugin had read the archive's list. Nothing
    /// showed. Now the list is waited for, and the archive's first files
    /// are looked for where MacPacker puts them.
    @Test func anExtractionOverBeforeTheListIsReadIsTakenUpFromWhatItLeft() throws {
        mac.setIndexFailure(.tooLarge, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        // Asked for at once: MacPacker has its copy for half a second, and
        // not one file is caught being written.
        var lines = tracker.step(now: 2.4, processes: [macPacker([reading(copy, size: copySize, at: 900_000_000)])])
        lines += tracker.step(now: 2.6, processes: [macPacker([reading(copy, size: copySize, at: copySize)])])
        for number in 0..<1_000 {
            mac.put(.file(size: 8_192), at: file(number))
        }
        lines += tracker.step(now: 2.9, processes: [macPacker([])])
        #expect(lines.isEmpty)
        #expect(tracker.attention == .close, "not let go of yet: its list is on its way")
        // The list is there four seconds later.
        mac.clock += 4
        mac.finishLaterIndex(entries, for: archive)
        lines = tracker.step(now: 6.9, processes: [macPacker([])])
        #expect(lines.first == "6 no index.tar.gz: its list of contents is read: 8.2 MB in 1,000 files (compressed tar)")
        #expect(lines.contains { $0.hasPrefix("6 no index.tar.gz: MacPacker is extracting it: 8.2 MB in 1,000 files (compressed tar") })
        #expect(tracker.extractions.count == 1, "under way for a look, so that it gets its card")
        lines = tracker.step(now: 7.0, processes: [macPacker([])])
        #expect(lines.last?.hasPrefix("6 no index.tar.gz: complete: 8.2 MB in") == true)
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .complete)
        #expect(ended.result == "/Users/me/Downloads/many")
    }

    /// The same when the list never comes: nothing is said, and the wait
    /// ends.
    @Test func withoutAListInTimeAnExtractionNobodySawIsNotMadeUp() {
        mac.setIndexFailure(.tooLarge, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        _ = tracker.step(now: 2.4, processes: [macPacker([reading(copy, size: copySize, at: 900_000_000)])])
        _ = tracker.step(now: 2.6, processes: [macPacker([reading(copy, size: copySize, at: copySize)])])
        #expect(tracker.step(now: 2.9, processes: [macPacker([])]).isEmpty)
        mac.clock += Tracker.listWait + 1
        #expect(tracker.step(now: 24, processes: [macPacker([])]).isEmpty)
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.ended.isEmpty)
        #expect(tracker.attention == .none)
    }

    /// The list is there, and MacPacker only looked into its copy: nothing
    /// was extracted, and nothing is said.
    @Test func lookingIntoTheCopyWithItsListReadIsNoExtraction() {
        mac.setIndexFailure(.tooLarge, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        mac.finishLaterIndex(entries, for: archive)
        mac.clock += 30
        var lines = tracker.step(now: 30, processes: [macPacker([reading(copy, size: copySize, at: 900_000_000)])])
        lines += tracker.step(now: 30.3, processes: [macPacker([])])
        lines += tracker.step(now: 30.4, processes: [macPacker([])])
        #expect(lines == ["6 no index.tar.gz: its list of contents is read: 8.2 MB in 1,000 files (compressed tar)"])
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.ended.isEmpty)
    }

    /// A file of it was caught being written before the list was there:
    /// followed without it, and at the end the list is waited for and the
    /// files looked at by it, where the file caught says they went.
    @Test func followedWithoutItsListThenLookedAtByItAtTheEnd() throws {
        mac.setIndexFailure(.tooLarge, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        mac.clock += 4                                   // (the reading beside the loop has gone on longer than a look may)
        var lines = tracker.step(now: 6, processes: [macPacker([reading(copy, size: copySize, at: 161_318_758), writing(file(3), size: 100)])])
        #expect(lines.first?.contains("MacPacker is extracting it; no total to read (it takes long to read") == true)
        #expect(mac.indexReads.isEmpty, "no second try at once")
        for number in 0..<1_000 {
            mac.put(.file(size: 8_192), at: file(number))
        }
        lines = tracker.step(now: 6.5, processes: [macPacker([])])
        #expect(tracker.ended.isEmpty, "the list may yet come")
        mac.finishLaterIndex(entries, for: archive)
        lines = tracker.step(now: 8, processes: [macPacker([])])
        #expect(lines.contains { $0.contains("its list of contents is read") })
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .complete)
        #expect(ended.result == "/Users/me/Downloads/many")
    }

    /// Seen on a real Mac (12 Oct, 150,000 files): MacPacker reads its
    /// copy through twice, once to see what is in it and once to extract,
    /// and then keeps it open for 45 seconds more, writing nothing. With
    /// everything written, that is no standstill.
    @Test func theCopyHeldAfterTheLastFileIsNotAStandstill() throws {
        mac.setIndex(entries, format: .compressedTar, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        var lines: [String] = []
        // Through its headers, to the end; nothing written yet.
        lines += tracker.step(now: 60, processes: [macPacker([reading(copy, size: copySize, at: 1_013_236_224)])])
        lines += tracker.step(now: 60.5, processes: [macPacker([reading(copy, size: copySize, at: copySize)])])
        #expect(lines.isEmpty)
        // Then from its beginning again, extracting.
        _ = tracker.step(now: 61, processes: [macPacker([reading(copy, size: copySize, at: 385_024), writing(file(0), size: 100)])])
        for number in 0..<1_000 {
            mac.put(.file(size: 8_192), at: file(number))
        }
        lines = []
        for second in 62...107 {
            lines += tracker.step(now: Double(second), processes: [macPacker([reading(copy, size: copySize, at: copySize - 1_024)])])
        }
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 8_192_000)
        #expect(extraction.stalledSince == nil)
        #expect(lines.contains { $0.contains("stalled") } == false)
        lines = tracker.step(now: 108, processes: [macPacker([])])
        #expect(lines.last == "6 no index.tar.gz: complete: 8.2 MB in 47.0 s; at /Users/me/Downloads/many")
    }

    /// The same where the copy has no index to go by: read to its end (a
    /// tar's last blocks are empty and needn't be read), it isn't stalled.
    /// Stopped in its middle, it is.
    @Test(arguments: [(UInt64(1_613_186_560), false), (806_593_792, true)])
    func aCopyReadToItsEndAndHeldIsNotAStandstill(position: UInt64, stalls: Bool) throws {
        mac.setIndexFailure(.tooLarge, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        _ = tracker.step(now: 60, processes: [macPacker([reading(copy, size: copySize, at: 100_000_000), writing(file(0), size: 100)])])
        var lines: [String] = []
        for second in 61...107 {
            lines += tracker.step(now: Double(second), processes: [macPacker([reading(copy, size: copySize, at: position)])])
        }
        #expect((tracker.extractions.first?.stalledSince != nil) == stalls)
        #expect(lines.contains { $0.contains("stalled: nothing written for 15 s") } == stalls)
    }

    /// The copy is known by having been seen while it was made. Unpacked
    /// between two looks, it stays a file whose name says nothing: nothing
    /// is shown, rather than a card that can't name its archive.
    @Test func aCopyNeverSeenBeingMadeIsNotFollowed() {
        mac.setIndex(entries, format: .compressedTar, for: archive)
        var tracker = mac.tracker()
        let lines = tracker.step(now: 0, processes: [macPacker([reading(copy, size: copySize, at: 5_000), writing(file(1), size: 100)])])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.attention == .none)
        #expect(mac.indexReads.isEmpty)
    }

    /// An archive taken out of another archive to be looked into is a copy
    /// too, but it has a name of its own: it goes by that, as before.
    @Test func anArchiveTakenOutOfAnotherKeepsItsOwnName() throws {
        let outer = "/Users/me/Downloads/outer.zip"
        let inner = "/Users/me/Library/Containers/com.sarensx.MacPacker/Data/Library/Caches/ta/0A0A/inner.zip"
        mac.setIndex([ArchiveEntry(path: "photo.jpg", size: 5_000)], for: inner)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(outer), writing(inner, size: 3_000)])])
        _ = tracker.step(now: 1, processes: [macPacker([])])
        _ = tracker.step(now: 5, processes: [
            macPacker([reading(inner), writing("/Users/me/Downloads/inner/photo.jpg", size: 1_000)]),
        ])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.name == "inner.zip")
        #expect(extraction.archivePath == inner)
    }

    @Test func eachCopyBelongsToTheArchiveReadWhileItWasMade() throws {
        let second = "/Users/me/Desktop/sources.tgz"
        let secondCopy = "/Users/me/Library/Containers/com.sarensx.MacPacker/Data/Library/Caches/ta/77AA/unknown"
        mac.setIndex(entries, format: .compressedTar, for: archive)
        mac.setIndex([ArchiveEntry(path: "src/main.c", size: 900)], format: .compressedTar, for: second)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        _ = unpack(&tracker, second, into: secondCopy, from: 10)

        _ = tracker.step(now: 60, processes: [
            macPacker([reading(secondCopy, size: 10_240), writing("/Users/me/Desktop/src/main.c", size: 100)]),
        ])
        #expect(tracker.extractions.map(\.name) == ["sources.tgz"])
        _ = tracker.step(now: 60.1, processes: [
            macPacker([reading(secondCopy, size: 10_240), reading(copy, size: copySize), writing(file(5), size: 100)]),
        ])
        #expect(tracker.extractions.map(\.name) == ["sources.tgz", "6 no index.tar.gz"])
    }

    /// Two compressed archives read at the same moment: which copy is
    /// whose can't be told, and isn't guessed.
    @Test func twoArchivesUnpackedAtTheSameMomentAreNotGuessedAt() {
        let second = "/Users/me/Desktop/sources.tgz"
        mac.setIndex(entries, format: .compressedTar, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), reading(second), writing(copy, size: 5_000_000)])])
        _ = tracker.step(now: 1, processes: [macPacker([])])
        let lines = tracker.step(now: 9, processes: [macPacker([reading(copy, size: copySize), writing(file(1), size: 100)])])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.isEmpty)
    }

    /// Seen on a real Mac, 23 Oct 2026: a `tar.gz` cut into numbered
    /// pieces. MacPacker has every piece open while it unpacks them into
    /// its copy, which it names after the tar inside (`big.tar`). What it
    /// extracted from the copy then went by the copy's name, was followed
    /// by how far the copy was read, and showed Stopped once done. The
    /// pieces are one archive: the copy is theirs.
    @Test(arguments: [
        ["/Users/me/Downloads/trip.tar.gz"],
        ["/Users/me/Downloads/trip.tar.gz.001", "/Users/me/Downloads/trip.tar.gz.002", "/Users/me/Downloads/trip.tar.gz.003"],
    ])
    func whatIsExtractedFromTheCopyGoesByTheArchiveItWasUnpackedFrom(pieces: [String]) throws {
        let first = try #require(pieces.first)
        let tarCopy = "/Users/me/Library/Containers/com.sarensx.MacPacker.lab/Data/Library/Caches/ta/8DF5B201/big.tar"
        mac.setIndex(entries, format: .compressedTar, for: first)
        var tracker = mac.tracker()
        for look in 0...21 {
            _ = tracker.step(now: Double(look) / 10, processes: [macPacker(
                pieces.map { reading($0, size: 104_857_600, at: 3_145_728) }
                    + [writing(tarCopy, size: UInt64(look + 1) * 73_000_000)]
            )])
        }
        _ = tracker.step(now: 2.2, processes: [macPacker([])])

        _ = tracker.step(now: 60, processes: [
            macPacker([reading(tarCopy, size: copySize, at: 131_072), writing(file(9), size: 4_000)]),
        ])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.name == ArchiveName.fileName(of: first))
        #expect(extraction.archivePath == first)
        #expect(extraction.total == 8_192_000)
        #expect(extraction.measuresArchive == false)

        for number in 0..<1_000 {
            mac.put(.file(size: 8_192), at: file(number))
        }
        _ = tracker.step(now: 61, processes: [macPacker([])])
        #expect(tracker.ended.map(\.name) == [ArchiveName.fileName(of: first)])
        #expect(tracker.ended.last?.ending == .complete)
    }

    /// The same, with a list too long to read within a look (300 MB on
    /// the real Mac): it is read beside the loop, and kept while MacPacker
    /// keeps the copy of the pieces.
    @Test func theListOfAnArchiveInPiecesIsKeptWhileMacPackerKeepsItsCopy() throws {
        let pieces = ["/Users/me/Downloads/trip.tar.gz.001", "/Users/me/Downloads/trip.tar.gz.002"]
        let tarCopy = "/Users/me/Library/Containers/com.sarensx.MacPacker.lab/Data/Library/Caches/ta/8DF5B201/big.tar"
        mac.setIndexFailure(.tooLarge, for: pieces[0])
        var tracker = mac.tracker()
        for look in 0...21 {
            _ = tracker.step(now: Double(look) / 10, processes: [macPacker(
                pieces.map { reading($0, size: 104_857_600, at: 3_145_728) }
                    + [writing(tarCopy, size: UInt64(look + 1) * 73_000_000)]
            )])
        }
        _ = tracker.step(now: 2.2, processes: [macPacker([])])
        _ = tracker.step(now: 3, processes: [macPacker([])])
        #expect(mac.laterBegun == [pieces[0]])
        #expect(mac.laterDropped.isEmpty, "kept: MacPacker has its copy to extract from")

        mac.finishLaterIndex(entries, for: pieces[0])
        mac.clock += 60
        _ = tracker.step(now: 60, processes: [
            macPacker([reading(tarCopy, size: copySize, at: 131_072), writing(file(9), size: 4_000)]),
        ])
        _ = tracker.step(now: 60.1, processes: [
            macPacker([reading(tarCopy, size: copySize, at: 131_072), writing(file(10), size: 4_000)]),
        ])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.name == "trip.tar.gz.001")
        #expect(extraction.total == 8_192_000)
        #expect(extraction.measuresArchive == false)
        for number in 0..<1_000 {
            mac.put(.file(size: 8_192), at: file(number))
        }
        _ = tracker.step(now: 61, processes: [macPacker([])])
        #expect(tracker.ended.last?.ending == .complete)
    }

    @Test func aProgramThatIsGoneTakesItsCopiesWithIt() {
        mac.setIndex(entries, format: .compressedTar, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        #expect(tracker.step(now: 30, processes: []).isEmpty)
        // Another MacPacker, given the same number by macOS.
        let lines = tracker.step(now: 60, processes: [macPacker([reading(copy, size: copySize), writing(file(1), size: 100)])])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.isEmpty)
    }

    /// A look that can't be read is no sign that the program is gone.
    @Test func aLookThatCannotBeReadKeepsTheCopies() {
        mac.setIndex(entries, format: .compressedTar, for: archive)
        var tracker = mac.tracker()
        _ = unpack(&tracker, archive, into: copy)
        _ = tracker.step(now: 30, processes: [macPacker(nil)])
        _ = tracker.step(now: 60, processes: [macPacker([reading(copy, size: copySize), writing(file(1), size: 100)])])
        #expect(tracker.extractions.map(\.name) == ["6 no index.tar.gz"])
    }

    /// Only MacPacker's copies, and only where it keeps them.
    @Test(arguments: [
        ("/Users/me/Library/Containers/com.sarensx.MacPacker/Data/Library/Caches/ta/5B11/unknown", true),
        ("/Users/me/Library/Caches/ta/5B11/photos.tar", true),
        ("/Users/me/Library/Containers/com.sarensx.MacPacker/Data/Library/Caches/ta/5B11/folder/file.txt", false),
        ("/Users/me/Library/Containers/com.sarensx.MacPacker/Data/Library/Caches/ta/unknown", false),
        ("/Users/me/Library/Caches/other/5B11/unknown", false),
        ("/Users/me/Downloads/ta/5B11/unknown", false),
        ("unknown", false),
        ("", false),
    ])
    func macPackersCopiesAreKnownByWhereTheyAre(path: String, isCopy: Bool) {
        #expect(Tool.macPacker.keepsCopy(at: path) == isCopy)
        #expect(Tool.archiveUtility.keepsCopy(at: path) == false)
    }

    @Test(arguments: [
        ("photos.tar.gz", true), ("photos.tgz", true), ("photos.TAR.XZ", true), ("photos.tbz2", true), ("notes.txt.gz", true),
        ("photos.tar", false), ("photos.zip", false), ("photos.7z", false), ("photos.rar", false), ("unknown", false),
    ])
    func aCompressedArchiveIsKnownByItsName(name: String, isCompressed: Bool) {
        #expect(ArchiveName.isCompressed("/Users/me/Downloads/" + name) == isCompressed)
    }
}
