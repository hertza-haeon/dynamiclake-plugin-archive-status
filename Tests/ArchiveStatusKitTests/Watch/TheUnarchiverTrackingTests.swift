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
        #expect(tracker.ended.last?.ending == .incomplete)
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

    /// (It is given a moment first: see
    /// `doneBetweenTwoLooksItIsToldByWhatItLeft`.)
    @Test func oneThatWaitedAndIsLetGoOfWasNeverExtracted() {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        #expect(tracker.step(now: 3, processes: [unarchiver([])]).isEmpty)
        #expect(tracker.extractions.first?.isWaiting == true)
        let lines = tracker.step(now: 5, processes: [unarchiver([])])
        #expect(lines == ["photos.zip: let go of without being extracted"])
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.ended.isEmpty)
    }

    /// Seen on a real Mac, 13 Oct 2026: a `tar.gz` of 510 MB extracted
    /// whole in two seconds, while the lists of other archives were being
    /// read. The Unarchiver had it, then didn't, and not one file was seen
    /// being written.
    @Test func doneBetweenTwoLooksItIsToldByWhatItLeft() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        var lines = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        #expect(lines == ["photos.zip: The Unarchiver has it open, to extract it: 6.0 KB in 3 files (zip)"])
        // All of it is there, and its work folder is gone already.
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        lines = tracker.step(now: 2, processes: [unarchiver([])])
        #expect(lines == ["photos.zip: complete: 6.0 KB in 2.0 s; at /Users/me/Downloads/photos"])
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .complete)
        #expect(ended.id == 1, "the one that waited")
        #expect(ended.isWaiting == false)
        #expect(ended.written == 6_000)
        #expect(ended.result == "/Users/me/Downloads/photos")
        #expect(tracker.extractions.isEmpty)
    }

    /// The result may come a moment after the archive is let go of.
    @Test func doneBetweenTwoLooksItsResultMayComeAMomentLater() {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        #expect(tracker.step(now: 2, processes: [unarchiver([])]).isEmpty)
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        let lines = tracker.step(now: 2.5, processes: [unarchiver([])])
        // (It took as long as The Unarchiver had the archive.)
        #expect(lines == ["photos.zip: complete: 6.0 KB in 2.0 s; at /Users/me/Downloads/photos"])
    }

    /// What it left with files missing is no `Complete`: incomplete.
    @Test func doneBetweenTwoLooksWithFilesMissingItIsIncomplete() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000)])
        let lines = tracker.step(now: 2, processes: [unarchiver([])])
        #expect(lines.first?.hasPrefix("photos.zip: not complete after 2.0 s: 1 of its 3 files") == true)
        #expect(tracker.ended.last?.ending == .incomplete)
    }

    /// Something of that name that was there before is no result of this.
    @Test func whatWasThereBeforeIsNoResultOfOneThatOnlyWaited() {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/photos", changedAt: mac.clock - 600)
        for (file, size) in [("a.jpg", UInt64(1_000)), ("b.jpg", 2_000), ("c.jpg", 3_000)] {
            mac.put(.file(size: size), at: "/Users/me/Downloads/photos/\(file)", changedAt: mac.clock - 600)
        }
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        _ = tracker.step(now: 2, processes: [unarchiver([])])
        let lines = tracker.step(now: 4, processes: [unarchiver([])])
        #expect(lines == ["photos.zip: let go of without being extracted"])
        #expect(tracker.ended.isEmpty)
    }

    // MARK: Archives under other names, and in the folders macOS keeps in the Library

    /// Seen on a real Mac, 13 Oct 2026: a zip named `comic.cbz`
    /// extracted with The Unarchiver showed nothing: its name wasn't an
    /// archive's. What it is is read from the file itself.
    @Test func aZipUnderAnotherNameIsFollowedLikeAnyZip() throws {
        let comic = "/Users/me/Downloads/comic.cbz"
        mac.setIndex(entries, for: comic)
        var tracker = mac.tracker()
        var lines = tracker.step(now: 0, processes: [unarchiver([reading(comic)])])
        #expect(lines == ["comic.cbz: The Unarchiver has it open, to extract it: 6.0 KB in 3 files (zip)"])
        mac.put(.folder(items: 1), at: temp)
        lines = tracker.step(now: 1, processes: [unarchiver([reading(comic), writing(temp + "/photos/a.jpg", size: 400)])])
        #expect(lines.first == "comic.cbz: The Unarchiver is extracting it: 6.0 KB in 3 files (zip), into \(temp)")
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        lines = tracker.step(now: 2, processes: [unarchiver([reading(comic)])])
        #expect(lines.last == "comic.cbz: complete: 6.0 KB in 1.0 s; at /Users/me/Downloads/photos")
    }

    /// An archive of a kind the plugin can't read (`disc.iso`, `old.lzh`):
    /// The Unarchiver reads nothing of the user's but archives, so it is
    /// one; followed by how far it is read, and done when its result is in
    /// place.
    @Test(arguments: ["/Users/me/Downloads/disc.iso", "/Users/me/Downloads/old.lzh", "/Volumes/USB/set.cab"])
    func anArchiveOfAKindWithoutANameIsFollowedToDone(disc: String) throws {
        mac.setIndexFailure(.notAnArchive, for: disc)
        let folder = ArchiveName.folder(of: disc)
        let temp = folder + "/.TheUnarchiverTemp0"
        var tracker = mac.tracker()
        var lines = tracker.step(now: 0, processes: [unarchiver([reading(disc, size: 9_000, at: 100)])])
        #expect(lines.first?.hasSuffix("The Unarchiver has it open, to extract it: its size can't be read") == true)
        mac.put(.folder(items: 1), at: temp)
        lines = tracker.step(now: 1, processes: [unarchiver([reading(disc, size: 9_000, at: 4_000), writing(temp + "/setup/a.bin", size: 400)])])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.measuresArchive)
        #expect(extraction.written == 4_000)
        mac.put(.missing, at: temp)
        mac.put(.folder(items: 1), at: folder + "/setup")
        lines = tracker.step(now: 2, processes: [unarchiver([reading(disc, size: 9_000, at: 9_000)])])
        #expect(lines.last?.contains("done after 1.0 s") == true)
        #expect(tracker.ended.last?.ending == .unchecked)
        #expect(tracker.ended.last?.result == folder + "/setup")
    }

    /// What The Unarchiver reads of its own, of macOS's or of an app's is
    /// no archive, whatever it is.
    @Test(arguments: [
        "/Users/me/Library/Caches/com.macpaw.site.theunarchiver/Cache.db",
        "/System/Library/Fonts/SFNS.ttf",
        "/Applications/The Unarchiver.app/Contents/Resources/Assets.car",
        "/private/var/folders/2f/x/C/com.macpaw.site.theunarchiver/thing",
        "/Users/me/Downloads/.TheUnarchiverTemp0/photos/a.jpg",
        "/Users/me/.Trash/disc.iso",
    ])
    func whatItReadsOfItsOwnIsNoArchive(path: String) {
        var tracker = mac.tracker()
        for look in 0..<3 {
            #expect(tracker.step(now: Double(look), processes: [unarchiver([reading(path)])]).isEmpty)
        }
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.attention == .none)
        #expect(mac.indexReads.isEmpty)
    }

    /// From the code, 13 Oct 2026: everything written under the user's
    /// Library was left out, and macOS keeps iCloud Drive and the disks of
    /// Dropbox, OneDrive and Google Drive there. An extraction in one of
    /// them is followed like any other.
    @Test(arguments: [
        "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Archives",
        "/Users/me/Library/CloudStorage/Dropbox/Archives",
        "/Users/me/Library/CloudStorage/OneDrive-Personal",
    ])
    func anExtractionInACloudFolderIsFollowed(folder: String) throws {
        let archive = folder + "/photos.zip"
        let temp = folder + "/.TheUnarchiverTemp0"
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        mac.put(.folder(items: 1), at: temp)
        var lines = tracker.step(now: 1, processes: [unarchiver([reading(archive), writing(temp + "/photos/b.jpg", size: 1_500)])])
        #expect(lines.first == "photos.zip: The Unarchiver is extracting it: 6.0 KB in 3 files (zip), into \(temp)")
        #expect(tracker.extractions.first?.written == 2_500)
        mac.put(.missing, at: temp)
        mac.put(.folder(items: 3), at: folder + "/photos")
        for (file, size) in [("a.jpg", UInt64(1_000)), ("b.jpg", 2_000), ("c.jpg", 3_000)] {
            mac.put(.file(size: size), at: folder + "/photos/" + file)
        }
        lines = tracker.step(now: 2, processes: [unarchiver([reading(archive)])])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 1.0 s; at \(folder)/photos")
    }

    // MARK: Set never to make a folder, the names taken

    /// Seen on a real Mac, 13 Oct 2026: The Unarchiver set never to make
    /// a folder writes each item at its final place, and under a numbered
    /// name where its own is taken (`album-1/disc 05/track 05575.bin`).
    /// Such an extraction wasn't followed: its files matched nothing.
    @Test func writtenInPlaceUnderANumberedNameItIsFollowed() throws {
        mac.setIndex(entries, for: archive)
        // An earlier copy has the name.
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/photos", changedAt: mac.clock - 900)
        for (file, size) in [("a.jpg", UInt64(1_000)), ("b.jpg", 2_000), ("c.jpg", 3_000)] {
            mac.put(.file(size: size), at: "/Users/me/Downloads/photos/\(file)", changedAt: mac.clock - 900)
        }
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/photos-1")
        mac.put(.file(size: 400), at: "/Users/me/Downloads/photos-1/a.jpg")
        var lines = tracker.step(now: 1, processes: [unarchiver([reading(archive), writing("/Users/me/Downloads/photos-1/a.jpg", size: 400)])])
        #expect(lines.first == "photos.zip: The Unarchiver is extracting it: 6.0 KB in 3 files (zip), into /Users/me/Downloads")
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.isWaiting == false)
        #expect(extraction.written == 400)
        #expect(extraction.result == "/Users/me/Downloads/photos-1")
        #expect(extraction.revealPaths == ["/Users/me/Downloads/photos-1"])
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/photos-1/a.jpg")
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/photos-1/b.jpg")
        _ = tracker.step(now: 2, processes: [unarchiver([reading(archive), writing("/Users/me/Downloads/photos-1/c.jpg", size: 1_500)])])
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 4_500)
        mac.put(.file(size: 3_000), at: "/Users/me/Downloads/photos-1/c.jpg")
        lines = tracker.step(now: 3, processes: [unarchiver([])])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 2.0 s; at /Users/me/Downloads/photos-1")
        #expect(tracker.ended.last?.ending == .complete)
    }

    /// Several items at the top: each gets the first numbered name that is
    /// free (seen: `first-1`, `movie-2.bin`, `notes-1.txt`), and one no
    /// file of which was caught being written is found all the same.
    @Test func severalItemsWrittenInPlaceEachUnderItsOwnNumber() throws {
        let several = [
            ArchiveEntry(path: "first/a.bin", size: 1_000),
            ArchiveEntry(path: "movie.bin", size: 5_000),
            ArchiveEntry(path: "notes.txt", size: 13),
        ]
        mac.setIndex(several, for: archive)
        for old in ["first", "movie.bin", "movie-1.bin", "notes.txt"] {
            mac.put(old == "first" ? .folder(items: 1) : .file(size: 5), at: "/Users/me/Downloads/" + old, changedAt: mac.clock - 900)
        }
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/first/a.bin", changedAt: mac.clock - 900)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/first-1")
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/first-1/a.bin")
        _ = tracker.step(now: 1, processes: [unarchiver([reading(archive), writing("/Users/me/Downloads/first-1/a.bin", size: 600)])])
        _ = tracker.step(now: 2, processes: [unarchiver([reading(archive), writing("/Users/me/Downloads/movie-2.bin", size: 2_500)])])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 3_500)
        #expect(extraction.revealPaths == ["/Users/me/Downloads/first-1", "/Users/me/Downloads/movie-2.bin", "/Users/me/Downloads/notes.txt"])
        mac.put(.file(size: 5_000), at: "/Users/me/Downloads/movie-2.bin")
        mac.put(.file(size: 13), at: "/Users/me/Downloads/notes-1.txt")
        let lines = tracker.step(now: 3, processes: [unarchiver([])])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 2.0 s; at /Users/me/Downloads")
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .complete)
        #expect(ended.revealPaths == ["/Users/me/Downloads/first-1", "/Users/me/Downloads/movie-2.bin", "/Users/me/Downloads/notes-1.txt"])
    }

    /// …and when not one file of them was caught being written.
    @Test func severalItemsWrittenInPlaceAreFoundWithoutAFileCaught() throws {
        let several = [ArchiveEntry(path: "first/a.bin", size: 1_000), ArchiveEntry(path: "movie.bin", size: 5_000)]
        mac.setIndex(several, for: archive)
        mac.put(.file(size: 5), at: "/Users/me/Downloads/movie.bin", changedAt: mac.clock - 900)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/first")
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/first/a.bin")
        mac.put(.file(size: 5_000), at: "/Users/me/Downloads/movie-1.bin")
        let lines = tracker.step(now: 2, processes: [unarchiver([])])
        #expect(lines == ["photos.zip: complete: 6.0 KB in 2.0 s; at /Users/me/Downloads"])
        let ended = try #require(tracker.ended.last)
        #expect(ended.revealPaths == ["/Users/me/Downloads/first", "/Users/me/Downloads/movie-1.bin"])
    }

    /// Items of those names that were there before are no extraction.
    @Test func severalItemsThereFromBeforeAreNoExtractionOfOneThatOnlyWaited() {
        let several = [ArchiveEntry(path: "first/a.bin", size: 1_000), ArchiveEntry(path: "movie.bin", size: 5_000)]
        mac.setIndex(several, for: archive)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/first", changedAt: mac.clock - 900)
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/first/a.bin", changedAt: mac.clock - 900)
        mac.put(.file(size: 5_000), at: "/Users/me/Downloads/movie.bin", changedAt: mac.clock - 900)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive)])])
        _ = tracker.step(now: 2, processes: [unarchiver([])])
        let lines = tracker.step(now: 4.5, processes: [])
        #expect(lines == ["photos.zip: let go of without being extracted"])
        #expect(tracker.ended.isEmpty)
    }

    /// Seen on a real Mac, 13 Oct 2026: an archive in a folder
    /// DynamicLake wasn't let into can't be read, and a `tar.bz2` of
    /// 492 MB takes too long to: the card went without a word at the end.
    /// With its result in place the extraction is done, which is not said
    /// complete: its files can't be looked at.
    @Test(arguments: [IndexError.unreadable, .tooLarge])
    func withoutAnIndexItsResultInPlaceIsDone(error: IndexError) throws {
        mac.setIndexFailure(error, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive, size: 9_000, at: 100)])])
        mac.put(.folder(items: 1), at: temp)
        _ = tracker.step(now: 1, processes: [unarchiver([reading(archive, size: 9_000, at: 3_000), writing(temp + "/photos/a.jpg", size: 400)])])
        _ = tracker.step(now: 2, processes: [unarchiver([reading(archive, size: 9_000, at: 9_000), writing(temp + "/photos/c.jpg", size: 3_000)])])
        #expect(tracker.extractions.first?.ending == nil)
        mac.put(.missing, at: temp)
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/photos")
        let lines = tracker.step(now: 3, processes: [unarchiver([reading(archive, size: 9_000, at: 9_000)])])
        #expect(lines.last == "photos.zip: done after 2.0 s: its result is in place, and its files couldn't be looked at "
            + "(no list of the archive's contents); at /Users/me/Downloads/photos")
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .unchecked)
        #expect(ended.result == "/Users/me/Downloads/photos")
        #expect(ended.revealPaths == ["/Users/me/Downloads/photos"])
    }

    /// Seen on a real Mac, 13 Oct 2026: The Unarchiver unpacked
    /// `big compressed.tar.bz2` into `.TheUnarchiverTemp0/big compressed/`,
    /// a folder it names after the archive, and put the one item in it,
    /// `mixed`, in place. Looked for under the folder's name only, the
    /// result wasn't found, and a finished extraction read `Stopped`.
    @Test func withoutAnIndexTheOneItemInTheFolderNamedAfterTheArchiveIsTheResult() throws {
        let tarball = "/Users/me/Downloads/big compressed.tar.bz2"
        // (Its list can't be had at all here: not even beside the loop.)
        mac.setIndexFailure(.unreadable, for: tarball)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(tarball, size: 9_000, at: 100)])])
        mac.put(.folder(items: 1), at: temp)
        _ = tracker.step(now: 1, processes: [unarchiver([reading(tarball, size: 9_000, at: 3_000),
                                                       writing(temp + "/big compressed/mixed/plain/a.bin", size: 400)])])
        _ = tracker.step(now: 2, processes: [unarchiver([reading(tarball, size: 9_000, at: 8_990),
                                                       writing(temp + "/big compressed/mixed/plain/b.bin", size: 400)])])
        mac.put(.missing, at: temp)
        mac.put(.folder(items: 6), at: "/Users/me/Downloads/mixed")
        let lines = tracker.step(now: 3, processes: [unarchiver([reading(tarball, size: 9_000, at: 8_990)])])
        #expect(lines.last?.hasPrefix("big compressed.tar.bz2: done after 2.0 s") == true)
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .unchecked)
        #expect(ended.result == "/Users/me/Downloads/mixed")
    }

    /// A list read beside the loop: The Unarchiver puts its result in place
    /// and holds the archive a while; the files are looked at by the list
    /// as soon as it is there.
    @Test func aListReadBesideTheLoopServesTheEnd() {
        let tarball = "/Users/me/Downloads/big compressed.tar.bz2"
        mac.setIndexFailure(.tooLarge, for: tarball)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(tarball, size: 9_000, at: 100)])])
        #expect(mac.laterBegun == [tarball])
        mac.put(.folder(items: 1), at: temp)
        _ = tracker.step(now: 1, processes: [unarchiver([reading(tarball, size: 9_000, at: 3_000),
                                                       writing(temp + "/big compressed/mixed/a.bin", size: 400)])])
        // It is done; its list comes a moment later.
        mac.put(.missing, at: temp)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/mixed")
        mac.put(.file(size: 400), at: "/Users/me/Downloads/mixed/a.bin")
        var lines = tracker.step(now: 3, processes: [unarchiver([reading(tarball, size: 9_000, at: 8_990)])])
        #expect(lines.contains { $0.contains("done after") } == false, "the list may yet come")
        mac.finishLaterIndex([ArchiveEntry(path: "mixed/a.bin", size: 400)], for: tarball)
        lines = tracker.step(now: 4, processes: [unarchiver([reading(tarball, size: 9_000, at: 8_990)])])
        #expect(lines.last == "big compressed.tar.bz2: complete in 3.0 s (an archive of 9.0 KB); at /Users/me/Downloads/mixed")
    }

    /// An archive that waits (for a password, for its turn) gets its
    /// amounts from the list as soon as that is read, and begins with it.
    @Test func aListReadBesideTheLoopGivesTheOneThatWaitsItsAmounts() throws {
        let tarball = "/Users/me/Downloads/next.tar.xz"
        mac.setIndexFailure(.tooLarge, for: tarball)
        var tracker = mac.tracker()
        var lines = tracker.step(now: 0, processes: [unarchiver([reading(tarball, size: 5_000)])])
        #expect(lines == ["next.tar.xz: The Unarchiver has it open, to extract it: its size can't be read"])
        mac.finishLaterIndex([ArchiveEntry(path: "notes/n.txt", size: 700)], for: tarball)
        lines = tracker.step(now: 2, processes: [unarchiver([reading(tarball, size: 5_000)])])
        #expect(lines == ["next.tar.xz: its list of contents is read: 700 bytes in 1 file (compressed tar)"])
        let waiting = try #require(tracker.extractions.first)
        #expect(waiting.isWaiting)
        #expect(waiting.total == 700)
        mac.put(.folder(items: 1), at: temp)
        lines = tracker.step(now: 3, processes: [unarchiver([reading(tarball, size: 5_000), writing(temp + "/notes/n.txt", size: 300)])])
        #expect(lines.first == "next.tar.xz: The Unarchiver is extracting it: 700 bytes in 1 file (compressed tar), into \(temp)")
        #expect(tracker.extractions.first?.measuresArchive == false)
        #expect(tracker.extractions.first?.written == 300)
    }

    /// The Unarchiver lets go of the archive while the end still waits for
    /// the list: that is no stop.
    @Test func lettingGoWhileTheEndWaitsForTheListIsNoStop() {
        let tarball = "/Users/me/Downloads/big compressed.tar.bz2"
        mac.setIndexFailure(.tooLarge, for: tarball)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(tarball, size: 9_000, at: 100)])])
        mac.put(.folder(items: 1), at: temp)
        _ = tracker.step(now: 1, processes: [unarchiver([reading(tarball, size: 9_000, at: 8_990),
                                                       writing(temp + "/big compressed/mixed/a.bin", size: 400)])])
        mac.put(.missing, at: temp)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/mixed")
        mac.put(.file(size: 400), at: "/Users/me/Downloads/mixed/a.bin")
        #expect(tracker.step(now: 2, processes: [unarchiver([])]).isEmpty)
        #expect(tracker.step(now: 3, processes: []).isEmpty)
        mac.finishLaterIndex([ArchiveEntry(path: "mixed/a.bin", size: 400)], for: tarball)
        let lines = tracker.step(now: 4, processes: [])
        #expect(lines.last?.hasPrefix("big compressed.tar.bz2: complete in") == true)
    }

    /// Without an index, a result that isn't found is no proof of a stop:
    /// read to its end, the archive may have been extracted under a name
    /// that can't be guessed. Nothing is said then.
    @Test func withoutAnIndexReadToItsEndAndNothingFoundCannotBeTold() {
        mac.setIndexFailure(.tooLarge, for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive, size: 9_000, at: 100)])])
        mac.put(.folder(items: 1), at: temp)
        _ = tracker.step(now: 1, processes: [unarchiver([reading(archive, size: 9_000, at: 8_900), writing(temp + "/photos/a.jpg", size: 400)])])
        mac.put(.missing, at: temp)
        let lines = tracker.step(now: 3, processes: [unarchiver([reading(archive, size: 9_000, at: 8_900)])])
        #expect(lines.last?.contains("whether it got to its end can't be told") == true)
        #expect(tracker.ended.last?.ending == .unknown)
    }

    /// The one item at the top is a file, and its name was taken: the
    /// number goes before its extension.
    @Test func withoutAnIndexAFileThatGotANumberIsFound() throws {
        mac.setIndexFailure(.unreadable, for: archive)
        mac.put(.file(size: 5), at: "/Users/me/Downloads/movie.mkv", changedAt: mac.clock - 900)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive, size: 9_000, at: 100)])])
        mac.put(.folder(items: 1), at: temp)
        _ = tracker.step(now: 1, processes: [unarchiver([reading(archive, size: 9_000, at: 3_000), writing(temp + "/movie.mkv", size: 400)])])
        mac.put(.missing, at: temp)
        mac.put(.file(size: 8_000), at: "/Users/me/Downloads/movie-1.mkv")
        _ = tracker.step(now: 3, processes: [unarchiver([reading(archive, size: 9_000, at: 9_000)])])
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .unchecked)
        #expect(ended.result == "/Users/me/Downloads/movie-1.mkv")
    }

    /// A cancel: The Unarchiver takes its work folder away and leaves
    /// nothing, with or without an index.
    @Test func withoutAnIndexNothingPutInPlaceIsStopped() {
        mac.setIndexFailure(.unreadable, for: archive)
        // (An earlier copy is there, and is not this extraction's.)
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/photos", changedAt: mac.clock - 900)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [unarchiver([reading(archive, size: 9_000, at: 100)])])
        mac.put(.folder(items: 1), at: temp)
        _ = tracker.step(now: 1, processes: [unarchiver([reading(archive, size: 9_000, at: 3_000), writing(temp + "/photos/a.jpg", size: 400)])])
        mac.put(.missing, at: temp)
        let lines = tracker.step(now: 3, processes: [unarchiver([reading(archive, size: 9_000, at: 3_000)])])
        #expect(lines.last?.hasPrefix("photos.zip: stopped short at 33 % (3.0 KB of 9.0 KB of the archive read)") == true)
        #expect(tracker.ended.last?.ending == .stopped)
        #expect(tracker.ended.last?.result == nil)
    }

    @Test(arguments: [
        ("/Users/me/Downloads/.TheUnarchiverTemp0/photos/a.jpg", Tool.theUnarchiver, "photos"),
        ("/Users/me/Downloads/.TheUnarchiverTemp0/movie.mkv", .theUnarchiver, "movie.mkv"),
        ("/Users/me/Downloads/photos.kextraction/Operation/photos/deep/a.jpg", .keka, "photos"),
        ("/Users/me/Downloads/photos.kextraction/Operation/movie.mkv", .keka, "movie.mkv"),
        ("/Users/me/Downloads/photos.kextraction/Info.plist", .keka, "Info.plist"),
    ])
    func theItemAtTheTopOfAWorkFolder(path: String, tool: Tool, top: String) {
        #expect(Tracker.top(of: path, for: tool) == top)
    }

    @Test(arguments: [
        ("/x/.TheUnarchiverTemp0/big compressed/mixed/plain/a.bin", Tool.theUnarchiver, ["big compressed", "mixed"]),
        ("/x/.TheUnarchiverTemp0/big compressed/a.bin", .theUnarchiver, ["big compressed"]),
        ("/x/.TheUnarchiverTemp0/photos/deep/a.jpg", .theUnarchiver, ["photos"]),
        ("/x/big compressed.tar.kextraction/Operation/mixed/plain/a.bin", .keka, ["mixed"]),
        ("/x/elsewhere/a.bin", .theUnarchiver, []),
    ])
    func theNamesAResultMayHaveFromAFileSeenWritten(path: String, tool: Tool, names: [String]) {
        #expect(Tracker.tops(of: path, for: tool, archivePath: "/x/big compressed.tar.bz2") == names)
    }

    @Test func whatIsWrittenElsewhereHasNoPlaceInAWorkFolder() {
        #expect(Tracker.top(of: "/Users/me/Downloads/photos/a.jpg", for: .theUnarchiver) == nil)
        #expect(Tracker.top(of: "/Users/me/Downloads/.TheUnarchiverTemp0", for: .theUnarchiver) == nil)
        #expect(Tracker.top(of: "/Users/me/Desktop/big.bin", for: .macPacker) == nil)
    }

    /// Seen on a real Mac, 13 Oct 2026: a 7z cut into `.001`, `.002`…
    /// is extracted like any other, and the folder The Unarchiver makes
    /// for several items is named after the first piece without its
    /// number.
    @Test func anArchiveCutIntoNumberedPiecesIsOneArchive() throws {
        let first = "/Users/me/Downloads/trip.7z.001"
        let second = "/Users/me/Downloads/trip.7z.002"
        mac.setIndex([ArchiveEntry(path: "a.jpg", size: 1_000), ArchiveEntry(path: "b.jpg", size: 2_000)],
                     format: .sevenZip, for: first, parts: [first, second])
        var tracker = mac.tracker()
        var lines = tracker.step(now: 0, processes: [unarchiver([reading(first)])])
        #expect(lines == ["trip.7z.001: The Unarchiver has it open, to extract it: 3.0 KB in 2 files (7z)"])
        mac.put(.folder(items: 1), at: temp)
        lines = tracker.step(now: 1, processes: [unarchiver([reading(first), reading(second),
                                                           writing(temp + "/trip.7z/a.jpg", size: 500)])])
        #expect(tracker.extractions.count == 1, "its pieces are one archive")
        #expect(tracker.extractions.first?.isWaiting == false)
        #expect(mac.indexReads == [first])
        _ = tracker.step(now: 2, processes: [unarchiver([reading(second), writing(temp + "/trip.7z/b.jpg", size: 2_000)])])
        #expect(tracker.extractions.count == 1)
        mac.put(.missing, at: temp)
        mac.put(.folder(items: 2), at: "/Users/me/Downloads/trip.7z")
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/trip.7z/a.jpg")
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/trip.7z/b.jpg")
        lines = tracker.step(now: 3, processes: [unarchiver([reading(second)])])
        #expect(lines.last == "trip.7z.001: complete: 3.0 KB in 2.0 s; at /Users/me/Downloads/trip.7z")
        #expect(tracker.ended.last?.ending == .complete)
    }

    /// Seen on a real Mac, 13 Oct 2026: a zip in parts as `zip -s`
    /// writes them (`photos.z01`, `photos.z02`, `photos.zip`) was taken
    /// for a zip and a RAR, two extractions for one.
    @Test func thePartsOfAZipAreNoSecondArchive() {
        mac.setIndex(entries, for: archive)
        let part = "/Users/me/Downloads/photos.z01"
        var tracker = mac.tracker()
        let lines = tracker.step(now: 0, processes: [unarchiver([reading(part), reading(archive)])])
        #expect(lines == ["photos.zip: The Unarchiver has it open, to extract it: 6.0 KB in 3 files (zip)"])
        #expect(tracker.extractions.count == 1)
        #expect(mac.indexReads == [archive])
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

    /// For an archive cut into numbered pieces, the folder made for its
    /// several items keeps the archive's own ending (seen on a real Mac,
    /// 13 Oct 2026: `several tops.7z` for `several tops.7z.001`); its one
    /// item keeps its name.
    @Test(arguments: [
        ([ArchiveEntry(path: "a.txt", size: 1), ArchiveEntry(path: "b.txt", size: 1)], "trip.7z", "trip.7z-1"),
        ([ArchiveEntry(path: "photos", size: 0, isFolder: true), ArchiveEntry(path: "photos/a.jpg", size: 1)], "photos", "photos-1"),
    ])
    func theNamesOfTheResultOfNumberedPieces(entries: [ArchiveEntry], first: String, second: String) {
        let names = Tracker.namesBeside(of: .theUnarchiver, archivePath: "/x/trip.7z.001",
                                        index: ArchiveIndex(format: .sevenZip, entries: entries, parts: []), in: "/x").names
        #expect(Array(names.prefix(2)) == ["/x/" + first, "/x/" + second])
    }
}
