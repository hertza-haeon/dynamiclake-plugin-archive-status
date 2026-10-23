// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// An item at the top of an archive that was given a number on disk
/// because its name was taken there (The Unarchiver, writing in place).
struct NumberedTopTests {
    let lookup = IndexLookup(ArchiveIndex(format: .zip, entries: [
        ArchiveEntry(path: "album/disc 1/a.mp3", size: 10),
        ArchiveEntry(path: "movie.bin", size: 20),
        ArchiveEntry(path: "README", size: 30),
        ArchiveEntry(path: "my.notes/n.txt", size: 40),
    ], parts: []))

    @Test(arguments: [
        ("/x/album-1/disc 1/a.mp3", 0, "/x", "album", "album-1"),
        ("/x/album-12/disc 1/a.mp3", 0, "/x", "album", "album-12"),
        ("/x/movie-2.bin", 1, "/x", "movie.bin", "movie-2.bin"),
        ("/x/README-1", 2, "/x", "README", "README-1"),
        ("/x/my.notes-3/n.txt", 3, "/x", "my.notes", "my.notes-3"),
    ])
    func aNumberedTopIsRecognised(path: String, place: Int, root: String, top: String, onDisk: String) throws {
        let found = try #require(lookup.matchNumberedTop(path))
        #expect(found.match.place == place)
        #expect(found.match.root == root)
        #expect(found.top == top)
        #expect(found.onDisk == onDisk)
    }

    @Test(arguments: ["/x/album/disc 1-1/a.mp3", "/x/album-1/other.mp3", "/x/album1/disc 1/a.mp3", "/x/movie.bin-1.tmp", "/x/elsewhere-1"])
    func aNumberElsewhereIsNot(path: String) {
        #expect(lookup.matchNumberedTop(path) == nil)
    }

    @Test func theNamesBeforeTheNumber() {
        #expect(IndexLookup.unnumbered("album-1", isFile: false) == ["album"])
        #expect(IndexLookup.unnumbered("movie-2.bin", isFile: true) == ["movie.bin"])
        #expect(IndexLookup.unnumbered("README-1", isFile: true) == ["README"])
        #expect(IndexLookup.unnumbered("v1.2-3.tar", isFile: true) == ["v1.2.tar"])
        #expect(IndexLookup.unnumbered("album", isFile: false).isEmpty)
        #expect(IndexLookup.unnumbered("-1", isFile: false).isEmpty)
    }
}

struct IndexLookupTests {
    let lookup = IndexLookup(ArchiveIndex(format: .zip, entries: [
        ArchiveEntry(path: "album", size: 0, isFolder: true),
        ArchiveEntry(path: "album/one.jpg", size: 100),
        ArchiveEntry(path: "album/two.jpg", size: 200),
        ArchiveEntry(path: "album/raw", size: 0, isFolder: true),
        ArchiveEntry(path: "album/raw/one.jpg", size: 4_000),
        ArchiveEntry(path: "notes.txt", size: 30),
        ArchiveEntry(path: "empty.txt", size: 0),
    ], parts: ["/d/album.zip"]))

    @Test func aFileOnDiskIsRecognisedByTheEndOfItsPath() throws {
        let match = try #require(lookup.match("/Users/me/Downloads/album/two.jpg"))
        #expect(match == IndexLookup.Match(place: 2, depth: 2, root: "/Users/me/Downloads"))
    }

    @Test func theLongestEndWins() throws {
        // "one.jpg" is in the archive twice; the folder above tells which.
        #expect(try #require(lookup.match("/x/album/raw/one.jpg")).place == 4)
        #expect(try #require(lookup.match("/x/album/one.jpg")).place == 1)
    }

    @Test func aFileAtTheTopOfTheArchiveGivesItsFolder() throws {
        let match = try #require(lookup.match("/private/var/folders/ab/T/NSIRD_ArchiveService_k3xQ/notes.txt"))
        #expect(match.place == 5)
        #expect(match.root == "/private/var/folders/ab/T/NSIRD_ArchiveService_k3xQ")
    }

    @Test func aFileTheArchiveDoesNotHoldIsNotRecognised() {
        #expect(lookup.match("/Users/me/Downloads/album/three.jpg") == nil)
        #expect(lookup.match("/Users/me/Downloads/album") == nil, "a folder is never the file being written")
        #expect(lookup.match("") == nil)
        #expect(lookup.match("/") == nil)
    }

    @Test func amongItemsOfTheSamePathTheFirstNotYetPassedIsTaken() throws {
        let twice = IndexLookup(ArchiveIndex(format: .zip, entries: [
            ArchiveEntry(path: "a.txt", size: 1), ArchiveEntry(path: "b.txt", size: 2), ArchiveEntry(path: "a.txt", size: 3),
        ], parts: []))
        #expect(try #require(twice.match("/x/a.txt", notBefore: 0)).place == 0)
        #expect(try #require(twice.match("/x/a.txt", notBefore: 1)).place == 2)
        #expect(try #require(twice.match("/x/a.txt", notBefore: 5)).place == 2)
    }

    @Test func namesWrittenInEitherUnicodeFormAreTheSameName() throws {
        // "é" as one character in the archive, as "e" + accent on disk.
        let accented = IndexLookup(ArchiveIndex(format: .zip, entries: [ArchiveEntry(path: "caf\u{00E9}.txt", size: 5)], parts: []))
        #expect(try #require(accented.match("/x/cafe\u{0301}.txt")).place == 0)
    }

    @Test func whatIsDoneIsEverythingBeforeTheFilePlusWhatIsWrittenOfIt() {
        #expect(lookup.before == [0, 0, 100, 300, 300, 4_300, 4_330])
        #expect(lookup.bytesDone(place: 4, written: 1_000) == 1_300)
        // A file never counts for more than the index says it holds.
        #expect(lookup.bytesDone(place: 4, written: 9_999) == 4_300)
        #expect(lookup.fileNumber == [0, 1, 2, 2, 3, 4, 5])
        #expect(lookup.lastSizedPlace == 5)
    }
}
