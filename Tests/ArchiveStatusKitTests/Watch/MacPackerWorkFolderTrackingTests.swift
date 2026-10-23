// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// A MacPacker that keeps a cancelled extraction from leaving anything
/// behind extracts into a work folder in the destination,
/// `<archive name>.macpack`, and puts the result in place at the end: the
/// work folder itself renamed, when the result is a folder made for the
/// archive, or else each item at its top moved up, under its own name or a
/// free one (`photos (2)`). The files followed while it extracts are then
/// gone from where they were written.
struct MacPackerWorkFolderTrackingTests {
    let mac = FakeMac()
    let archive = "/Users/me/Downloads/big.zip"
    let work = "/Users/me/Downloads/big.macpack"

    /// Two loose files, which MacPacker puts in a folder named after the
    /// archive: the work folder becomes that folder.
    @Test func aWorkFolderRenamedAfterTheArchiveIsTheResult() throws {
        mac.setIndex([ArchiveEntry(path: "a.txt", size: 1_000), ArchiveEntry(path: "b.txt", size: 2_000)], for: archive)
        var tracker = mac.tracker()
        mac.put(.folder(items: nil), at: work)

        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.5, processes: [macPacker([reading(archive), writing("\(work)/b.txt", size: 500)])])
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.destination == work)

        // Done: the work folder is renamed, then the archive let go of.
        mac.put(.missing, at: work)
        mac.put(.folder(items: nil), at: "/Users/me/Downloads/big")
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/big/a.txt")
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/big/b.txt")
        _ = tracker.step(now: 1.0, processes: [macPacker([])])

        #expect(tracker.extractions.isEmpty)
        extraction = try #require(tracker.ended.last)
        #expect(extraction.ending == .complete)
        #expect(extraction.destination == "/Users/me/Downloads/big")
    }

    /// One folder at the top, extracted as it is: it moves up out of the
    /// work folder, under a free name where its own is taken by an
    /// earlier one.
    @Test func itemsMovedUpUnderAFreeNameAreTheResult() throws {
        mac.setIndex([ArchiveEntry(path: "photos", size: 0, isFolder: true),
                      ArchiveEntry(path: "photos/a.jpg", size: 1_000),
                      ArchiveEntry(path: "photos/b.jpg", size: 2_000)], for: archive)
        var tracker = mac.tracker()
        mac.put(.folder(items: nil), at: work)
        // An earlier extraction's folder, long before this one.
        mac.put(.folder(items: nil), at: "/Users/me/Downloads/photos", changedAt: 1_000)
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/photos/b.jpg", changedAt: 1_000)

        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.5, processes: [macPacker([reading(archive), writing("\(work)/photos/b.jpg", size: 500)])])
        #expect(tracker.extractions.first?.destination == work)

        mac.put(.missing, at: work)
        mac.put(.folder(items: nil), at: "/Users/me/Downloads/photos (2)")
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/photos (2)/a.jpg")
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/photos (2)/b.jpg")
        _ = tracker.step(now: 1.0, processes: [macPacker([])])

        let extraction = try #require(tracker.ended.last)
        #expect(extraction.ending == .complete)
        #expect(extraction.destination == "/Users/me/Downloads")
        #expect(extraction.result == "/Users/me/Downloads/photos (2)")
    }

    /// Cancelled: MacPacker takes its work folder away and puts nothing in
    /// place.
    @Test func aWorkFolderGoneWithNothingInPlaceIsAStop() throws {
        mac.setIndex([ArchiveEntry(path: "a.txt", size: 1_000), ArchiveEntry(path: "b.txt", size: 2_000)], for: archive)
        var tracker = mac.tracker()
        mac.put(.folder(items: nil), at: work)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.5, processes: [macPacker([reading(archive), writing("\(work)/a.txt", size: 500)])])

        mac.put(.missing, at: work)
        _ = tracker.step(now: 1.0, processes: [macPacker([])])
        let extraction = try #require(tracker.ended.last)
        #expect(extraction.ending == .stopped)
    }

    /// MacPacker let go of the archive and its work folder stays: it puts
    /// the result in place right after, so a moment is waited; past it,
    /// it never will (it was quit mid-way).
    @Test func aWorkFolderThatStaysIsAStopOnceWaitedFor() throws {
        mac.setIndex([ArchiveEntry(path: "a.txt", size: 1_000), ArchiveEntry(path: "b.txt", size: 2_000)], for: archive)
        var tracker = mac.tracker()
        mac.put(.folder(items: nil), at: work)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        _ = tracker.step(now: 0.5, processes: [macPacker([reading(archive), writing("\(work)/a.txt", size: 500)])])

        _ = tracker.step(now: 1.0, processes: [macPacker([])])
        #expect(tracker.ended.isEmpty, "waited for")
        #expect(tracker.extractions.count == 1)
        // (Time passes on the Mac's clock too: the folder has been still.)
        mac.clock += Tracker.unarchiverFinishWait + 0.1
        _ = tracker.step(now: 1.0 + Tracker.unarchiverFinishWait + 0.1, processes: [macPacker([])])
        let extraction = try #require(tracker.ended.last)
        #expect(extraction.ending == .stopped)
    }

    /// The beginning is found in the work folder too, without a file
    /// caught being written: beside the archive, and in the folder named
    /// after it ("Extract to").
    @Test(arguments: [
        "/Users/me/Downloads/big.macpack",
        "/Users/me/Downloads/big/big.macpack",
    ])
    func theBeginningIsFoundInTheWorkFolder(root: String) throws {
        mac.setIndex([ArchiveEntry(path: "many", size: 0, isFolder: true)]
            + (0..<1_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 100) }, for: archive)
        var tracker = mac.tracker()
        #expect(tracker.step(now: 0, processes: [macPacker([reading(archive)])]).isEmpty)
        #expect(tracker.step(now: 0.1, processes: [macPacker([reading(archive)])]).isEmpty)
        for file in 0..<10 {
            mac.put(.file(size: 100), at: "\(root)/many/file \(file).bin")
        }
        _ = tracker.step(now: 0.2, processes: [macPacker([reading(archive)])])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.destination == root)
    }

    /// Seen on a real Mac, 23 Oct 2026: a compressed tar is extracted from
    /// the copy MacPacker unpacked it into, and the work folder is named
    /// after that copy (`many.tar`, the name kept inside the archive), not
    /// after the archive (`manyparts.tar.gz.001`). Of 20,000 small files
    /// none was caught being written, and the extraction was seen only once
    /// it was over. Its beginning is looked for under the copy's name too.
    @Test(arguments: [
        "/Users/me/Downloads/many.macpack",
        "/Users/me/Downloads/manyparts/many.macpack",
    ])
    func theBeginningIsFoundInAWorkFolderNamedAfterTheCopy(root: String) throws {
        let pieces = ["/Users/me/Downloads/manyparts.tar.gz.001", "/Users/me/Downloads/manyparts.tar.gz.002"]
        let copy = "/Users/me/Library/Containers/com.sarensx.MacPacker.lab/Data/Library/Caches/ta/8DF5B201/many.tar"
        let entries = [ArchiveEntry(path: "many", size: 0, isFolder: true)]
            + (0..<1_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 100) }
        mac.setIndexFailure(.tooLarge, for: pieces[0])
        var tracker = mac.tracker()
        for look in 0...21 {
            _ = tracker.step(now: Double(look) / 10, processes: [macPacker(
                pieces.map { reading($0, size: 125_829_120, at: 3_145_728) }
                    + [writing(copy, size: UInt64(look + 1) * 15_000_000)]
            )])
        }
        _ = tracker.step(now: 2.2, processes: [macPacker([])])
        mac.finishLaterIndex(entries, for: pieces[0])
        mac.clock += 60

        _ = tracker.step(now: 60, processes: [macPacker([reading(copy, size: 340_000_000, at: 600_000)])])
        #expect(tracker.extractions.isEmpty)
        for file in 0..<10 {
            mac.put(.file(size: 100), at: "\(root)/many/file \(file).bin")
        }
        _ = tracker.step(now: 60.1, processes: [macPacker([reading(copy, size: 340_000_000, at: 900_000)])])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.name == "manyparts.tar.gz.001")
        #expect(extraction.destination == root)
    }
}
