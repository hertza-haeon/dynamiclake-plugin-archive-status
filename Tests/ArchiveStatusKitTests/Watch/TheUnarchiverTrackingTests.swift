// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// What The Unarchiver (4.3.9) was seen to do on a real Mac on 12 Oct
/// 2026, replayed look by look: it has every archive it was given open
/// from the start and takes them one after the other; each is extracted
/// into a hidden folder where the result will go, `.TheUnarchiverTemp0`,
/// which is gone, and the result there under its name, in one instant;
/// and it holds the archive for seconds more.
struct TheUnarchiverTrackingTests {
    let mac = FakeMac()
    let archive = "/Users/me/Downloads/photos.zip"
    let temp = "/Users/me/Downloads/.TheUnarchiverTemp0"
    let entries = [
        ArchiveEntry(path: "photos", size: 0, isFolder: true),
        ArchiveEntry(path: "photos/a.jpg", size: 1_000),
        ArchiveEntry(path: "photos/b.jpg", size: 2_000),
        ArchiveEntry(path: "photos/c.jpg", size: 3_000),
    ]

    /// The result put in place under `name`, with these files in it, and
    /// the work folder gone.
    private func finish(as name: String, files: [(String, UInt64)], temp: String? = nil) {
        mac.put(.missing, at: temp ?? self.temp)
        mac.put(.folder(items: files.count), at: "/Users/me/Downloads/" + name)
        for (file, size) in files {
            mac.put(.file(size: size), at: "/Users/me/Downloads/\(name)/\(file)")
        }
    }

    /// Extracts the archive as far as its second file.
    private func begin(_ tracker: inout Tracker) -> [String] {
        mac.put(.folder(items: 1), at: temp)
        var lines = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        lines += tracker.step(now: 5, processes: [unarchiver([reading(archive), writing(temp + "/photos/a.jpg", size: 400)])])
        lines += tracker.step(now: 6, processes: [unarchiver([reading(archive), writing(temp + "/photos/b.jpg", size: 1_500)])])
        return lines
    }

    @Test func anArchiveItHasOpenWaitsThenBeginsWithItsFirstFile() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        // The Unarchiver reads the archive through before it writes anything.
        var lines = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        #expect(lines == ["photos.zip: The Unarchiver has it open, to extract it: 6.0 KB in 3 files (zip)"])
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.isWaiting)
        #expect(extraction.total == 6_000)
        #expect(extraction.written == 0)
        // However long it takes, waiting is no standstill.
        for second in 1...30 {
            lines = tracker.step(now: Double(second), processes: [unarchiver([reading(archive)])])
            #expect(lines.isEmpty)
        }
        #expect(tracker.extractions.first?.stalledSince == nil)

        mac.put(.folder(items: 1), at: temp)
        lines = tracker.step(now: 31, processes: [unarchiver([reading(archive), writing(temp + "/photos/a.jpg", size: 400)])])
        #expect(lines.first == "photos.zip: The Unarchiver is extracting it: 6.0 KB in 3 files (zip), into \(temp)")
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.isWaiting == false)
        #expect(extraction.id == 1, "the same extraction, begun")
        #expect(extraction.startedAt == 31)
        #expect(extraction.written == 400)
        #expect(extraction.tool == .theUnarchiver)
        // Where the result will be: the first of its names that is free.
        _ = tracker.step(now: 31.1, processes: [unarchiver([reading(archive), writing(temp + "/photos/a.jpg", size: 900)])])
        #expect(tracker.extractions.first?.result == "/Users/me/Downloads/photos")
    }

    @Test func theWorkFolderGoneAndTheResultInPlaceIsComplete() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        // The Unarchiver still holds the archive: that says nothing.
        var lines = tracker.step(now: 9, processes: [unarchiver([reading(archive)])])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 4.0 s; at /Users/me/Downloads/photos")
        #expect(tracker.extractions.isEmpty)
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .complete)
        #expect(ended.revealPaths == ["/Users/me/Downloads/photos"])
        // Held for seconds more: no second extraction comes of it.
        let reads = mac.indexReads.count
        for second in 10...16 {
            lines = tracker.step(now: Double(second), processes: [unarchiver([reading(archive)])])
            #expect(lines.isEmpty)
        }
        #expect(tracker.extractions.isEmpty)
        #expect(mac.indexReads.count == reads, "and the archive isn't read again")
        #expect(tracker.step(now: 17, processes: []).isEmpty)
        #expect(tracker.ended.count == 1)
    }

    /// Seen: `very many small files-1`, `one big file-1.bin`.
    @Test func aNameThatIsTakenGetsANumber() throws {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/photos", changedAt: mac.clock - 500)
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/photos/a.jpg", changedAt: mac.clock - 500)
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/photos/b.jpg", changedAt: mac.clock - 500)
        mac.put(.file(size: 3_000), at: "/Users/me/Downloads/photos/c.jpg", changedAt: mac.clock - 500)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        #expect(tracker.extractions.first?.result == "/Users/me/Downloads/photos-1")
        finish(as: "photos-1", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        let lines = tracker.step(now: 9, processes: [unarchiver([reading(archive)])])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 4.0 s; at /Users/me/Downloads/photos-1")
    }

    /// Seen with a damaged archive: The Unarchiver went through it to its
    /// end and put in place what it could read, 46 files of 150,000
    /// missing and one cut short.
    @Test func aResultInPlaceWithFilesMissingIsNotComplete() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        finish(as: "photos", files: [("a.jpg", 1_000), ("c.jpg", 2_999)])
        let lines = tracker.step(now: 9, processes: [unarchiver([reading(archive)])])
        #expect(lines.last == "photos.zip: not complete after 4.0 s: 2 of its 3 files are missing or cut short; at /Users/me/Downloads/photos")
        #expect(tracker.ended.last?.ending == .stopped)
        #expect(tracker.ended.last?.revealPaths == ["/Users/me/Downloads/photos"])
    }

    /// Nothing put in place: stopped. An earlier result of the same name
    /// isn't taken for this one's.
    @Test func theWorkFolderGoneAndNoResultIsStopped() throws {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/photos", changedAt: mac.clock - 500)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        mac.put(.missing, at: temp)
        let lines = tracker.step(now: 9, processes: [unarchiver([reading(archive)])])
        // (As a cancel went, 12 Oct: the work folder taken away,
        // nothing put in place, `Stopped` two seconds later.)
        #expect(lines.last == "photos.zip: stopped short at 41 % (2.5 KB of 6.0 KB) after 4.0 s")
        #expect(tracker.ended.last?.ending == .stopped)
        #expect(tracker.ended.last?.result == nil, "the name it would have had is no place")
        #expect(tracker.ended.last?.revealPaths.isEmpty == true)
    }

    @Test func theProgramGoneWithItsWorkFolderLeftBehindIsStopped() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        let lines = tracker.step(now: 9, processes: [])
        #expect(lines.last?.hasPrefix("photos.zip: stopped short at ") == true)
    }

    /// Several items at the top: a folder named after the archive.
    @Test func severalItemsGoIntoAFolderNamedAfterTheArchive() throws {
        mac.setIndex([ArchiveEntry(path: "first.txt", size: 10), ArchiveEntry(path: "second.txt", size: 20)], for: archive)
        mac.put(.folder(items: 1), at: temp)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive), writing(temp + "/photos/first.txt", size: 4)])])
        #expect(tracker.extractions.first?.destination == temp + "/photos")
        finish(as: "photos", files: [("first.txt", 10), ("second.txt", 20)])
        let lines = tracker.step(now: 1, processes: [unarchiver([reading(archive)])])
        #expect(lines.last == "photos.zip: complete: 30 bytes in 1.0 s; at /Users/me/Downloads/photos")
    }

    /// One file: the file itself, its number before its extension.
    @Test(arguments: [("movie.mkv", false), ("movie-1.mkv", true)])
    func oneFileIsPutThereUnderItsOwnName(name: String, taken: Bool) throws {
        mac.setIndex([ArchiveEntry(path: "movie.mkv", size: 5_000)], for: archive)
        if taken {
            mac.put(.file(size: 5_000), at: "/Users/me/Downloads/movie.mkv", changedAt: mac.clock - 500)
        }
        mac.put(.folder(items: 1), at: temp)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive), writing(temp + "/movie.mkv", size: 100)])])
        mac.put(.missing, at: temp)
        mac.put(.file(size: 5_000), at: "/Users/me/Downloads/" + name)
        let lines = tracker.step(now: 2, processes: [unarchiver([reading(archive)])])
        #expect(lines.last == "photos.zip: complete: 5.0 KB in 2.0 s; at /Users/me/Downloads/\(name)")
    }

    /// A compressed tar is extracted one folder deeper in the work folder
    /// (`.TheUnarchiverTemp0/tarball/…`), and its one item put in place.
    @Test func aCompressedTarIsFollowedAFolderDeeper() throws {
        let tarball = "/Users/me/Downloads/tarball.tar.gz"
        mac.setIndex(entries, format: .compressedTar, for: tarball)
        mac.put(.folder(items: 1), at: temp)
        var tracker = mac.tracker()
        let lines = tracker.step(now: 0, processes: [unarchiver([reading(tarball), writing(temp + "/tarball/photos/a.jpg", size: 100)])])
        #expect(lines.contains("tarball.tar.gz: The Unarchiver is extracting it: 6.0 KB in 3 files (compressed tar), into \(temp)/tarball"))
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        #expect(tracker.step(now: 3, processes: [unarchiver([reading(tarball)])]).last
            == "tarball.tar.gz: complete: 6.0 KB in 3.0 s; at /Users/me/Downloads/photos")
    }

    // MARK: Its own settings, other than as it comes (seen on a real Mac, 12 Oct 2026)

    /// "Create a new folder for the extracted files: Always": the archive's
    /// one item is put in a folder named after the archive. (Before this
    /// was known, such an extraction read `stopped`: nothing was where the
    /// item alone would have been.)
    @Test(arguments: [
        // The folder's name isn't the item's.
        ("/Users/me/Downloads/trip.zip", "trip"),
        // …or it is: `photos.zip` holds `photos`, and ends up as `photos/photos`.
        ("/Users/me/Downloads/photos.zip", "photos"),
    ])
    func setAlwaysToMakeAFolderTheOneItemIsInsideIt(archive: String, folder: String) throws {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 1), at: temp)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive), writing("\(temp)/\(folder)/photos/a.jpg", size: 400)])])
        #expect(tracker.extractions.first?.destination == "\(temp)/\(folder)")
        mac.put(.missing, at: temp)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/\(folder)")
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/\(folder)/photos")
        for (file, size) in [("a.jpg", UInt64(1_000)), ("b.jpg", 2_000), ("c.jpg", 3_000)] {
            mac.put(.file(size: size), at: "/Users/me/Downloads/\(folder)/photos/\(file)")
        }
        let lines = tracker.step(now: 2, processes: [unarchiver([reading(archive)])])
        #expect(lines.last == "\(ArchiveName.fileName(of: archive)): complete: 6.0 KB in 2.0 s; at /Users/me/Downloads/\(folder)")
        #expect(tracker.ended.last?.ending == .complete)
    }

    /// The same with one file, and with a file of it missing.
    @Test func setAlwaysToMakeAFolderItsFilesAreLookedForInsideIt() throws {
        mac.setIndex([ArchiveEntry(path: "movie.mkv", size: 5_000)], for: archive)
        mac.put(.folder(items: 1), at: temp)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive), writing(temp + "/photos/movie.mkv", size: 100)])])
        mac.put(.missing, at: temp)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/photos")
        mac.put(.file(size: 4_999), at: "/Users/me/Downloads/photos/movie.mkv")
        let lines = tracker.step(now: 2, processes: [unarchiver([reading(archive)])])
        #expect(lines.last == "photos.zip: not complete after 2.0 s: 1 of its 1 files is missing or cut short; at /Users/me/Downloads/photos")
    }

    /// "…Never": no hidden folder at all. It writes where the files are to
    /// stay, as MacPacker does, and is judged the same way when it lets go
    /// of the archive. (Before: `whether it got to its end can't be told`,
    /// in the first second.)
    @Test func setNeverToMakeAFolderItWritesAtTheFinalPlace() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        var lines = tracker.step(now: 1, processes: [unarchiver([reading(archive), writing("/Users/me/Downloads/photos/a.jpg", size: 400)])])
        #expect(lines.first == "photos.zip: The Unarchiver is extracting it: 6.0 KB in 3 files (zip), into /Users/me/Downloads")
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.result == "/Users/me/Downloads/photos")
        #expect(extraction.revealPaths == ["/Users/me/Downloads/photos"])
        // Between two files, with nothing open for writing: still under way.
        lines = tracker.step(now: 2, processes: [unarchiver([reading(archive)])])
        #expect(tracker.extractions.count == 1)
        lines = tracker.step(now: 3, processes: [unarchiver([reading(archive), writing("/Users/me/Downloads/photos/c.jpg", size: 2_500)])])
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 5_500)
        // It lets go: every file is there, whole.
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/photos/a.jpg")
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/photos/b.jpg")
        mac.put(.file(size: 3_000), at: "/Users/me/Downloads/photos/c.jpg")
        lines = tracker.step(now: 4, processes: [unarchiver([])])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 3.0 s; at /Users/me/Downloads/photos")
    }

    @Test func setNeverToMakeAFolderAStopLeavesTheLastFileShort() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive), writing("/Users/me/Downloads/photos/a.jpg", size: 400)])])
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/photos/a.jpg")
        mac.put(.file(size: 900), at: "/Users/me/Downloads/photos/b.jpg")
        let lines = tracker.step(now: 4, processes: [unarchiver([])])
        #expect(lines.last?.hasPrefix("photos.zip: stopped short at ") == true)
        #expect(tracker.ended.last?.ending == .stopped)
    }

    /// "Move the archive to the trash": it is moved while The Unarchiver
    /// still has it open. That is the same archive, done with, not another
    /// one that waits. (Before: a second `has it open, to extract it`.)
    @Test func anArchiveMovedToTheTrashWhileHeldIsNoSecondArchive() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        let reads = mac.indexReads.count
        var lines = tracker.step(now: 9, processes: [unarchiver([reading("/Users/me/.Trash/photos.zip")])])
        #expect(lines == ["photos.zip: complete: 6.0 KB in 4.0 s; at /Users/me/Downloads/photos"])
        for second in 10...15 {
            lines = tracker.step(now: Double(second), processes: [unarchiver([reading("/Users/me/.Trash/photos.zip")])])
            #expect(lines.isEmpty)
        }
        #expect(tracker.extractions.isEmpty)
        #expect(mac.indexReads.count == reads, "it isn't read there")
        #expect(tracker.attention == .none)
    }

    @Test(arguments: [
        ("/Users/me/.Trash/photos.zip", true),
        ("/Volumes/Disk/.Trashes/501/photos.zip", true),
        ("/Users/me/Downloads/photos.zip", false),
        ("/Users/me/Trash/photos.zip", false),
    ])
    func anArchiveInATrashFolderIsTold(path: String, isInTrash: Bool) {
        #expect(ArchiveName.isInTrash(path) == isInTrash)
    }

    /// Given two archives, it has both open from the start and takes them
    /// in turn, each in a work folder of its own.
    @Test func twoArchivesAreTakenOneAfterTheOther() throws {
        let second = "/Users/me/Downloads/music.zip"
        let secondTemp = "/Users/me/Downloads/.TheUnarchiverTemp1"
        mac.setIndex(entries, for: archive)
        mac.setIndex([ArchiveEntry(path: "album.flac", size: 9_000)], for: second)
        mac.put(.folder(items: 1), at: temp)
        var tracker = mac.tracker()
        var lines = tracker.step(now: 0, processes: [unarchiver([reading(archive), reading(second), writing(temp + "/photos/a.jpg", size: 400)])])
        #expect(lines.contains("music.zip: The Unarchiver has it open, to extract it: 9.0 KB in 1 file (zip)"))
        let waiting = try #require(tracker.extractions.first { $0.name == "music.zip" })
        #expect(waiting.isWaiting)
        #expect(tracker.extractions.first { $0.name == "photos.zip" }?.isWaiting == false)

        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        lines = tracker.step(now: 4, processes: [unarchiver([reading(archive), reading(second)])])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 4.0 s; at /Users/me/Downloads/photos")
        #expect(tracker.extractions.map(\.name) == ["music.zip"])
        #expect(tracker.extractions.first?.isWaiting == true)

        mac.put(.folder(items: 1), at: secondTemp)
        lines = tracker.step(now: 4.5, processes: [unarchiver([reading(archive), reading(second), writing(secondTemp + "/album.flac", size: 3_000)])])
        #expect(lines.first == "music.zip: The Unarchiver is extracting it: 9.0 KB in 1 file (zip), into \(secondTemp)")
        #expect(tracker.extractions.first?.id == waiting.id, "the one that waited, begun")
        #expect(tracker.extractions.first?.isWaiting == false)
        mac.put(.missing, at: secondTemp)
        mac.put(.file(size: 9_000), at: "/Users/me/Downloads/album.flac")
        lines = tracker.step(now: 8, processes: [unarchiver([reading(archive), reading(second)])])
        #expect(lines.last == "music.zip: complete: 9.0 KB in 3.5 s; at /Users/me/Downloads/album.flac")
        #expect(tracker.ended.map(\.ending) == [.complete, .complete])
        #expect(tracker.step(now: 14, processes: []).isEmpty)
    }

    @Test func oneThatWaitedAndIsLetGoOfWasNeverExtracted() {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        let lines = tracker.step(now: 3, processes: [unarchiver([])])
        #expect(lines == ["photos.zip: let go of without being extracted"])
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.ended.isEmpty)
    }

    /// What The Unarchiver writes for itself is no part of an extraction.
    @Test func itsOwnFilesDoNotCount() {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([
            reading(archive),
            writing("/private/var/folders/2f/x/C/com.macpaw.site.theunarchiver/com.apple.metal/16777235_530/functions.data", size: 81_920),
        ])])
        #expect(tracker.extractions.first?.isWaiting == true)
    }

    @Test(arguments: [
        ([ArchiveEntry(path: "photos", size: 0, isFolder: true), ArchiveEntry(path: "photos/a.jpg", size: 1)], "photos", "photos-1", "photos-2"),
        ([ArchiveEntry(path: "movie.mkv", size: 1)], "movie.mkv", "movie-1.mkv", "movie-2.mkv"),
        ([ArchiveEntry(path: "a.txt", size: 1), ArchiveEntry(path: "b.txt", size: 1)], "trip", "trip-1", "trip-2"),
        ([ArchiveEntry(path: "README", size: 1)], "README", "README-1", "README-2"),
    ])
    func theNamesItsResultMayHave(entries: [ArchiveEntry], first: String, second: String, third: String) {
        let names = Tracker.namesBeside(of: .theUnarchiver, archivePath: "/x/trip.tar.gz",
                                        index: ArchiveIndex(format: .zip, entries: entries, parts: []), in: "/x").names
        #expect(Array(names.prefix(3)) == ["/x/" + first, "/x/" + second, "/x/" + third])
    }
}
