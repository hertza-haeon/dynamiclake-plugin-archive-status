// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// The second way of telling how far an extraction is: which of the
/// archive's files are there, written by this extraction.
///
/// Seen on a real Mac (11 Oct): MacPacker extracting 150,000 small
/// files was caught writing one only eleven times in twenty seconds, and
/// the card's time left was wrong for want of readings.
struct ProbeTrackingTests {
    let mac = FakeMac()
    let archive = "/Users/me/Downloads/small files.zip"
    let root = "/Users/me/Desktop"

    /// An archive of `count` files of 100 bytes in a folder.
    private func index(_ count: Int) -> [ArchiveEntry] {
        [ArchiveEntry(path: "small", size: 0, isFolder: true)]
            + (0..<count).map { ArchiveEntry(path: "small/file \($0).bin", size: 100) }
    }

    private func path(_ number: Int) -> String {
        "\(root)/small/file \(number).bin"
    }

    /// The tool has written the files up to `number`, the last one `partly`.
    private func written(through number: Int, partly: UInt64 = 100, from first: Int = 0) {
        guard number >= first else { return }
        for file in first..<number {
            mac.put(.file(size: 100), at: path(file))
        }
        mac.put(.file(size: partly), at: path(number))
    }

    @Test func theFilesOnTheDiskTellHowFarWhenNoneIsCaughtBeingWritten() throws {
        mac.setIndex(index(1_000), for: archive)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        // One file is caught, the eleventh, 60 bytes in.
        written(through: 10, partly: 60)
        _ = tracker.step(now: 1, processes: [macPacker([reading(archive), writing(path(10), size: 60)])])
        #expect(try #require(tracker.extractions.first).written == 1_060)

        // From here no look catches anything, as with MacPacker's small files.
        written(through: 500, partly: 30, from: 10)
        _ = tracker.step(now: 2, processes: [macPacker([reading(archive)])])
        var extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 50_030)
        #expect(extraction.fileNumber == 501)

        written(through: 999, from: 500)
        _ = tracker.step(now: 3, processes: [macPacker([reading(archive)])])
        extraction = try #require(tracker.extractions.first)
        #expect(extraction.written == 100_000)
        #expect(extraction.fileNumber == 1_000)

        #expect(tracker.step(now: 3.5, processes: [macPacker([])]).first?.hasPrefix("small files.zip: complete: 100.0 KB") == true)
    }

    @Test func theLogThenHasAReadingEverySecond() {
        mac.setIndex(index(1_000), for: archive)
        var tracker = mac.tracker()
        written(through: 0, partly: 50)
        var lines = tracker.step(now: 0, processes: [macPacker([reading(archive), writing(path(0), size: 50)])])
        var readings = lines.count { $0.contains(" of ") }
        // A hundred files a second, none of them ever caught.
        for tenth in 1...60 {
            written(through: tenth * 10, from: max(0, tenth * 10 - 10))
            lines = tracker.step(now: Double(tenth) / 10, processes: [macPacker([reading(archive)])])
            readings += lines.count { $0.contains(" of ") }
        }
        #expect(readings == 7, "one at the start, then one a second for six seconds")
    }

    /// The third run of 11 Oct: extracted again into the folder
    /// where the first copy still was.
    @Test func anEarlierCopyAtTheSamePlaceDoesNotCount() throws {
        mac.setIndex(index(1_000), for: archive)
        // The earlier copy: every file there, whole, from ten minutes ago.
        for file in 0..<1_000 {
            mac.put(.file(size: 100), at: path(file), changedAt: mac.clock - 600)
        }
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive)])])
        written(through: 10, partly: 60)
        _ = tracker.step(now: 1, processes: [macPacker([reading(archive), writing(path(10), size: 60)])])
        #expect(try #require(tracker.extractions.first).written == 1_060, "not the 100,000 bytes of the earlier copy")
        written(through: 300, from: 10)
        _ = tracker.step(now: 2, processes: [macPacker([reading(archive)])])
        #expect(try #require(tracker.extractions.first).fileNumber == 301)
    }

    /// Stopped short over an earlier copy: the last file of the archive is
    /// there, whole, from before. That must not be taken for the end.
    @Test func stoppedShortOverAnEarlierCopyIsNotReportedComplete() throws {
        mac.setIndex(index(1_000), for: archive)
        for file in 0..<1_000 {
            mac.put(.file(size: 100), at: path(file), changedAt: mac.clock - 600)
        }
        var tracker = mac.tracker()
        written(through: 10, partly: 60)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing(path(10), size: 60)])])
        written(through: 300, from: 10)
        _ = tracker.step(now: 1, processes: [macPacker([reading(archive)])])
        let lines = tracker.step(now: 1.5, processes: [macPacker([])])
        #expect(lines == ["small files.zip: stopped short at 30 % (30.1 KB of 100.0 KB) after 1.5 s; at /Users/me/Desktop/small"])
        #expect(tracker.ended.last?.ending == .stopped)
    }

    @Test func extractedAgainToItsEndOverAnEarlierCopyIsComplete() throws {
        mac.setIndex(index(1_000), for: archive)
        for file in 0..<1_000 {
            mac.put(.file(size: 100), at: path(file), changedAt: mac.clock - 600)
        }
        var tracker = mac.tracker()
        written(through: 10, partly: 60)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing(path(10), size: 60)])])
        written(through: 999, from: 10)
        // (The look that finds the archive let go of also reads the last
        // progress from the disk: a last reading, then the end.)
        let lines = tracker.step(now: 1.5, processes: [macPacker([])])
        #expect(lines.last == "small files.zip: complete: 100.0 KB in 1.5 s; at /Users/me/Desktop/small")
        #expect(tracker.ended.last?.ending == .complete)
    }

    @Test func aFileTheToolLeftOutDoesNotHoldEverythingUp() throws {
        mac.setIndex(index(1_000), for: archive)
        var tracker = mac.tracker()
        written(through: 5, partly: 60)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing(path(5), size: 60)])])
        // Files 20 and 21 never appear (names the tool couldn't write, say).
        written(through: 400, from: 5)
        mac.put(.missing, at: path(20))
        mac.put(.missing, at: path(21))
        _ = tracker.step(now: 1, processes: [macPacker([reading(archive)])])
        #expect(try #require(tracker.extractions.first).fileNumber == 401)
    }

    @Test func aLongerGapIsCrossedOnceAFileBeyondItIsCaught() throws {
        mac.setIndex(index(1_000), for: archive)
        var tracker = mac.tracker()
        written(through: 5, partly: 60)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing(path(5), size: 60)])])
        written(through: 400, from: 5)
        for file in 20..<30 {
            mac.put(.missing, at: path(file))           // ten in a row left out
        }
        _ = tracker.step(now: 1, processes: [macPacker([reading(archive)])])
        #expect(try #require(tracker.extractions.first).fileNumber == 20, "held up at the gap")
        _ = tracker.step(now: 2, processes: [macPacker([reading(archive), writing(path(400), size: 100)])])
        #expect(try #require(tracker.extractions.first).fileNumber == 401)
        written(through: 700, from: 400)
        _ = tracker.step(now: 3, processes: [macPacker([reading(archive)])])
        #expect(try #require(tracker.extractions.first).fileNumber == 701)
    }

    /// On a disk that doesn't keep the date this way goes by, a file caught
    /// being written doesn't say so itself: the plugin goes by what it
    /// catches, as before, and by the last file being whole at the end.
    @Test func whereFilesDoNotTellWhenTheyWereWrittenTheFirstWayStandsAlone() throws {
        mac.setIndex(index(1_000), for: archive)
        var tracker = mac.tracker()
        func old(through number: Int) {
            for file in 0...number {
                mac.put(.file(size: 100), at: path(file), changedAt: 0)
            }
        }
        old(through: 10)
        let lines = tracker.step(now: 0, processes: [macPacker([reading(archive), writing(path(10), size: 60)])])
        // Said once in the log.
        #expect(lines.contains("small files.zip: the file being written doesn't tell when it was written: "
            + "its progress is read from the files caught being written only"))
        old(through: 500)
        _ = tracker.step(now: 1, processes: [macPacker([reading(archive)])])
        #expect(try #require(tracker.extractions.first).fileNumber == 11, "nothing caught, nothing known")
        _ = tracker.step(now: 2, processes: [macPacker([reading(archive), writing(path(600), size: 10)])])
        #expect(try #require(tracker.extractions.first).fileNumber == 601)
        old(through: 999)
        #expect(tracker.step(now: 3, processes: [macPacker([])]).first?.hasPrefix("small files.zip: complete") == true)
    }

    @Test func withArchiveUtilityTheFilesAreAskedForInItsTemporaryFolder() throws {
        let archive = "/Users/me/Downloads/small.zip"
        mac.setIndex(index(1_000), for: archive)
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/small")
        var tracker = mac.tracker()
        func inHelper(_ number: Int) -> String { "\(helperFolder)/small/file \(number).bin" }
        for file in 0...10 {
            mac.put(.file(size: 100), at: inHelper(file))
        }
        _ = tracker.step(now: 0, processes: [helper([reading(archive), writing(inHelper(10), size: 100)])])
        for file in 10...800 {
            mac.put(.file(size: 100), at: inHelper(file))
        }
        _ = tracker.step(now: 1, processes: [helper([reading(archive)])])
        #expect(try #require(tracker.extractions.first).fileNumber == 801)
        // At the end the files leave the temporary folder for their final
        // place: what was known stays, and the placeholder tells the end.
        for file in 0...800 {
            mac.put(.missing, at: inHelper(file))
        }
        _ = tracker.step(now: 2, processes: [helper([reading(archive)])])
        #expect(try #require(tracker.extractions.first).fileNumber == 801)
        mac.put(.folder(items: 1), at: "/Users/me/Downloads/small")
        #expect(tracker.step(now: 3, processes: [helper([])]).first?.hasPrefix("small.zip: complete: 100.0 KB") == true)
    }

    @Test func aFewQuestionsALookAreEnoughEvenForVeryManyFiles() throws {
        let count = 150_000
        mac.setIndex(index(count), for: archive)
        var tracker = mac.tracker()
        written(through: 0, partly: 50)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing(path(0), size: 50)])])
        var most = 0
        var reached = 0
        // 7,000 files a second, looked at ten times a second, none caught.
        for tenth in 1...100 {
            let upTo = min(count - 1, tenth * 700)
            written(through: upTo, from: reached)
            reached = upTo
            let before = mac.changeTimeAsked
            _ = tracker.step(now: Double(tenth) / 10, processes: [macPacker([reading(archive)])])
            most = max(most, mac.changeTimeAsked - before)
            #expect(tracker.extractions.first?.fileNumber == upTo + 1)
        }
        #expect(most <= 80, "\(most) questions in one look")
    }

    @Test func whatTheDiskSaysNeverTakesProgressBack() throws {
        mac.setIndex(index(1_000), for: archive)
        var tracker = mac.tracker()
        written(through: 600)
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing(path(600), size: 100)])])
        let before = try #require(tracker.extractions.first).written
        // The files go away under it (moved, deleted): nothing is unlearnt.
        for file in 0...600 {
            mac.put(.missing, at: path(file))
        }
        _ = tracker.step(now: 1, processes: [macPacker([reading(archive)])])
        #expect(try #require(tracker.extractions.first).written == before)
    }
}
