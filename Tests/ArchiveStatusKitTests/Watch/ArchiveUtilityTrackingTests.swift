// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// What Archive Utility was seen to do on a real Mac (7 and 11 Oct),
/// replayed look by look. Its helper works in a temporary folder; beside
/// the archive stands an empty placeholder (a file for a one-file result, a
/// folder otherwise), which is filled at the end, or taken away on a cancel.
struct ArchiveUtilityTrackingTests {
    let mac = FakeMac()
    let folder = "/Users/me/Downloads"

    @Test func oneFileIsFollowedThroughItsPlaceholder() throws {
        let archive = folder + "/one big file.zip"
        let result = folder + "/one big file.bin"
        mac.setIndex([ArchiveEntry(path: "one big file.bin", size: 1_258_291_200)], for: archive)
        var tracker = mac.tracker()

        // The placeholder is there before the helper writes anything.
        mac.put(.file(size: 0), at: result)
        #expect(tracker.step(now: 0, processes: [helper([reading(archive)])]).isEmpty)
        var lines = tracker.step(now: 0.1, processes: [
            helper([reading(archive), writing(helperFolder + "/one big file.bin", size: 117_432_254)]),
        ])
        #expect(lines == [
            "one big file.zip: Archive Utility is extracting it: 1.26 GB in 1 file (zip), into \(helperFolder)",
            "one big file.zip: 9 % · 117.4 MB of 1.26 GB",
        ])
        #expect(tracker.extractions.first?.result == result, "known from the start: what Show in Finder shows")

        // The helper lets go of the archive a moment before the file is in place.
        #expect(tracker.step(now: 1.2, processes: [helper([])]).isEmpty)
        #expect(tracker.extractions.count == 1, "not ended while the placeholder is still empty")
        mac.put(.file(size: 1_258_291_200), at: result)
        lines = tracker.step(now: 1.3, processes: [helper([])])
        // (From the first file seen written, at 0.1, to the helper letting go, at 1.2.)
        #expect(lines == ["one big file.zip: complete: 1.26 GB in 1.1 s; at \(result)"])
        #expect(tracker.ended.last?.ending == .complete)
        #expect(tracker.attention == .none)
    }

    @Test func aTakenNameGivesTheNextOne() throws {
        let archive = folder + "/one big file.zip"
        mac.setIndex([ArchiveEntry(path: "one big file.bin", size: 5_000)], for: archive)
        // Two earlier extractions are still there.
        mac.put(.file(size: 5_000), at: folder + "/one big file.bin")
        mac.put(.file(size: 5_000), at: folder + "/one big file 2.bin")
        mac.put(.file(size: 0), at: folder + "/one big file 3.bin")
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/one big file.bin", size: 100)])])
        #expect(tracker.extractions.first?.result == folder + "/one big file 3.bin")
    }

    @Test func aCancelTakesThePlaceholderAway() throws {
        let archive = folder + "/one big file.zip"
        let result = folder + "/one big file.bin"
        mac.setIndex([ArchiveEntry(path: "one big file.bin", size: 3_520_833_340)], for: archive)
        mac.put(.file(size: 0), at: result)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/one big file.bin", size: 100_000_000)])])
        _ = tracker.step(now: 13, processes: [helper([reading(archive), writing(helperFolder + "/one big file.bin", size: 3_500_000_000)])])
        // Cancelled at 99 %: the helper lets go, the placeholder is gone,
        // and nothing is left behind.
        mac.put(.missing, at: result)
        // (Not said at the first look without it: it must stay gone a moment.)
        #expect(tracker.step(now: 13.1, processes: [helper([])]).isEmpty)
        #expect(tracker.step(now: 13.2, processes: [helper([])]).isEmpty)
        let lines = tracker.step(now: 13.4, processes: [helper([])])
        #expect(lines == ["one big file.zip: stopped short at 99 % (3.50 GB of 3.52 GB) after 13.1 s; at \(result)"])
        #expect(tracker.ended.last?.ending == .stopped)
    }

    /// Seen on the real Mac (11 Oct): the helper was first looked at half a
    /// second after the placeholder folder had appeared. Taking it for an
    /// older folder made the plugin wait for a result under the next name,
    /// which never came.
    @Test func aFolderResultIsKnownByItsEmptyPlaceholderFolder() throws {
        let archive = folder + "/several tops.zip"
        mac.setIndex([
            ArchiveEntry(path: "first top/file 000.bin", size: 1_000_000),
            ArchiveEntry(path: "second top.bin", size: 250_000_000),
            ArchiveEntry(path: "third top.txt", size: 14),
        ], for: archive)
        // Three earlier extractions, and this one's placeholder.
        mac.put(.folder(items: 3), at: folder + "/several tops")
        mac.put(.folder(items: 3), at: folder + "/several tops 2")
        mac.put(.folder(items: 3), at: folder + "/several tops 3")
        mac.put(.folder(items: 0), at: folder + "/several tops 4")
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/second top.bin", size: 162_000_000)])])
        #expect(tracker.extractions.first?.result == folder + "/several tops 4")

        // The helper is done; the folder is still empty for an instant.
        #expect(tracker.step(now: 0.3, processes: [helper([])]).isEmpty)
        mac.put(.folder(items: 3), at: folder + "/several tops 4")
        #expect(tracker.step(now: 0.4, processes: []) == [
            "several tops.zip: complete: 251.0 MB in 0.3 s; at \(folder)/several tops 4",
        ])
    }

    @Test func aFolderResultIsAlsoKnownBeforeItsPlaceholderAppears() throws {
        let archive = folder + "/many files.zip"
        mac.setIndex([
            ArchiveEntry(path: "many files", size: 0, isFolder: true),
            ArchiveEntry(path: "many files/a.bin", size: 400),
            ArchiveEntry(path: "many files/b.bin", size: 600),
        ], for: archive)
        mac.put(.folder(items: 2), at: folder + "/many files")
        var tracker = mac.tracker()
        // First look: the archive is open, nothing is written, no placeholder yet.
        #expect(tracker.step(now: 0, processes: [helper([reading(archive)])]).isEmpty)
        mac.put(.folder(items: 0), at: folder + "/many files 2")
        _ = tracker.step(now: 1, processes: [helper([reading(archive), writing(helperFolder + "/many files/a.bin", size: 200)])])
        #expect(tracker.extractions.first?.result == folder + "/many files 2")
        mac.put(.folder(items: 2), at: folder + "/many files 2")
        #expect(tracker.step(now: 2, processes: [helper([])]) == [
            "many files.zip: complete: 1.0 KB in 1.0 s; at \(folder)/many files 2",
        ])
    }

    /// A cancel of 11 Oct, a folder result: the helper lets go
    /// and is gone, and the empty folder beside the archive is taken away.
    @Test func aFolderResultThatIsTakenAwayWasStopped() {
        let archive = folder + "/many files.zip"
        mac.setIndex([ArchiveEntry(path: "many files/a.bin", size: 400), ArchiveEntry(path: "many files/b.bin", size: 600)], for: archive)
        mac.put(.folder(items: 0), at: folder + "/many files")
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/many files/a.bin", size: 200)])])
        mac.put(.missing, at: folder + "/many files")
        #expect(tracker.step(now: 1, processes: [helper([])]).isEmpty)
        #expect(tracker.step(now: 1.3, processes: []) == [
            "many files.zip: stopped short at 20 % (200 bytes of 1.0 KB) after 1.0 s; at \(folder)/many files",
        ])
    }

    @Test func theInstantInWhichTheResultTakesThePlaceholdersPlaceIsNotAStop() {
        // Should Archive Utility take its placeholder away and put the
        // result there a moment later, the look in between must not be read
        // as a cancel.
        let archive = folder + "/one big file.zip"
        let result = folder + "/one big file.bin"
        mac.setIndex([ArchiveEntry(path: "one big file.bin", size: 5_000)], for: archive)
        mac.put(.file(size: 0), at: result)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/one big file.bin", size: 4_000)])])
        mac.put(.missing, at: result)
        #expect(tracker.step(now: 1, processes: [helper([])]).isEmpty)
        mac.put(.file(size: 5_000), at: result)
        #expect(tracker.step(now: 1.1, processes: [helper([])]) == [
            "one big file.zip: complete: 5.0 KB in 1.0 s; at \(result)",
        ])
    }

    /// A cancel of 11 Oct, one file, clicked late: the helper
    /// stops writing, has the archive open for one more look, lets go and
    /// is gone; the placeholder is taken away.
    @Test func aLateCancelOfOneFileIsStoppedHoweverCloseToTheEnd() {
        let archive = folder + "/1 one big file.zip"
        let result = folder + "/one big file.bin"
        mac.setIndex([ArchiveEntry(path: "one big file.bin", size: 8_388_608_000)], for: archive)
        mac.put(.file(size: 0), at: result)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/one big file.bin", size: 290_700_000)])])
        _ = tracker.step(now: 6.0, processes: [helper([reading(archive), writing(helperFolder + "/one big file.bin", size: 8_303_912_894)])])
        #expect(tracker.step(now: 6.1, processes: [helper([reading(archive)])]).isEmpty)
        mac.put(.missing, at: result)
        #expect(tracker.step(now: 6.2, processes: [helper([])]).isEmpty)
        #expect(tracker.step(now: 6.3, processes: []).isEmpty)
        #expect(tracker.step(now: 6.6, processes: []) == [
            "1 one big file.zip: stopped short at 98 % (8.30 GB of 8.39 GB) after 6.2 s; at \(result)",
        ])
    }

    @Test func aPlaceholderThatStaysEmptyIsGivenFiveSecondsThenLeftUndecided() {
        let archive = folder + "/many files.zip"
        mac.setIndex([ArchiveEntry(path: "many files/a.bin", size: 400)], for: archive)
        mac.put(.folder(items: 0), at: folder + "/many files")
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/many files/a.bin", size: 200)])])
        for tenth in 10..<60 {
            #expect(tracker.step(now: Double(tenth) / 10, processes: [helper([])]).isEmpty)
            #expect(tracker.attention == .close, "it keeps looking while the ending isn't known")
        }
        #expect(tracker.step(now: 6.0, processes: [helper([])]) == [
            "many files.zip: ended after 1.0 s, and whether it got to its end can't be told "
                + "(200 bytes seen written of 400 bytes); at \(folder)/many files",
        ])
        #expect(tracker.ended.last?.ending == .unknown)
    }

    @Test func aResultThatNeverShowsBesideTheArchiveIsLeftUndecided() {
        // Archive Utility can be set to put what it extracts somewhere
        // else: then nothing ever shows beside the archive. That isn't
        // taken for a cancel.
        let archive = folder + "/photos.zip"
        mac.setIndex([ArchiveEntry(path: "photos/a.jpg", size: 400)], for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/photos/a.jpg", size: 390)])])
        #expect(tracker.step(now: 1, processes: []).isEmpty)
        let lines = tracker.step(now: 6.5, processes: [])
        #expect(lines == [
            "photos.zip: ended after 1.0 s, and whether it got to its end can't be told "
                + "(390 bytes seen written of 400 bytes); at \(folder)/photos (Archive Utility's placeholder was never seen there)",
        ])
    }

    @Test func compressingIsNotExtracting() {
        // The helper also makes archives. It then reads what it compresses,
        // which may be an archive, and writes the new one in its folder.
        let inside = folder + "/project/backup.tar.gz"
        mac.setIndexFailure(.notAnArchive, for: inside)
        var tracker = mac.tracker()
        for tenth in 0..<20 {
            let lines = tracker.step(now: Double(tenth) / 10, processes: [
                helper([reading(inside), writing(helperFolder + "/Archive.zip", size: UInt64(tenth) * 1_000)]),
            ])
            #expect(lines.isEmpty)
        }
        #expect(tracker.extractions.isEmpty)
        #expect(tracker.step(now: 3, processes: [helper([])]).isEmpty)
    }

    @Test func anArchiveWithoutAnIndexIsFollowedWithoutATotal() {
        let archive = folder + "/sources.tar.gz"
        mac.setIndexFailure(.notAnArchive, for: archive)
        var tracker = mac.tracker()
        var lines = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/sources/main.c", size: 700)])])
        #expect(lines == [
            "sources.tar.gz: Archive Utility is extracting it; total unknown (this kind of archive has no index to read)",
            "sources.tar.gz: 700 bytes written",
        ])
        // What the helper writes outside its own folder isn't counted.
        lines = tracker.step(now: 1, processes: [helper([reading(archive), writing("/Users/me/Library/Logs/helper.log", size: 99_999)])])
        #expect(lines.isEmpty)
        #expect(tracker.extractions.first?.written == 700)
        lines = tracker.step(now: 2, processes: [helper([])])
        // (Where the result goes isn't known either without an index.)
        #expect(lines == [
            "sources.tar.gz: ended after 2.0 s, and whether it got to its end can't be told (700 bytes seen written)",
        ])
    }

    @Test func theSameArchiveOpenedAgainSettlesTheOneBefore() {
        let archive = folder + "/many files.zip"
        mac.setIndex([ArchiveEntry(path: "many files/a.bin", size: 400)], for: archive)
        mac.put(.folder(items: 0), at: folder + "/many files")
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/many files/a.bin", size: 200)])])
        #expect(tracker.step(now: 1, processes: [helper([])]).isEmpty)
        // Opened again while the first one's ending is still being waited for.
        let lines = tracker.step(now: 2, processes: [helper([reading(archive), writing(helperFolder + "/many files/a.bin", size: 100)])])
        #expect(lines.count == 3)
        #expect(lines.first?.contains("whether it got to its end can't be told") == true)
        #expect(lines.dropFirst().first?.contains("Archive Utility is extracting it") == true)
        #expect(tracker.extractions.count == 1)
        #expect(tracker.ended.count == 1)
    }

    @Test func whatMacOSAddsBesideEachFileIsNotWaitedFor() throws {
        // A zip made on a Mac: the index reader has left the `__MACOSX`
        // companions out, so the total is what really gets written.
        let archive = folder + "/mac made.zip"
        mac.setIndex((0..<300).map { ArchiveEntry(path: "mac made/photo \($0).bin", size: 2_097_152) }, for: archive)
        mac.put(.folder(items: 0), at: folder + "/mac made")
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(helperFolder + "/mac made/photo 299.bin", size: 2_097_152)])])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == extraction.total)
        #expect(extraction.total == 629_145_600)
    }

    @Test(arguments: [
        // one file: its number goes before the extension
        (["report.pdf"], "/d/x.zip", ["/d/report.pdf", "/d/report 2.pdf", "/d/report 3.pdf"], true),
        (["README"], "/d/x.zip", ["/d/README", "/d/README 2", "/d/README 3"], true),
        ([".hidden"], "/d/x.zip", ["/d/.hidden", "/d/.hidden 2", "/d/.hidden 3"], true),
        // one folder: the folder itself, the number at the end
        (["album/one.jpg", "album/two.jpg"], "/d/x.zip", ["/d/album", "/d/album 2", "/d/album 3"], false),
        (["v1.2/readme.txt"], "/d/x.zip", ["/d/v1.2", "/d/v1.2 2", "/d/v1.2 3"], false),
        // several items at the top: a folder named after the archive
        (["a.txt", "b.txt"], "/d/my files.zip", ["/d/my files", "/d/my files 2", "/d/my files 3"], false),
        (["a.txt", "dir/b.txt"], "/d/sources.tar.gz", ["/d/sources", "/d/sources 2", "/d/sources 3"], false),
        // nothing at all: a folder named after the archive
        ([], "/d/empty.zip", ["/d/empty", "/d/empty 2", "/d/empty 3"], false),
    ] as [([String], String, [String], Bool)])
    func theResultIsNamedAsArchiveUtilityNamesIt(paths: [String], archive: String, names: [String], isFile: Bool) {
        let index = ArchiveIndex(format: .zip, entries: paths.map { ArchiveEntry(path: $0, size: 1) }, parts: [archive])
        let expected = Tracker.resultNames(archivePath: archive, index: index)
        #expect(Array(expected.names.prefix(3)) == names)
        #expect(expected.isFile == isFile)
    }

    @Test func aLoneFolderEntryIsAFolderResult() {
        let index = ArchiveIndex(format: .zip, entries: [ArchiveEntry(path: "empty folder", size: 0, isFolder: true)], parts: ["/d/x.zip"])
        #expect(Tracker.resultNames(archivePath: "/d/x.zip", index: index).isFile == false)
    }
}

/// An archive without an index (a `tar.gz`), as Archive Utility was seen to
/// extract it on 12 Oct: an empty folder named after the item appears
/// beside the archive as the extraction begins, and is filled at the end.
struct ArchiveUtilityWithoutIndexTests {
    let mac = FakeMac()
    let archive = "/Users/me/Downloads/sources.tar.gz"

    init() {
        mac.setIndexFailure(.notAnArchive, for: archive)
    }

    private func extracting(_ path: String, size: UInt64 = 500) -> [ToolProcess] {
        [helper([reading(archive), writing(helperFolder + "/" + path, size: size)])]
    }

    @Test func itsEndIsToldByThePlaceholderNamedAfterWhatIsBeingWritten() throws {
        var tracker = mac.tracker()
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/project")
        _ = tracker.step(now: 0, processes: extracting("project/src/main.c"))
        #expect(try #require(tracker.extractions.first).result == "/Users/me/Downloads/project")
        mac.put(.folder(items: 4), at: "/Users/me/Downloads/project")
        let lines = tracker.step(now: 30, processes: [helper([])])
        #expect(lines == ["sources.tar.gz: complete: 500 bytes in 30.0 s; at /Users/me/Downloads/project"])
        #expect(tracker.ended.last?.ending == .complete)
    }

    @Test func aCancelTakesThatPlaceholderAwayToo() throws {
        var tracker = mac.tracker()
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/project")
        _ = tracker.step(now: 0, processes: extracting("project/src/main.c"))
        mac.put(.missing, at: "/Users/me/Downloads/project")
        #expect(tracker.step(now: 10, processes: [helper([])]).isEmpty)
        let lines = tracker.step(now: 10.4, processes: [])
        #expect(lines == ["sources.tar.gz: stopped short with 500 bytes written after 10.0 s; at /Users/me/Downloads/project"])
    }

    @Test func aTakenNameGivesTheNumberedOneForAFolderAndForAFile() throws {
        // An earlier copy of the folder is there: the placeholder is "project 2".
        var tracker = mac.tracker()
        mac.put(.folder(items: 9), at: "/Users/me/Downloads/project", changedAt: mac.clock - 3_600)
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/project 2")
        _ = tracker.step(now: 0, processes: extracting("project/src/main.c"))
        #expect(try #require(tracker.extractions.first).result == "/Users/me/Downloads/project 2")

        // One file at the top: its number goes before the extension.
        let other = FakeMac()
        let single = "/Users/me/Downloads/notes.txt.gz"
        other.setIndexFailure(.notAnArchive, for: single)
        other.put(.file(size: 80), at: "/Users/me/Downloads/notes.txt", changedAt: other.clock - 3_600)
        other.put(.file(size: 0), at: "/Users/me/Downloads/notes 2.txt")
        var second = other.tracker()
        _ = second.step(now: 0, processes: [helper([reading(single), writing(helperFolder + "/notes.txt", size: 40)])])
        #expect(try #require(second.extractions.first).result == "/Users/me/Downloads/notes 2.txt")
    }

    @Test func anOlderEmptyFolderOfThatNameIsNotTakenForThePlaceholder() throws {
        var tracker = mac.tracker()
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/project", changedAt: mac.clock - 3_600)
        _ = tracker.step(now: 0, processes: extracting("project/src/main.c"))
        #expect(try #require(tracker.extractions.first).result == nil)
        // Without a placeholder, the end can't be told.
        let lines = tracker.step(now: 20, processes: [helper([])])
        #expect(lines.first?.contains("whether it got to its end can't be told") == true)
    }

    @Test func severalItemsAtTheTopGoIntoAFolderNamedAfterTheArchive() throws {
        var tracker = mac.tracker()
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/sources")
        _ = tracker.step(now: 0, processes: extracting("README"))
        #expect(try #require(tracker.extractions.first).result == "/Users/me/Downloads/sources")
    }

    @Test func thePlaceholderIsOnlyLookedForAsTheExtractionBegins() throws {
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: extracting("project/a.c"))
        // It shows up late (it never does in fact): no longer looked for.
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/project")
        let asked = mac.changeTimeAsked
        for second in 4...20 {
            _ = tracker.step(now: Double(second), processes: extracting("project/a.c", size: UInt64(second) * 100))
        }
        #expect(mac.changeTimeAsked == asked)
        #expect(try #require(tracker.extractions.first).result == nil)
    }
}

/// An archive without an index is followed by how far the unarchiver has
/// read into it (decided on 12 Oct). Seen on the real Mac that day:
/// Archive Utility's helper has the archive open twice, and one of the two
/// moves through it as the extraction goes; for a `tar.gz` it reads the
/// archive through once before it extracts.
struct ReadingPositionTests {
    let mac = FakeMac()
    let archive = "/Users/me/Downloads/sources.tar.gz"
    let size: UInt64 = 11_344_275

    init() {
        mac.setIndexFailure(.notAnArchive, for: archive)
    }

    /// The helper with the archive open twice, one of them `position` in.
    private func look(at position: UInt64, writing file: String? = "project/a.c") -> [ToolProcess] {
        var files = [reading(archive, size: size, at: 0), reading(archive, size: size, at: position)]
        if let file {
            files.append(writing(helperFolder + "/" + file, size: 300))
        }
        return [helper(files)]
    }

    @Test func theArchivesOwnSizeIsTheTotalAndTheReadingThePlace() throws {
        var tracker = mac.tracker()
        // First it reads the archive through without writing anything: no extraction yet.
        #expect(tracker.step(now: 0, processes: look(at: 4_567_040, writing: nil)).isEmpty)
        #expect(tracker.step(now: 1, processes: look(at: 8_601_600, writing: nil)).isEmpty)
        #expect(tracker.extractions.isEmpty)
        // Then it starts over, and writes.
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/project")
        var lines = tracker.step(now: 2, processes: look(at: 143_360))
        #expect(lines == [
            "sources.tar.gz: Archive Utility is extracting it; no total to read (this kind of archive has no index to read), "
                + "so it is followed by how far the archive has been read, of its 11.3 MB",
            "sources.tar.gz: 1 % · 143.4 KB of 11.3 MB of the archive read",
        ])
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.measuresArchive)
        #expect(extraction.total == size)
        #expect(extraction.written == 143_360)

        lines = tracker.step(now: 12, processes: look(at: 3_840_000, writing: nil))
        #expect(lines == ["sources.tar.gz: 33 % · 3.8 MB of 11.3 MB of the archive read · 369.7 KB/s · 21 s left"])
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 3_840_000, "from the reading, not from the few files caught being written")

        mac.put(.folder(items: 3), at: "/Users/me/Downloads/project")
        lines = tracker.step(now: 30, processes: [helper([])])
        #expect(lines == ["sources.tar.gz: complete in 28.0 s (an archive of 11.3 MB); at /Users/me/Downloads/project"])
        #expect(tracker.ended.last?.written == size)
    }

    @Test func oneHundredPercentIsOnlySaidAtTheEnd() throws {
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: look(at: 1_000_000))
        // A tool reads ahead of what it writes: the whole archive is read
        // while files are still being written.
        _ = tracker.step(now: 5, processes: look(at: size))
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == size - 1)
        #expect(Amount.percent(extraction.written, of: size) == "99 %")
    }

    @Test func theReadingNeverTakesProgressBack() throws {
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: look(at: 5_000_000))
        _ = tracker.step(now: 1, processes: look(at: 2_000_000))
        #expect(try #require(tracker.extractions.first).written == 5_000_000)
    }

    @Test func whereTheReadingIsNotToldTheFilesCaughtAreAddedUpAsBefore() throws {
        var tracker = mac.tracker()
        let lines = tracker.step(now: 0, processes: look(at: 0))
        #expect(lines.first == "sources.tar.gz: Archive Utility is extracting it; total unknown (this kind of archive has no index to read)")
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.measuresArchive == false)
        #expect(extraction.total == nil)
        #expect(extraction.written == 300)
    }

    @Test func aReadingThatIsToldLaterIsTakenUpThen() throws {
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: look(at: 0))
        let lines = tracker.step(now: 2, processes: look(at: 2_000_000))
        #expect(lines.contains("sources.tar.gz: followed from now by how far the archive has been read, of its 11.3 MB"))
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.measuresArchive)
        #expect(extraction.written == 2_000_000)
    }

    @Test func anArchiveWithAnIndexIsFollowedByItsIndexWhateverTheReading() throws {
        let zip = "/Users/me/Downloads/photos.zip"
        mac.setIndex([ArchiveEntry(path: "big.bin", size: 2_000_000_000)], for: zip)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([reading(zip, size: 900_000_000, at: 600_000_000),
                                                     writing(helperFolder + "/big.bin", size: 400_000_000)])])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.measuresArchive == false)
        #expect(extraction.total == 2_000_000_000)
        #expect(extraction.written == 400_000_000)
    }

    @Test func anArchiveInSeveralPartsWithoutAnIndexIsNotFollowedThisWay() throws {
        // (A RAR whose index is encrypted: each part is read in its turn.)
        let parts = ["/Users/me/Downloads/sealed.part1.rar", "/Users/me/Downloads/sealed.part2.rar"]
        mac.setIndexFailure(.locked, for: parts[0])
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(parts[0], size: 5_000, at: 5_000), reading(parts[1], size: 5_000, at: 100),
                                                        writing("/Users/me/Desktop/out/a.bin", size: 70)])])
        let extraction = try #require(tracker.extractions.first)
        #expect(extraction.measuresArchive == false)
        #expect(extraction.total == nil)
    }

    @Test func aStopIsToldWithHowFarTheArchiveWasRead() throws {
        var tracker = mac.tracker()
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/project")
        _ = tracker.step(now: 0, processes: look(at: 1_000_000))
        _ = tracker.step(now: 4, processes: look(at: 3_857_000))
        mac.put(.missing, at: "/Users/me/Downloads/project")
        _ = tracker.step(now: 5, processes: [helper([])])
        let lines = tracker.step(now: 5.4, processes: [])
        #expect(lines == ["sources.tar.gz: stopped short at 33 % (3.9 MB of 11.3 MB of the archive read) after 5.0 s; "
            + "at /Users/me/Downloads/project"])
    }
}
