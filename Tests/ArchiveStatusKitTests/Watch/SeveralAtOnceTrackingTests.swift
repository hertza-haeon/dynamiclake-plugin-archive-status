// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// Archive Utility given several archives at once extracts them at the
/// same time, in one helper, each in a folder of its own (seen on a
/// real Mac, 12 Oct 2026). Replayed here, look by look.
struct SeveralAtOnceTrackingTests {
    let mac = FakeMac()
    let first = "/Users/me/Downloads/no index.tar.gz"
    let second = "/Users/me/Downloads/8 plain.tar"
    let firstWork = "/private/var/folders/2f/x/T/com.apple.desktopservices.ArchiveService/TemporaryItems/NSIRD_ArchiveService_6QMN7T"
    let secondWork = "/private/var/folders/2f/x/T/com.apple.desktopservices.ArchiveService/TemporaryItems/NSIRD_ArchiveService_Jm5qlI"
    /// The two archives hold the very same files.
    let entries = (0..<1_000).map { ArchiveEntry(path: "many/file \($0).bin", size: 8_192) }

    private func looks(_ tracker: inout Tracker, from start: Int = 0, to end: Int) -> [String] {
        var lines: [String] = []
        for look in start...end {
            // Each archive's files are written in its own folder, the
            // second a little behind the first.
            lines += tracker.step(now: Double(look) / 10, processes: [helper([
                reading(first, size: 11_344_275, at: UInt64(look) * 100_000),
                reading(second, size: 1_613_187_584, at: UInt64(look + 1) * 10_000_000),
                writing("\(firstWork)/many/file \(look * 10).bin", size: 4_000),
                writing("\(secondWork)/many/file \(look * 8).bin", size: 4_000),
            ])])
        }
        return lines
    }

    @Test func twoArchivesWithTheSameContentsEachGetTheirOwnFiles() throws {
        mac.setIndex(entries, format: .compressedTar, for: first)
        mac.setIndex(entries, format: .tar, for: second)
        var tracker = mac.tracker()
        let lines = looks(&tracker, to: 50)
        #expect(lines.contains { $0.contains("from earlier in the index") } == false, "no file is taken for the other archive's")
        let extractions = tracker.extractions
        #expect(Set(extractions.map(\.name)) == ["no index.tar.gz", "8 plain.tar"])
        let byName = Dictionary(uniqueKeysWithValues: extractions.map { ($0.name, $0) })
        #expect(Set(extractions.compactMap(\.destination)) == [firstWork, secondWork], "each in its own folder")
        // Files 500 and 400 at the last look, half written.
        let one = try #require(extractions.first { $0.destination == firstWork })
        let other = try #require(extractions.first { $0.destination == secondWork })
        #expect(one.written == 500 * 8_192 + 4_000)
        #expect(other.written == 400 * 8_192 + 4_000)
        #expect(byName.count == 2)
    }

    /// As it happened: the plain tar's index couldn't be read in time, and
    /// the other archive's index lists the very files it writes.
    @Test func anArchiveWithoutAnIndexIsFollowedBesideOneThatListsTheSameFiles() throws {
        mac.setIndex(entries, format: .compressedTar, for: first)
        mac.setIndexFailure(.tooLarge, for: second)
        var tracker = mac.tracker()
        let lines = looks(&tracker, to: 50)
        #expect(lines.contains { $0.contains("from earlier in the index") } == false)
        #expect(lines.contains { $0.hasPrefix("8 plain.tar: Archive Utility is extracting it; no total to read") },
                "it is seen from its first file, not once the other is over")
        let indexed = try #require(tracker.extractions.first { $0.name == "no index.tar.gz" })
        let followed = try #require(tracker.extractions.first { $0.name == "8 plain.tar" })
        #expect(indexed.written == 500 * 8_192 + 4_000)
        #expect(indexed.destination == firstWork)
        // Followed by how far its archive has been read.
        #expect(followed.measuresArchive)
        #expect(followed.total == 1_613_187_584)
        #expect(followed.written == 510_000_000)
        #expect(followed.destination == secondWork)
    }

    /// Seen on a real Mac: both results were said to be at the same
    /// place, the first placeholder. Each has a name of its own.
    @Test(arguments: [true, false])
    func twoResultsOfTheSameNameAreNotTakenForOne(secondHasAnIndex: Bool) throws {
        mac.setIndex(entries, format: .compressedTar, for: first)
        if secondHasAnIndex {
            mac.setIndex(entries, format: .tar, for: second)
        } else {
            mac.setIndexFailure(.tooLarge, for: second)
        }
        // Archive Utility's two placeholders, beside the archives.
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/many")
        mac.put(.folder(items: 0), at: "/Users/me/Downloads/many 2")
        var tracker = mac.tracker()
        _ = looks(&tracker, to: 20)
        let results = tracker.extractions.compactMap(\.result)
        #expect(Set(results) == ["/Users/me/Downloads/many", "/Users/me/Downloads/many 2"], "\(results)")
    }

    /// A file an index doesn't list, written where that archive is being
    /// extracted, isn't taken for the other archive's.
    @Test func aFileNoIndexListsIsNotGivenToTheArchiveWithoutAnIndexWhenItLiesInTheOthersFolder() throws {
        mac.setIndex(entries, format: .compressedTar, for: first)
        mac.setIndexFailure(.tooLarge, for: second)
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [helper([
            reading(first), reading(second, size: 1_000_000, at: 0),
            writing("\(firstWork)/many/file 3.bin", size: 100),
        ])])
        let lines = tracker.step(now: 0.1, processes: [helper([
            reading(first), reading(second, size: 1_000_000, at: 0),
            writing("\(firstWork)/many/._file 3.bin", size: 100),
        ])])
        #expect(lines.contains { $0.hasPrefix("8 plain.tar") } == false)
        #expect(tracker.extractions.map(\.name) == ["no index.tar.gz"])
    }

    @Test(arguments: [
        ("/private/var/folders/2f/x/T/com.apple.desktopservices.ArchiveService/TemporaryItems/NSIRD_ArchiveService_k3xQ9a/a/b.txt",
         "/private/var/folders/2f/x/T/com.apple.desktopservices.ArchiveService/TemporaryItems/NSIRD_ArchiveService_k3xQ9a"),
        ("/tmp/NSIRD_x", "/tmp/NSIRD_x"),
        ("/Users/me/Downloads/photos/a.jpg", nil),
        ("", nil),
    ] as [(String, String?)])
    func theHelpersFolderForAnArchiveIsReadFromAFileItWritesThere(path: String, folder: String?) {
        #expect(Tool.archiveUtility.workFolder(of: path) == folder)
    }
}
