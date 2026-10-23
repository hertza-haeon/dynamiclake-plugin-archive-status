// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// MacPacker from 23 Oct 2026 on (its main branch; seen on a real Mac in a
/// build of it): extracting a whole archive, it writes into a hidden folder
/// of its own in the destination, `.MacPacker-<a random id>`, and moves
/// what it extracted out of it at the end: the folder itself, renamed after
/// the archive, when the archive needs a folder of its own, or else each
/// item at its top, under its own name or the next free one, numbered the
/// way Archive Utility numbers them (`photos 2`, `notes 2.txt`). Nothing
/// already there is replaced.
struct MacPackerHiddenWorkFolderTrackingTests {
    let mac = FakeMac()
    let archive = "/Users/me/Downloads/big.zip"
    let hidden = "/Users/me/Downloads/.MacPacker-6F1C2A9E-3B7D-4C55-9E21-0D8A4B6F7C13"

    /// Two loose files, which go into a folder named after the archive: the
    /// hidden folder becomes that folder.
    @Test func theHiddenFolderRenamedAfterTheArchiveIsTheResult() throws {
        mac.setIndex([ArchiveEntry(path: "a.txt", size: 1_000), ArchiveEntry(path: "b.txt", size: 2_000)], for: archive)
        var tracker = mac.tracker()
        mac.put(.folder(items: nil), at: hidden)

        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.5, processes: [macPacker([reading(archive), writing("\(hidden)/b.txt", size: 500)])])
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.destination == hidden)

        mac.put(.missing, at: hidden)
        mac.put(.folder(items: nil), at: "/Users/me/Downloads/big")
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/big/a.txt")
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/big/b.txt")
        _ = tracker.step(now: 1.0, processes: [macPacker([])])

        #expect(tracker.extractions.isEmpty)
        extraction = try #require(tracker.ended.last)
        #expect(extraction.ending == .complete)
        #expect(extraction.destination == "/Users/me/Downloads/big")
    }

    /// One folder at the top: it moves out of the hidden folder, as
    /// `photos 2` where an earlier `photos` is.
    @Test func itemsMovedOutTakeArchiveUtilitysNumbers() throws {
        mac.setIndex([ArchiveEntry(path: "photos", size: 0, isFolder: true),
                      ArchiveEntry(path: "photos/a.jpg", size: 1_000),
                      ArchiveEntry(path: "photos/b.jpg", size: 2_000)], for: archive)
        var tracker = mac.tracker()
        mac.put(.folder(items: nil), at: hidden)
        // An earlier extraction's folder, long before this one.
        mac.put(.folder(items: nil), at: "/Users/me/Downloads/photos", changedAt: 1_000)
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/photos/b.jpg", changedAt: 1_000)

        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.5, processes: [macPacker([reading(archive), writing("\(hidden)/photos/b.jpg", size: 500)])])

        mac.put(.missing, at: hidden)
        mac.put(.folder(items: nil), at: "/Users/me/Downloads/photos 2")
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/photos 2/a.jpg")
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/photos 2/b.jpg")
        _ = tracker.step(now: 1.0, processes: [macPacker([])])

        let extraction = try #require(tracker.ended.last)
        #expect(extraction.ending == .complete)
        #expect(extraction.destination == "/Users/me/Downloads")
        #expect(extraction.result == "/Users/me/Downloads/photos 2")
    }

    /// Seen on a real Mac (23 Oct 2026): Finder's Extract to "name" makes
    /// the folder `findertest`, and MacPacker extracts into a hidden folder
    /// in it, then moves its 30,000 items out one by one, for longer than
    /// the moment waited for. It showed Stopped at 100 %. The wait lasts
    /// while the work folder keeps changing.
    @Test func itemsMovedOutOneByOneAreWaitedFor() throws {
        let made = "/Users/me/Downloads/big"
        let work = "\(made)/.MacPacker-85714173-50AE-4F79-A426-C53E310EA37A"
        let files = (0..<3).map { ArchiveEntry(path: "file \($0).bin", size: 1_000) }
        mac.setIndex(files, for: archive)
        var tracker = mac.tracker()
        mac.put(.folder(items: nil), at: made)
        mac.put(.folder(items: nil), at: work)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.5, processes: [macPacker([reading(archive), writing("\(work)/file 1.bin", size: 500)])])
        #expect(tracker.extractions.first?.destination == work)

        // The archive let go of; the items still going out of the work
        // folder, which changes with each.
        var now = 1.0
        while now < 1.0 + 3 * Tracker.unarchiverFinishWait {
            mac.clock += 0.5
            mac.put(.folder(items: nil), at: work)
            _ = tracker.step(now: now, processes: [macPacker([])])
            #expect(tracker.ended.isEmpty, "still moving its items out")
            now += 0.5
        }

        mac.clock += 0.5
        mac.put(.missing, at: work)
        for file in files {
            mac.put(.file(size: 1_000), at: "\(made)/\(file.path)")
        }
        _ = tracker.step(now: now, processes: [macPacker([])])
        let extraction = try #require(tracker.ended.last)
        #expect(extraction.ending == .complete)
        #expect(extraction.destination == made)
    }

    /// Cancelled: MacPacker deletes its hidden folder and puts nothing in
    /// place.
    @Test func theHiddenFolderGoneWithNothingInPlaceIsAStop() throws {
        mac.setIndex([ArchiveEntry(path: "a.txt", size: 1_000), ArchiveEntry(path: "b.txt", size: 2_000)], for: archive)
        var tracker = mac.tracker()
        mac.put(.folder(items: nil), at: hidden)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.5, processes: [macPacker([reading(archive), writing("\(hidden)/a.txt", size: 500)])])

        mac.put(.missing, at: hidden)
        _ = tracker.step(now: 1.0, processes: [macPacker([])])
        let extraction = try #require(tracker.ended.last)
        #expect(extraction.ending == .stopped)
    }

    /// Without a file caught being written, the beginning is found in the
    /// hidden folder, whose name can't be guessed: it is looked for in the
    /// places MacPacker extracts to that changed since it opened the
    /// archive. Beside the archive, and in the folder Finder's Extract to
    /// "name" makes for it.
    @Test(arguments: [
        "/Users/me/Downloads",
        "/Users/me/Downloads/big",
    ])
    func theBeginningIsFoundInTheHiddenFolder(place: String) throws {
        mac.setIndex([ArchiveEntry(path: "many", size: 0, isFolder: true)]
            + (0..<1_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 100) }, for: archive)
        var tracker = mac.tracker()
        #expect(tracker.step(now: 0, processes: [macPacker([reading(archive)])]).isEmpty)
        #expect(tracker.step(now: 0.1, processes: [macPacker([reading(archive)])]).isEmpty)
        let work = "\(place)/.MacPacker-0B3E5D1A-77C2-4F0E-A6B9-5E2C8D4F1A90"
        mac.put(.folder(items: nil), at: place)
        mac.put(.folder(items: nil), at: work)
        for file in 0..<10 {
            mac.put(.file(size: 100), at: "\(work)/many/file \(file).bin")
        }
        _ = tracker.step(now: 0.2, processes: [macPacker([reading(archive)])])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.destination == work)
    }

    /// A folder is listed when it has changed since MacPacker opened the
    /// archive, and again only once it changes again: not at every look.
    @Test func aFolderIsListedOnlyWhenItChanges() {
        mac.setIndex([ArchiveEntry(path: "many", size: 0, isFolder: true)]
            + (0..<1_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 100) }, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.1, processes: [macPacker([reading(archive)])])
        #expect(mac.hiddenListings.isEmpty, "nothing has changed since the archive was opened")

        mac.put(.folder(items: nil), at: "/Users/me/Downloads")
        for look in 2..<12 {
            _ = tracker.step(now: Double(look) / 10, processes: [macPacker([reading(archive)])])
        }
        #expect(mac.hiddenListings == ["/Users/me/Downloads"])

        mac.clock += 1
        mac.put(.folder(items: nil), at: "/Users/me/Downloads")
        _ = tracker.step(now: 1.3, processes: [macPacker([reading(archive)])])
        #expect(mac.hiddenListings == ["/Users/me/Downloads", "/Users/me/Downloads"])
    }

    /// Another program's hidden folder, or an old one of MacPacker's from
    /// before the archive was opened, is no beginning.
    @Test func anOlderHiddenFolderIsNoBeginning() {
        mac.setIndex([ArchiveEntry(path: "many", size: 0, isFolder: true)]
            + (0..<1_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 100) }, for: archive)
        // Left by a run that MacPacker didn't see to its end, long before.
        let old = "/Users/me/Downloads/.MacPacker-11111111-2222-3333-4444-555555555555"
        mac.put(.folder(items: nil), at: old, changedAt: 1_000)
        for file in 0..<10 {
            mac.put(.file(size: 100), at: "\(old)/many/file \(file).bin", changedAt: 1_000)
        }
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        mac.put(.folder(items: nil), at: "/Users/me/Downloads")
        _ = tracker.step(now: 0.1, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.2, processes: [macPacker([reading(archive)])])
        #expect(tracker.extractions.isEmpty)
    }

    /// The case seen on the real Mac (23 Oct 2026): 15,000 files of 16 KB,
    /// none of them caught being written, the hidden folder renamed
    /// `loose` at the end, the archive let go of right after (MacPacker
    /// moved it to the Bin, as set). It showed nothing at all.
    @Test func manySmallFilesNoneCaughtAreFollowedToTheirEnd() throws {
        let loose = "/Users/me/Downloads/loose.zip"
        let files = (0..<1_000).map { ArchiveEntry(path: "file \($0).bin", size: 16_384) }
        mac.setIndex(files, for: loose)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(loose, size: 16_500_000)])])
        _ = tracker.step(now: 0.1, processes: [macPacker([reading(loose, size: 16_500_000)])])

        // Extracting: the archive read through, the files in the hidden folder.
        mac.put(.folder(items: nil), at: "/Users/me/Downloads")
        mac.put(.folder(items: nil), at: hidden)
        for file in 0..<400 {
            mac.put(.file(size: 16_384), at: "\(hidden)/file \(file).bin")
        }
        let lines = tracker.step(now: 0.2, processes: [macPacker([reading(loose, size: 16_500_000, at: 6_000_000)])])
        #expect(lines.contains { $0.hasPrefix("loose.zip: MacPacker is extracting it") })

        // Done: the hidden folder is `loose`, and the archive goes.
        mac.put(.missing, at: hidden)
        mac.put(.folder(items: nil), at: "/Users/me/Downloads/loose")
        for file in 0..<1_000 {
            mac.put(.file(size: 16_384), at: "/Users/me/Downloads/loose/file \(file).bin")
        }
        _ = tracker.step(now: 0.6, processes: [macPacker([])])
        let extraction = try #require(tracker.ended.last)
        #expect(extraction.name == "loose.zip")
        #expect(extraction.ending == .complete)
        #expect(extraction.destination == "/Users/me/Downloads/loose")
    }

    /// The names a taken name gets, Archive Utility's way: a number before
    /// a file's ending, the whole ending of a compressed tar kept, a
    /// folder's name never cut at a dot.
    @Test(arguments: [
        ("photos", true, ["photos", "photos 2", "photos 3"]),
        ("my.photos", true, ["my.photos", "my.photos 2", "my.photos 3"]),
        ("notes.txt", false, ["notes.txt", "notes 2.txt", "notes 3.txt"]),
        ("archive.tar.gz", false, ["archive.tar.gz", "archive 2.tar.gz", "archive 3.tar.gz"]),
        (".hidden", false, [".hidden", ".hidden 2", ".hidden 3"]),
        ("README", false, ["README", "README 2", "README 3"]),
    ])
    func archiveUtilitysNumbers(name: String, isFolder: Bool, expected: [String]) {
        let names = Tracker.numbered(name, isFolder: isFolder, numbering: .archiveUtility, in: "/x")
        #expect(Array(names.prefix(3)) == expected.map { "/x/" + $0 })
    }

    /// MacPacker's work folders, as they are known.
    @Test(arguments: [
        ("/Users/me/Downloads/.MacPacker-6F1C2A9E-3B7D-4C55-9E21-0D8A4B6F7C13/photos", "/Users/me/Downloads/.MacPacker-6F1C2A9E-3B7D-4C55-9E21-0D8A4B6F7C13"),
        ("/Users/me/Downloads/photos.macpack/a.jpg", "/Users/me/Downloads/photos.macpack"),
        ("/Users/me/Downloads/.MacPacker-", nil),
        ("/Users/me/Downloads/MacPacker-6F1C/photos", nil),
        ("/Users/me/Downloads/photos", nil),
    ])
    func macPackersWorkFoldersAreKnown(place: String, work: String?) {
        #expect(Tracker.macPackerWorkFolder(of: place) == work)
    }
}
