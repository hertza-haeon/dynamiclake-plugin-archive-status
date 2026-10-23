// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// What Keka (1.6.8) was seen to do on a real Mac on 12 Oct 2026,
/// replayed look by look: it makes a folder named after the archive beside
/// it (`photos.kextraction`), then gives the archive to a helper of its
/// own (`kekaunar`, `keka7zz`, `kekatar`…), which extracts into
/// `photos.kextraction/Operation`; a tenth of a second after the helper is
/// gone, the result is beside the archive under its name and that folder
/// is gone. Two archives are two helpers, at the same time.
struct KekaTrackingTests {
    let mac = FakeMac()
    let archive = "/Users/me/Downloads/photos.zip"
    let work = "/Users/me/Downloads/photos.kextraction"
    var operation: String { work + "/Operation" }
    let entries = [
        ArchiveEntry(path: "photos", size: 0, isFolder: true),
        ArchiveEntry(path: "photos/a.jpg", size: 1_000),
        ArchiveEntry(path: "photos/b.jpg", size: 2_000),
        ArchiveEntry(path: "photos/c.jpg", size: 3_000),
    ]

    /// The result put in place under `name`, with these files in it, and
    /// the work folder gone.
    private func finish(as name: String, files: [(String, UInt64)], work: String? = nil) {
        mac.put(.missing, at: work ?? self.work)
        mac.put(.folder(items: files.count), at: "/Users/me/Downloads/" + name)
        for (file, size) in files {
            mac.put(.file(size: size), at: "/Users/me/Downloads/\(name)/\(file)")
        }
    }

    /// Extracts the archive as far as its second file.
    private func begin(_ tracker: inout Tracker) -> [String] {
        mac.put(.folder(items: 1), at: work)
        var lines = tracker.step(now: 0, processes: [kekaHelper([reading(archive)])])
        lines += tracker.step(now: 0.1, processes: [kekaHelper([reading(archive)])])
        lines += tracker.step(now: 5, processes: [kekaHelper([reading(archive), writing(operation + "/photos/a.jpg", size: 400)])])
        lines += tracker.step(now: 6, processes: [kekaHelper([reading(archive), writing(operation + "/photos/b.jpg", size: 1_500)])])
        return lines
    }

    @Test func aHelperWithAnArchiveBesideItsWorkFolderWaitsThenBeginsWithItsFirstFile() throws {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        // (Not at the first look: see `theDoubleOfAHelperIsNoSecondExtraction`.)
        var lines = tracker.step(now: 0, processes: [kekaHelper([reading(archive)])])
        #expect(lines.isEmpty)
        lines = tracker.step(now: 0.1, processes: [kekaHelper([reading(archive)])])
        #expect(lines == ["photos.zip: Keka has it open, to extract it: 6.0 KB in 3 files (zip)"])
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.isWaiting)
        #expect(extraction.total == 6_000)
        // Its helper reads a zip of very many files through before the
        // first of them (3 s for 150,000): no standstill.
        for second in 1...30 {
            #expect(tracker.step(now: Double(second), processes: [kekaHelper([reading(archive)])]).isEmpty)
        }
        #expect(tracker.extractions.first?.stalledSince == nil)

        lines = tracker.step(now: 31, processes: [kekaHelper([reading(archive), writing(operation + "/photos/a.jpg", size: 400)])])
        #expect(lines.first == "photos.zip: Keka is extracting it: 6.0 KB in 3 files (zip), into \(operation)")
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.isWaiting == false)
        #expect(extraction.id == 1, "the same extraction, begun")
        #expect(extraction.startedAt == 31)
        #expect(extraction.written == 400)
        #expect(extraction.tool == .keka)
        // Where the result will be: the first of its names that is free.
        _ = tracker.step(now: 31.1, processes: [kekaHelper([reading(archive), writing(operation + "/photos/a.jpg", size: 900)])])
        #expect(tracker.extractions.first?.result == "/Users/me/Downloads/photos")
    }

    /// Seen with 150,000 small files beside another extraction: the first
    /// file caught being written was the 46,241st, eight seconds in, and
    /// the ring spun until then. The first files are looked for where the
    /// helper writes them.
    @Test func itsBeginningIsFoundWithoutAFileCaughtBeingWritten() throws {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(archive)])])
        _ = tracker.step(now: 0.1, processes: [kekaHelper([reading(archive)])])
        #expect(tracker.extractions.first?.isWaiting == true)
        // Its first two files are there, and the helper has none open.
        mac.put(.file(size: 1_000), at: operation + "/photos/a.jpg")
        mac.put(.file(size: 700), at: operation + "/photos/b.jpg")
        let lines = tracker.step(now: 3, processes: [kekaHelper([reading(archive)])])
        #expect(lines.first == "photos.zip: Keka is extracting it: 6.0 KB in 3 files (zip), into \(operation)")
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.isWaiting == false)
        #expect(extraction.id == 1)
        #expect(extraction.startedAt == 3)
        #expect(extraction.written == 1_700, "as far as the files that are there")
    }

    /// A file left in such a folder by something earlier is no beginning.
    @Test func anOldFileInTheWorkFolderIsNoBeginning() {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 1), at: work)
        mac.put(.file(size: 1_000), at: operation + "/photos/a.jpg", changedAt: mac.clock - 500)
        var tracker = mac.tracker()
        for look in 0..<5 {
            _ = tracker.step(now: Double(look), processes: [kekaHelper([reading(archive)])])
        }
        #expect(tracker.extractions.first?.isWaiting == true)
    }

    /// Seen: the helper gone, then, 60 to 170 ms later, the result in place
    /// and the work folder gone in the same instant.
    @Test func theHelperGoneThenTheResultInPlaceIsComplete() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        // The helper is gone, the work folder not yet: nothing to say.
        var lines = tracker.step(now: 9, processes: [])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.count == 1)
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        lines = tracker.step(now: 9.1, processes: [])
        // (It ended when the helper was gone.)
        #expect(lines == ["photos.zip: complete: 6.0 KB in 4.0 s; at /Users/me/Downloads/photos"])
        #expect(tracker.extractions.isEmpty)
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .complete)
        #expect(ended.result == "/Users/me/Downloads/photos")
        #expect(ended.revealPaths == ["/Users/me/Downloads/photos"])
        #expect(tracker.step(now: 10, processes: []).isEmpty)
        #expect(tracker.attention == .none)
    }

    /// Seen: `very many small files 2`, then `3`, `4`, `5`.
    @Test func aNameThatIsTakenGetsANumber() throws {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/photos", changedAt: mac.clock - 500)
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/photos/a.jpg", changedAt: mac.clock - 500)
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/photos/b.jpg", changedAt: mac.clock - 500)
        mac.put(.file(size: 3_000), at: "/Users/me/Downloads/photos/c.jpg", changedAt: mac.clock - 500)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        #expect(tracker.extractions.first?.result == "/Users/me/Downloads/photos 2")
        finish(as: "photos 2", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        let lines = tracker.step(now: 9, processes: [])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 4.0 s; at /Users/me/Downloads/photos 2")
    }

    /// Seen with a damaged archive: Keka too went through it to its end
    /// and put in place what its helper could read.
    @Test func aResultInPlaceWithFilesMissingIsNotComplete() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        finish(as: "photos", files: [("a.jpg", 1_000), ("c.jpg", 2_999)])
        let lines = tracker.step(now: 9, processes: [])
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
        mac.put(.missing, at: work)
        let lines = tracker.step(now: 9, processes: [])
        #expect(lines.last == "photos.zip: stopped short at 41 % (2.5 KB of 6.0 KB) after 4.0 s")
        #expect(tracker.ended.last?.ending == .stopped)
        #expect(tracker.ended.last?.result == nil, "the name it would have had is no place")
        #expect(tracker.ended.last?.revealPaths.isEmpty == true)
    }

    /// The helper gone and the work folder left there (Keka itself gone,
    /// say): after a long wait, an end that can't be told.
    @Test func theWorkFolderLeftBehindCannotBeTold() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        let wait = Tracker.kekaFinishWait(files: 3)
        #expect(tracker.step(now: 9, processes: []).isEmpty)
        #expect(tracker.step(now: 9 + wait - 0.1, processes: []).isEmpty)
        let lines = tracker.step(now: 9 + wait, processes: [])
        #expect(lines.last?.hasPrefix("photos.zip: ended after 4.0 s, and whether it got to its end can't be told") == true)
        #expect(tracker.ended.last?.ending == .unknown)
        #expect(tracker.ended.last?.result == nil)
    }

    /// Seen with an archive marked as downloaded from the internet: the
    /// helper gone, Keka marked each of the 150,000 extracted files the
    /// same, and put the result in place 14 s later. All of it is written
    /// meanwhile, and that is no standstill.
    @Test func whatKekaDoesAfterItsHelperIsWaitedFor() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        mac.put(.file(size: 1_000), at: operation + "/photos/a.jpg")
        mac.put(.file(size: 2_000), at: operation + "/photos/b.jpg")
        mac.put(.file(size: 3_000), at: operation + "/photos/c.jpg")
        for second in 9...22 {
            let lines = tracker.step(now: Double(second), processes: [])
            #expect(lines.allSatisfy { $0.contains(" · ") }, "nothing but progress: \(lines)")
            let extraction = try #require(tracker.extractions.first)
            #expect(extraction.written == 6_000, "all of it is written")
            #expect(extraction.stalledSince == nil)
        }
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        let lines = tracker.step(now: 23, processes: [])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 4.0 s; at /Users/me/Downloads/photos")
        #expect(tracker.ended.last?.ending == .complete)
    }

    /// A cancel, 12 Oct: the helper gone at once, the work
    /// folder emptied for 3.4 s (63,000 files), then gone, and nothing put
    /// in place. However long the emptying takes, that is `stopped`.
    @Test func aCancelWhoseFolderTakesSecondsToGoIsStopped() throws {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        for second in 9...20 {
            #expect(tracker.step(now: Double(second), processes: []).isEmpty)
        }
        mac.put(.missing, at: work)
        let lines = tracker.step(now: 21, processes: [])
        #expect(lines.last == "photos.zip: stopped short at 41 % (2.5 KB of 6.0 KB) after 4.0 s")
        #expect(tracker.ended.last?.ending == .stopped)
        #expect(tracker.ended.last?.result == nil)
    }

    @Test(arguments: [(3, 30.0), (60_000, 30.0), (150_000, 75.0), (1_000_000, 500.0)])
    func theWaitForKekaGrowsWithTheNumberOfFiles(files: Int, seconds: Double) {
        #expect(Tracker.kekaFinishWait(files: files) == seconds)
        #expect(Tracker.kekaFinishWait(files: nil) == 120)
    }

    /// Seen: several items at the top are written right into `Operation`,
    /// and end up in a folder named after the archive.
    @Test func severalItemsGoIntoAFolderNamedAfterTheArchive() throws {
        mac.setIndex([ArchiveEntry(path: "first.txt", size: 10), ArchiveEntry(path: "second.txt", size: 20)], for: archive)
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(archive), writing(operation + "/first.txt", size: 4)])])
        #expect(tracker.extractions.first?.destination == operation)
        finish(as: "photos", files: [("first.txt", 10), ("second.txt", 20)])
        let lines = tracker.step(now: 1, processes: [])
        #expect(lines.last == "photos.zip: complete: 30 bytes in 1.0 s; at /Users/me/Downloads/photos")
    }

    /// Seen: `one big file.bin`, then `one big file 2.bin`.
    @Test(arguments: [("movie.mkv", false), ("movie 2.mkv", true)])
    func oneFileIsPutThereUnderItsOwnName(name: String, taken: Bool) throws {
        mac.setIndex([ArchiveEntry(path: "movie.mkv", size: 5_000)], for: archive)
        if taken {
            mac.put(.file(size: 5_000), at: "/Users/me/Downloads/movie.mkv", changedAt: mac.clock - 500)
        }
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(archive), writing(operation + "/movie.mkv", size: 100)])])
        mac.put(.missing, at: work)
        mac.put(.file(size: 5_000), at: "/Users/me/Downloads/" + name)
        let lines = tracker.step(now: 2, processes: [])
        #expect(lines.last == "photos.zip: complete: 5.0 KB in 2.0 s; at /Users/me/Downloads/\(name)")
    }

    /// SIMULATED only: should Keka be set to put an archive's one item in
    /// a folder named after the archive, as The Unarchiver can be, the
    /// result is found there.
    @Test func oneItemPutInAFolderNamedAfterTheArchiveIsFoundThere() throws {
        let trip = "/Users/me/Downloads/trip.zip"
        let tripWork = "/Users/me/Downloads/trip.kextraction"
        mac.setIndex(entries, for: trip)
        mac.put(.folder(items: 1), at: tripWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(trip), writing(tripWork + "/Operation/photos/a.jpg", size: 400)])])
        mac.put(.missing, at: tripWork)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/trip")
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/trip/photos")
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/trip/photos/a.jpg")
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/trip/photos/b.jpg")
        mac.put(.file(size: 3_000), at: "/Users/me/Downloads/trip/photos/c.jpg")
        let lines = tracker.step(now: 2, processes: [])
        #expect(lines.last == "trip.zip: complete: 6.0 KB in 2.0 s; at /Users/me/Downloads/trip")
    }

    /// Seen with `tarball.tar.gz`: the work folder is
    /// `tarball.tar.kextraction`, and `kekatar` reads the archive itself.
    @Test func aCompressedTarHasItsWorkFolderNamedAfterTheTar() throws {
        let tarball = "/Users/me/Downloads/tarball.tar.gz"
        let tarWork = "/Users/me/Downloads/tarball.tar.kextraction"
        mac.setIndex(entries, format: .compressedTar, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball)])])
        var lines = tracker.step(now: 0.1, processes: [kekaHelper([reading(tarball)])])
        #expect(lines == ["tarball.tar.gz: Keka has it open, to extract it: 6.0 KB in 3 files (compressed tar)"])
        lines = tracker.step(now: 1, processes: [kekaHelper([reading(tarball), writing(tarWork + "/Operation/photos/a.jpg", size: 100)])])
        #expect(lines.first == "tarball.tar.gz: Keka is extracting it: 6.0 KB in 3 files (compressed tar), into \(tarWork)/Operation")
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)], work: tarWork)
        #expect(tracker.step(now: 4, processes: []).last == "tarball.tar.gz: complete: 6.0 KB in 3.0 s; at /Users/me/Downloads/photos")
    }

    /// Seen with two archives opened together: a helper each, at the same
    /// time, each in a work folder of its own.
    @Test func twoArchivesAreExtractedAtTheSameTimeEachByItsHelper() throws {
        let second = "/Users/me/Downloads/music.rar"
        let secondWork = "/Users/me/Downloads/music.kextraction"
        mac.setIndex(entries, for: archive)
        mac.setIndex([ArchiveEntry(path: "album.flac", size: 9_000)], format: .rar5, for: second)
        mac.put(.folder(items: 1), at: work)
        mac.put(.folder(items: 1), at: secondWork)
        var tracker = mac.tracker()
        func both(_ first: [OpenFile], _ other: [OpenFile]) -> [ToolProcess] {
            [kekaHelper([reading(archive)] + first, pid: 801), kekaHelper([reading(second)] + other, pid: 802)]
        }
        _ = tracker.step(now: 0, processes: both([], []))
        var lines = tracker.step(now: 0.1, processes: both([], []))
        #expect(lines.count == 2)
        #expect(tracker.extractions.map(\.isWaiting) == [true, true])
        lines = tracker.step(now: 1, processes: both([writing(operation + "/photos/a.jpg", size: 400)],
                                                      [writing(secondWork + "/Operation/album.flac", size: 3_000)]))
        #expect(tracker.extractions.map(\.isWaiting) == [false, false])
        #expect(Set(tracker.extractions.map(\.name)) == ["photos.zip", "music.rar"])

        // The second is done first: its helper is gone, the other's not.
        mac.put(.missing, at: secondWork)
        mac.put(.file(size: 9_000), at: "/Users/me/Downloads/album.flac")
        lines = tracker.step(now: 2, processes: [kekaHelper([reading(archive), writing(operation + "/photos/b.jpg", size: 100)], pid: 801)])
        #expect(lines.contains("music.rar: complete: 9.0 KB in 1.0 s; at /Users/me/Downloads/album.flac"))
        #expect(tracker.extractions.map(\.name) == ["photos.zip"])
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        lines = tracker.step(now: 5, processes: [])
        #expect(lines.last == "photos.zip: complete: 6.0 KB in 4.0 s; at /Users/me/Downloads/photos")
        #expect(tracker.ended.map(\.ending) == [.complete, .complete])
    }

    /// Seen with a `tar.xz`: the helper starts another, and for an instant
    /// there are two of it with the archive open.
    @Test func theDoubleOfAHelperIsNoSecondExtraction() throws {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(archive)], pid: 801), kekaHelper([reading(archive)], pid: 802)])
        // The double has become the other program, with nothing open.
        var lines = tracker.step(now: 0.1, processes: [kekaHelper([reading(archive)], pid: 801), kekaHelper([], pid: 802)])
        #expect(lines == ["photos.zip: Keka has it open, to extract it: 6.0 KB in 3 files (zip)"])
        #expect(tracker.extractions.count == 1)
        // And had it kept the archive a look longer: still one extraction.
        lines = tracker.step(now: 0.2, processes: [kekaHelper([reading(archive)], pid: 801), kekaHelper([reading(archive)], pid: 802)])
        lines += tracker.step(now: 0.3, processes: [kekaHelper([reading(archive)], pid: 801), kekaHelper([reading(archive)], pid: 802)])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.count == 1)
        lines = tracker.step(now: 0.4, processes: [kekaHelper([reading(archive)], pid: 801), kekaHelper([], pid: 802)])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.map(\.id) == [1])
    }

    /// Seen on a real Mac, 13 Oct 2026, with a `tar.gz` cut short: Keka
    /// went at it with three helpers in two seconds, each in the same
    /// folder (the first wrote 1,272 of its files and gave up, the second
    /// unpacked a tar into the folder, the third began again), then took
    /// the folder away and left nothing. One extraction, not two: the card
    /// read `0/2 Extractions Completed` for the one archive.
    @Test func oneHelperAfterTheOtherAtTheSameArchiveIsOneExtraction() throws {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(archive)], pid: 801), kekaHelper([], pid: 802)])
        var lines = tracker.step(now: 0.1, processes: [kekaHelper([reading(archive), writing(operation + "/photos/b.jpg", size: 1_500)], pid: 801)])
        #expect(lines.contains("photos.zip: Keka is extracting it: 6.0 KB in 3 files (zip), into \(operation)"))
        #expect(tracker.extractions.first?.written == 2_500)
        // The first helper is gone; its folder is still there.
        #expect(tracker.step(now: 0.9, processes: []).isEmpty)
        // The second unpacks the archive into the folder: no file of the index.
        lines = tracker.step(now: 1.1, processes: [kekaHelper([reading(archive), writing(operation + "/photos.tar", size: 4_000)], pid: 803)])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.map(\.id) == [1])
        #expect(tracker.step(now: 1.3, processes: []).isEmpty)
        // The third begins again, in the same folder.
        lines = tracker.step(now: 1.5, processes: [kekaHelper([reading(archive), writing(operation + "/photos/a.jpg", size: 0)], pid: 804)])
        #expect(lines.first == "photos.zip: Keka goes at it again, with another of its helpers")
        #expect(lines.contains("photos.zip: Keka is extracting it: 6.0 KB in 3 files (zip), into \(operation)"))
        var extraction = try #require(tracker.extractions.first)
        #expect(tracker.extractions.count == 1)
        #expect(extraction.id == 1, "the same extraction, begun again")
        #expect(extraction.isWaiting == false)
        #expect(extraction.startedAt == 1.5)
        #expect(extraction.written == 0)
        _ = tracker.step(now: 1.8, processes: [kekaHelper([reading(archive), writing(operation + "/photos/c.jpg", size: 2_000)], pid: 804)])
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 5_000)
        // It gives up too, and Keka takes the folder away.
        #expect(tracker.step(now: 2.0, processes: []).isEmpty)
        mac.put(.missing, at: work)
        lines = tracker.step(now: 2.2, processes: [])
        #expect(lines == ["photos.zip: stopped short at 83 % (5.0 KB of 6.0 KB) after 0.5 s"])
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.ended.map(\.id) == [1])
        #expect(tracker.ended.last?.ending == .stopped)
    }

    /// The same when the next helper is seen at the very look the one
    /// before is gone.
    @Test func theNextHelperSeenAsTheFirstIsGoneCarriesItOn() {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        let lines = tracker.step(now: 7, processes: [kekaHelper([reading(archive), writing(operation + "/photos/a.jpg", size: 100)], pid: 804)])
        #expect(lines.first == "photos.zip: Keka goes at it again, with another of its helpers")
        #expect(tracker.extractions.map(\.id) == [1])
        #expect(tracker.extractions.first?.written == 100)
    }

    /// Seen the same day with a zip cut short, which has no index left to
    /// read: two helpers, the first reading it through and writing
    /// nothing, the second writing what it found. One extraction.
    @Test func oneHelperAfterTheOtherWithoutAnIndexIsOneExtraction() {
        mac.setIndexFailure(.notAnArchive, for: archive)
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(archive, size: 9_000, at: 8_000)], pid: 801)])
        var lines = tracker.step(now: 0.1, processes: [kekaHelper([reading(archive, size: 9_000, at: 6_000)], pid: 801)])
        #expect(lines.first == "photos.zip: Keka has it open, to extract it: its size can't be read")
        #expect(tracker.step(now: 1.1, processes: []).isEmpty)
        lines = tracker.step(now: 1.3, processes: [kekaHelper([reading(archive, size: 9_000, at: 1_000),
                                                             writing(operation + "/photos/a.jpg", size: 400)], pid: 802)])
        #expect(lines.first == "photos.zip: Keka goes at it again, with another of its helpers")
        #expect(tracker.extractions.map(\.id) == [1])
        #expect(tracker.extractions.first?.isWaiting == false)
        _ = tracker.step(now: 1.6, processes: [])
        mac.put(.missing, at: work)
        _ = tracker.step(now: 1.8, processes: [])
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.ended.map(\.id) == [1], "one extraction ended, not two")
    }

    /// Another archive's helper is nobody's next helper.
    @Test func aHelperOfAnotherArchiveCarriesNothingOn() {
        let second = "/Users/me/Downloads/music.zip"
        mac.setIndex(entries, for: archive)
        mac.setIndex([ArchiveEntry(path: "album.flac", size: 9_000)], for: second)
        var tracker = mac.tracker()
        _ = begin(&tracker)
        _ = tracker.step(now: 7, processes: [])
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/music.kextraction")
        let lines = tracker.step(now: 7.2, processes: [kekaHelper(
            [reading(second), writing("/Users/me/Downloads/music.kextraction/Operation/album.flac", size: 3_000)], pid: 805)])
        #expect(lines.contains { $0.contains("goes at it again") } == false)
        #expect(Set(tracker.extractions.map(\.id)) == [1, 2])
    }

    /// Seen on a real Mac, 13 Oct 2026: a 7z cut into `.001`, `.002`…
    /// Keka's work folder is named after the first piece without its
    /// number (`trip.7z.kextraction`), and the folder it makes for several
    /// items after the same with an underscore for its dot (`trip_7z`).
    @Test func anArchiveCutIntoNumberedPiecesIsOneArchive() throws {
        let first = "/Users/me/Downloads/trip.7z.001"
        let second = "/Users/me/Downloads/trip.7z.002"
        let work = "/Users/me/Downloads/trip.7z.kextraction"
        mac.setIndex([ArchiveEntry(path: "a.jpg", size: 1_000), ArchiveEntry(path: "b.jpg", size: 2_000)],
                     format: .sevenZip, for: first, parts: [first, second])
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(first)])])
        var lines = tracker.step(now: 0.1, processes: [kekaHelper([reading(first), reading(second)])])
        #expect(lines == ["trip.7z.001: Keka has it open, to extract it: 3.0 KB in 2 files (7z)"])
        lines = tracker.step(now: 1, processes: [kekaHelper([reading(second), writing(work + "/Operation/b.jpg", size: 2_000)])])
        #expect(tracker.extractions.count == 1, "its pieces are one archive")
        #expect(mac.indexReads == [first])
        _ = tracker.step(now: 1.5, processes: [])
        mac.put(.missing, at: work)
        mac.put(.folder(items: 2), at: "/Users/me/Downloads/trip_7z")
        mac.put(.file(size: 1_000), at: "/Users/me/Downloads/trip_7z/a.jpg")
        mac.put(.file(size: 2_000), at: "/Users/me/Downloads/trip_7z/b.jpg")
        lines = tracker.step(now: 1.7, processes: [])
        #expect(lines.last == "trip.7z.001: complete: 3.0 KB in 0.5 s; at /Users/me/Downloads/trip_7z")
        #expect(tracker.ended.last?.ending == .complete)
    }

    @Test(arguments: [
        ("/x/trip.7z.001", "trip_7z", "trip_7z 2"),
        ("/x/my.dotted name.zip.001", "my.dotted name_zip", "my.dotted name_zip 2"),
        ("/x/trip.7z", "trip", "trip 2"),
    ])
    func theFolderItMakesForSeveralItems(archive: String, first: String, second: String) {
        let items = [ArchiveEntry(path: "a.txt", size: 1), ArchiveEntry(path: "b.txt", size: 1)]
        let names = Tracker.namesBeside(of: .keka, archivePath: archive,
                                        index: ArchiveIndex(format: .sevenZip, entries: items, parts: []), in: "/x").names
        #expect(Array(names.prefix(2)) == ["/x/" + first, "/x/" + second])
    }

    /// Seen on a real Mac, 13 Oct 2026: a zip named `app.jar` and a
    /// `data.tar.zst` extracted with Keka showed nothing. A helper that
    /// reads one of the user's files beside the folder Keka made for it
    /// extracts it, whatever its name; what it is is read from the file.
    @Test func aZipUnderAnotherNameIsFollowedLikeAnyZip() throws {
        let jar = "/Users/me/Downloads/app.jar"
        let jarWork = "/Users/me/Downloads/app.kextraction"
        mac.setIndex(entries, for: jar)
        mac.put(.folder(items: 1), at: jarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(jar)])])
        var lines = tracker.step(now: 0.1, processes: [kekaHelper([reading(jar)])])
        #expect(lines == ["app.jar: Keka has it open, to extract it: 6.0 KB in 3 files (zip)"])
        lines = tracker.step(now: 1, processes: [kekaHelper([reading(jar), writing(jarWork + "/Operation/photos/a.jpg", size: 400)])])
        #expect(lines.first == "app.jar: Keka is extracting it: 6.0 KB in 3 files (zip), into \(jarWork)/Operation")
        _ = tracker.step(now: 2, processes: [])
        mac.put(.missing, at: jarWork)
        mac.put(.folder(items: 3), at: "/Users/me/Downloads/photos")
        for (file, size) in [("a.jpg", UInt64(1_000)), ("b.jpg", 2_000), ("c.jpg", 3_000)] {
            mac.put(.file(size: size), at: "/Users/me/Downloads/photos/" + file)
        }
        lines = tracker.step(now: 2.2, processes: [])
        #expect(lines.last == "app.jar: complete: 6.0 KB in 1.0 s; at /Users/me/Downloads/photos")
    }

    /// A `tar.zst`: one helper reads the archive and hands what it
    /// unpacks to another, which writes the files and has no archive of
    /// its own. What the second writes into the first's work folder is
    /// that archive's: followed by how far it is read, and done with its
    /// result in place.
    @Test func whatAnotherHelperWritesIntoTheWorkFolderIsThatArchives() throws {
        let zst = "/Users/me/Downloads/data.tar.zst"
        let zstWork = "/Users/me/Downloads/data.tar.kextraction"
        mac.setIndexFailure(.notAnArchive, for: zst)
        mac.put(.folder(items: 1), at: zstWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(zst, size: 9_000, at: 100)], pid: 801), kekaHelper([], pid: 802)])
        var lines = tracker.step(now: 0.1, processes: [kekaHelper([reading(zst, size: 9_000, at: 500)], pid: 801), kekaHelper([], pid: 802)])
        #expect(lines.first == "data.tar.zst: Keka has it open, to extract it: its size can't be read")
        lines = tracker.step(now: 1, processes: [
            kekaHelper([reading(zst, size: 9_000, at: 4_000)], pid: 801),
            kekaHelper([writing(zstWork + "/Operation/mixed/plain/a.bin", size: 300)], pid: 802),
        ])
        let extraction = try #require(tracker.extractions.first)
        #expect(tracker.extractions.count == 1)
        #expect(extraction.isWaiting == false)
        #expect(extraction.measuresArchive)
        #expect(extraction.written == 4_000)
        _ = tracker.step(now: 2, processes: [])
        mac.put(.missing, at: zstWork)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/mixed")
        lines = tracker.step(now: 2.2, processes: [])
        #expect(lines.last?.contains("done after") == true)
        #expect(tracker.ended.last?.ending == .unchecked)
        #expect(tracker.ended.last?.result == "/Users/me/Downloads/mixed", "under the name of what was seen written")
    }

    /// A helper that compresses reads the user's files too: with no folder
    /// of Keka's for any of them, and nothing written into one, none is
    /// an archive.
    @Test func whatAHelperReadsToCompressIsNoArchiveWhateverItsName() {
        var tracker = mac.tracker()
        for look in 0..<5 {
            let lines = tracker.step(now: Double(look), processes: [kekaHelper([
                reading("/Users/me/Documents/project/notes.txt"), reading("/Users/me/Documents/project/disc.iso"),
                writing("/Users/me/Documents/project.7z", size: UInt64(look) * 1_000),
            ])])
            #expect(lines.isEmpty)
        }
        #expect(tracker.extractions.isEmpty)
        #expect(mac.indexReads.isEmpty)
    }

    /// Keka's helpers compress too, and read whatever they compress: an
    /// archive among it is no extraction, and isn't read.
    @Test func aHelperThatCompressesIsNoExtraction() {
        let inner = "/Users/me/Documents/project/old.zip"
        mac.setIndex(entries, for: inner)
        var tracker = mac.tracker()
        for look in 0..<5 {
            let lines = tracker.step(now: Double(look), processes: [kekaHelper([
                reading(inner, size: 50_000, at: UInt64(look) * 10_000),
                writing("/Users/me/Documents/project.7z", size: UInt64(look) * 9_000),
            ])])
            #expect(lines.isEmpty)
        }
        #expect(tracker.extractions.isEmpty)
        #expect(mac.indexReads.isEmpty)
        #expect(tracker.step(now: 6, processes: []).isEmpty)
    }

    /// An extraction over before one of its files was caught being
    /// written is told from what it left. (Seen: 629 MB in 0.4 s.)
    @Test func oneTooQuickToCatchIsToldFromWhatItLeft() throws {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(archive)])])
        _ = tracker.step(now: 0.1, processes: [kekaHelper([reading(archive)])])
        #expect(tracker.step(now: 0.4, processes: []).isEmpty)
        finish(as: "photos", files: [("a.jpg", 1_000), ("b.jpg", 2_000), ("c.jpg", 3_000)])
        let lines = tracker.step(now: 0.5, processes: [])
        #expect(lines == ["photos.zip: complete: 6.0 KB in 0.3 s; at /Users/me/Downloads/photos"])
        let ended = try #require(tracker.ended.last)
        #expect(ended.isWaiting == false)
        #expect(ended.written == 6_000)
    }

    @Test func oneThatWaitedAndLeftNothingWasNeverExtracted() {
        mac.setIndex(entries, for: archive)
        mac.put(.folder(items: 1), at: work)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(archive)])])
        _ = tracker.step(now: 0.1, processes: [kekaHelper([reading(archive)])])
        mac.put(.missing, at: work)
        let lines = tracker.step(now: 3, processes: [])
        #expect(lines == ["photos.zip: let go of without being extracted"])
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.ended.isEmpty)
    }

    /// SIMULATED only: Keka set to extract somewhere else than beside the
    /// archive. No work folder beside the archive, so no waiting; the
    /// extraction begins with the first file caught in a work folder,
    /// wherever that is, and the result is looked for there.
    @Test func aWorkFolderElsewhereIsFoundFromTheFirstFileWritten() throws {
        let elsewhere = "/Volumes/Out/photos.kextraction"
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        var lines = tracker.step(now: 0, processes: [kekaHelper([reading(archive)])])
        lines += tracker.step(now: 0.1, processes: [kekaHelper([reading(archive)])])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.isEmpty)
        mac.put(.folder(items: 1), at: elsewhere)
        lines = tracker.step(now: 1, processes: [kekaHelper([reading(archive), writing(elsewhere + "/Operation/photos/a.jpg", size: 400)])])
        #expect(lines.first == "photos.zip: Keka is extracting it: 6.0 KB in 3 files (zip), into \(elsewhere)/Operation")
        mac.put(.missing, at: elsewhere)
        mac.put(.folder(items: 3), at: "/Volumes/Out/photos")
        mac.put(.file(size: 1_000), at: "/Volumes/Out/photos/a.jpg")
        mac.put(.file(size: 2_000), at: "/Volumes/Out/photos/b.jpg")
        mac.put(.file(size: 3_000), at: "/Volumes/Out/photos/c.jpg")
        #expect(tracker.step(now: 3, processes: []).last == "photos.zip: complete: 6.0 KB in 2.0 s; at /Volumes/Out/photos")
    }

    /// An archive whose index can't be read is followed by how far the
    /// helper has read into it; its end can't be checked file by file.
    /// With its result in place it is done, which is not said complete
    /// (seen on a real Mac, 13 Oct 2026, with a `tar.bz2` of 492 MB and
    /// with an archive in a folder DynamicLake wasn't let into: the card
    /// went without a word).
    @Test func anArchiveWithoutAnIndexIsFollowedByHowFarItIsRead() throws {
        let tarball = "/Users/me/Downloads/huge.tar.gz"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.unreadable, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        var lines = tracker.step(now: 0.1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 200)])])
        #expect(lines == ["huge.tar.gz: Keka has it open, to extract it: its size can't be read",
                          "huge.tar.gz: followed from now by how far the archive has been read, of its 10.0 KB"])
        lines = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 4_000),
                                                             writing(tarWork + "/Operation/data/a.bin", size: 100)])])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.measuresArchive)
        #expect(extraction.total == 10_000)
        #expect(extraction.written == 4_000)
        mac.put(.missing, at: tarWork)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/data")
        lines = tracker.step(now: 3, processes: [])
        #expect(lines.last == "huge.tar.gz: done after 2.0 s: its result is in place, and its files couldn't be looked at "
            + "(no list of the archive's contents); at /Users/me/Downloads/data")
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .unchecked)
        #expect(ended.result == "/Users/me/Downloads/data")
        #expect(ended.written == 10_000, "all of the archive, at the end")
    }

    /// Without an index and with nothing put in place, it stopped: Keka
    /// takes its folder away and leaves nothing on a cancel.
    @Test func withoutAnIndexNothingPutInPlaceIsStopped() throws {
        let tarball = "/Users/me/Downloads/huge.tar.gz"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.unreadable, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 4_000),
                                                         writing(tarWork + "/Operation/data/a.bin", size: 100)])])
        mac.put(.missing, at: tarWork)
        let lines = tracker.step(now: 3, processes: [])
        #expect(lines.last?.hasPrefix("huge.tar.gz: stopped short at 40 % (4.0 KB of 10.0 KB of the archive read)") == true)
        #expect(tracker.ended.last?.ending == .stopped)
        #expect(tracker.ended.last?.result == nil)
    }

    /// Something of the result's name that was there before is not its
    /// result: a cancel beside an earlier copy is stopped.
    @Test func withoutAnIndexAnEarlierCopyIsNoResult() {
        let tarball = "/Users/me/Downloads/huge.tar.gz"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.unreadable, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/data", changedAt: mac.clock - 900)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 4_000),
                                                         writing(tarWork + "/Operation/data/a.bin", size: 100)])])
        mac.put(.missing, at: tarWork)
        _ = tracker.step(now: 3, processes: [])
        #expect(tracker.ended.last?.ending == .stopped)
    }

    /// The result of several items is a folder named after the archive,
    /// and its name may be taken: the latest of its names is the result.
    @Test func withoutAnIndexTheResultIsFoundUnderTheArchivesNameToo() throws {
        let tarball = "/Users/me/Downloads/huge.tar.gz"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.unreadable, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        mac.put(.folder(items: 2), at: "/Users/me/Downloads/huge", changedAt: mac.clock - 900)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 4_000),
                                                         writing(tarWork + "/Operation/a.bin", size: 100)])])
        mac.put(.missing, at: tarWork)
        mac.clock += 5
        mac.put(.folder(items: 2), at: "/Users/me/Downloads/huge 2")
        _ = tracker.step(now: 3, processes: [])
        let ended = try #require(tracker.ended.last)
        #expect(ended.ending == .unchecked)
        #expect(ended.result == "/Users/me/Downloads/huge 2")
    }

    /// Seen on a real Mac, 13 Oct 2026: a `tar.bz2` of 492 MB takes
    /// seventeen seconds to unpack, and the plugin gives a list three. It
    /// is read on beside the loop; the extraction is followed by how far
    /// the archive is read meanwhile, and at the end its files are looked
    /// at by the list: complete, not only done.
    @Test func aListReadBesideTheLoopComesInTimeToLookAtTheFiles() throws {
        let tarball = "/Users/me/Downloads/huge.tar.bz2"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        let listed = [ArchiveEntry(path: "data/a.bin", size: 100), ArchiveEntry(path: "data/b.bin", size: 300)]
        mac.setIndexFailure(.tooLarge, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 4_000),
                                                         writing(tarWork + "/Operation/data/a.bin", size: 100)])])
        #expect(mac.laterBegun == [tarball])
        #expect(tracker.extractions.first?.measuresArchive == true)
        // The list is there while the helper is still at work.
        mac.finishLaterIndex(listed, for: tarball)
        var lines = tracker.step(now: 2, processes: [kekaHelper([reading(tarball, size: 10_000, at: 8_000),
                                                                 writing(tarWork + "/Operation/data/b.bin", size: 200)])])
        #expect(lines.first == "huge.tar.bz2: its list of contents is read (400 bytes in 2 files (compressed tar)): "
            + "its files will be looked at by it at the end")
        #expect(tracker.extractions.first?.measuresArchive == true, "followed as before")
        _ = tracker.step(now: 3, processes: [])
        mac.put(.missing, at: tarWork)
        mac.put(.folder(items: 2), at: "/Users/me/Downloads/data")
        mac.put(.file(size: 100), at: "/Users/me/Downloads/data/a.bin")
        mac.put(.file(size: 300), at: "/Users/me/Downloads/data/b.bin")
        lines = tracker.step(now: 3.2, processes: [])
        #expect(lines.last == "huge.tar.bz2: complete in 2.0 s (an archive of 10.0 KB); at /Users/me/Downloads/data")
        #expect(tracker.ended.last?.ending == .complete)
        // Nobody waits for the list any more.
        #expect(mac.laterDropped == [tarball])
    }

    /// The same with a file missing from what Keka put in place.
    @Test func aListReadBesideTheLoopFindsAFileMissing() {
        let tarball = "/Users/me/Downloads/huge.tar.bz2"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.tooLarge, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 9_000),
                                                         writing(tarWork + "/Operation/data/a.bin", size: 100)])])
        mac.finishLaterIndex([ArchiveEntry(path: "data/a.bin", size: 100), ArchiveEntry(path: "data/b.bin", size: 300)], for: tarball)
        _ = tracker.step(now: 2, processes: [])
        mac.put(.missing, at: tarWork)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/data")
        mac.put(.file(size: 100), at: "/Users/me/Downloads/data/a.bin")
        _ = tracker.step(now: 2.2, processes: [])
        #expect(tracker.ended.last?.ending == .incomplete)
    }

    /// The helper is done and the result in place before the list is read:
    /// the end waits for the list, twenty seconds at most, then says done.
    @Test func theEndWaitsForAListStillBeingReadThenSaysDone() throws {
        let tarball = "/Users/me/Downloads/huge.tar.bz2"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.tooLarge, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 9_900),
                                                         writing(tarWork + "/Operation/data/a.bin", size: 100)])])
        _ = tracker.step(now: 2, processes: [])
        mac.put(.missing, at: tarWork)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/data")
        for tenth in 21...60 {
            mac.clock += 0.1
            #expect(tracker.step(now: Double(tenth) / 10, processes: []).isEmpty, "the list may yet come")
        }
        #expect(tracker.extractions.first?.stalledSince == nil)
        mac.clock += Tracker.listWait
        let lines = tracker.step(now: 26.1, processes: [])
        #expect(lines.last?.hasPrefix("huge.tar.bz2: done after") == true)
        #expect(tracker.ended.last?.ending == .unchecked)
    }

    /// …and the list coming while the end waits for it is looked at.
    @Test func aListThatComesWhileTheEndWaitsForItIsLookedAt() {
        let tarball = "/Users/me/Downloads/huge.tar.bz2"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.tooLarge, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 9_900),
                                                         writing(tarWork + "/Operation/data/a.bin", size: 100)])])
        _ = tracker.step(now: 2, processes: [])
        mac.put(.missing, at: tarWork)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/data")
        mac.put(.file(size: 100), at: "/Users/me/Downloads/data/a.bin")
        #expect(tracker.step(now: 2.2, processes: []).isEmpty)
        mac.clock += 4
        mac.finishLaterIndex([ArchiveEntry(path: "data/a.bin", size: 100)], for: tarball)
        let lines = tracker.step(now: 6.2, processes: [])
        #expect(lines.last?.hasPrefix("huge.tar.bz2: complete in") == true)
        #expect(tracker.ended.last?.ending == .complete)
    }

    /// A cancel isn't kept waiting for a list: nothing is in place.
    @Test func aCancelIsSaidAtOnceThoughTheListIsStillBeingRead() {
        let tarball = "/Users/me/Downloads/huge.tar.bz2"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.tooLarge, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 4_000),
                                                         writing(tarWork + "/Operation/data/a.bin", size: 100)])])
        _ = tracker.step(now: 2, processes: [])
        mac.put(.missing, at: tarWork)
        let lines = tracker.step(now: 2.2, processes: [])
        #expect(lines.last?.hasPrefix("huge.tar.bz2: stopped short at 40 %") == true)
        #expect(mac.laterDropped == [tarball])
    }

    /// A list that can't be read after all leaves things as they were.
    @Test func aListThatCannotBeReadAfterAllLeavesItDone() {
        let tarball = "/Users/me/Downloads/huge.tar.bz2"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.tooLarge, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 9_900),
                                                         writing(tarWork + "/Operation/data/a.bin", size: 100)])])
        mac.failLaterIndex(.notAnArchive, for: tarball)
        let lines = tracker.step(now: 2, processes: [])
        #expect(lines == ["huge.tar.bz2: its list of contents couldn't be read after all (this kind of archive has no index to read)"])
        mac.put(.missing, at: tarWork)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/data")
        _ = tracker.step(now: 2.2, processes: [])
        #expect(tracker.ended.last?.ending == .unchecked)
    }

    /// Without an index and without one file seen being written, the names
    /// its result could have aren't known: nothing found says nothing.
    @Test func withoutAnIndexAndWithoutAFileSeenNothingFoundCannotBeTold() {
        let tarball = "/Users/me/Downloads/huge.tar.gz"
        let tarWork = "/Users/me/Downloads/huge.tar.kextraction"
        mac.setIndexFailure(.tooLarge, for: tarball)
        mac.put(.folder(items: 1), at: tarWork)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [kekaHelper([reading(tarball, size: 10_000, at: 100)])])
        _ = tracker.step(now: 0.1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 200)])])
        _ = tracker.step(now: 1, processes: [kekaHelper([reading(tarball, size: 10_000, at: 9_000)])])
        mac.put(.missing, at: tarWork)
        var lines: [String] = []
        for second in 2...40 {
            lines += tracker.step(now: Double(second), processes: [])
        }
        #expect(lines.contains { $0.contains("stopped short") || $0.contains("done after") } == false)
        #expect(tracker.ended.allSatisfy { $0.ending == .unknown })
    }

    /// What Keka's helpers write elsewhere than in a work folder is no
    /// part of an extraction.
    @Test func whatAHelperWritesElsewhereDoesNotCount() {
        mac.setIndex(entries, for: archive)
        var tracker = mac.tracker()
        let lines = tracker.step(now: 0, processes: [kekaHelper([reading(archive), writing("/Users/me/Downloads/photos/a.jpg", size: 400)])])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.isEmpty)
    }

    @Test(arguments: [
        ([ArchiveEntry(path: "photos", size: 0, isFolder: true), ArchiveEntry(path: "photos/a.jpg", size: 1)], "photos", "photos 2", "photos 3"),
        ([ArchiveEntry(path: "movie.mkv", size: 1)], "movie.mkv", "movie 2.mkv", "movie 3.mkv"),
        ([ArchiveEntry(path: "a.txt", size: 1), ArchiveEntry(path: "b.txt", size: 1)], "trip", "trip 2", "trip 3"),
        ([ArchiveEntry(path: "README", size: 1)], "README", "README 2", "README 3"),
    ])
    func theNamesItsResultMayHave(entries: [ArchiveEntry], first: String, second: String, third: String) {
        let names = Tracker.namesBeside(of: .keka, archivePath: "/x/trip.tar.gz",
                                        index: ArchiveIndex(format: .zip, entries: entries, parts: []), in: "/x").names
        #expect(Array(names.prefix(3)) == ["/x/" + first, "/x/" + second, "/x/" + third])
    }

    /// Seen: `many small.kextraction`, `tarball.tar.kextraction`,
    /// `pair.kextraction` for `pair.tar`.
    @Test(arguments: [
        ("/Users/me/Downloads/many small.zip", "/Users/me/Downloads/many small.kextraction"),
        ("/Users/me/Downloads/tarball.tar.gz", "/Users/me/Downloads/tarball.tar.kextraction"),
        ("/Users/me/Downloads/pair.tar", "/Users/me/Downloads/pair.kextraction"),
        ("/five.rar", "/five.kextraction"),
    ])
    func theFolderKekaMakesForAnArchive(archive: String, folder: String) {
        #expect(Tool.kekaWorkFolder(for: archive) == folder)
    }

    @Test(arguments: [
        ("/Users/me/Downloads/photos.kextraction/Operation/photos/a.jpg", "/Users/me/Downloads/photos.kextraction"),
        ("/Users/me/Downloads/tarball.tar.kextraction/Operation/a.jpg", "/Users/me/Downloads/tarball.tar.kextraction"),
        ("/Users/me/Downloads/photos/a.jpg", nil),
        ("/Users/me/Downloads/.kextraction/a.jpg", nil),
    ] as [(String, String?)])
    func kekasFolderForAnArchiveIsReadFromAFileItWritesThere(path: String, folder: String?) {
        #expect(Tool.keka.workFolder(of: path) == folder)
    }
}
