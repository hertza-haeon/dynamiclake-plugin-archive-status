// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// What a file's name says of the archive it is, or is a part of.
struct ArchiveNameTests {
    @Test(arguments: [
        "photos.zip", "photos.RAR", "photos.7z", "photos.tar", "photos.tar.gz", "photos.tgz", "photos.tar.xz",
        "photos.r00", "photos.s17", "photos.z01", "photos.part2.rar",
        "photos.7z.001", "photos.zip.002", "photos.tar.gz.014", "photos.7Z.001",
    ])
    func theseAreArchivesOrPartsOfOne(name: String) {
        #expect(ArchiveName.isArchive("/x/" + name))
    }

    /// A zip, a RAR or a 7z under a name of its own.
    @Test(arguments: ["comic.cbz", "comic.CBR", "comic.cb7", "comic.cbt", "app.jar", "app.apk", "app.ipa", "book.epub", "report.docx"])
    func theseAreArchivesUnderAnotherName(name: String) {
        #expect(ArchiveName.isArchive("/x/" + name))
        #expect(ArchiveName.baseName(of: "/x/" + name) == String(name.prefix { $0 != "." }))
    }

    /// An archive of a kind there is no name for: its ending goes, and a
    /// `tar` under it.
    @Test(arguments: [("backup.tar.zst", "backup"), ("disc.iso", "disc"), ("old.lzh", "old"), ("data.tar.lz4", "data"),
                      ("my.files.cab", "my.files"), ("noending", "noending")])
    func theNameWithoutAnEndingThatIsNotKnown(name: String, base: String) {
        #expect(ArchiveName.baseName(of: "/x/" + name) == base)
    }

    @Test(arguments: [
        ("/Users/me/Downloads/disc.iso", true),
        ("/Volumes/USB/backup.tar.zst", true),
        ("/private/tmp/work/data.lz4", true),
        ("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/disc.iso", true),
        ("/Users/me/Library/CloudStorage/Dropbox/disc.iso", true),
        ("/Users/me/Library/Caches/com.macpaw.site.theunarchiver/x.db", false),
        ("/Users/me/Library/Containers/com.aone.keka/Data/tmp/x", false),
        ("/System/Library/Fonts/SFNS.ttf", false),
        ("/Applications/Keka.app/Contents/Resources/Keka.css", false),
        ("/Users/me/Apps/Tool.app/Contents/Info.plist", false),
        ("/private/var/folders/2f/x/T/TemporaryItems/y", false),
        ("/usr/share/icu/icudt74l.dat", false),
    ])
    func whatIsTheUsersOwnAndWhatIsNot(path: String, isOwn: Bool) {
        #expect(ArchiveName.isUsersOwn(path, home: "/Users/me") == isOwn)
    }

    @Test(arguments: [
        "photos.jpg", "photos", "photos.001", "notes.txt.001", "photos.7z.000", "photos.7z.01", "photos.7z.0001",
        "photos.7z.abc", ".zip",
    ])
    func theseAreNot(name: String) {
        #expect(ArchiveName.isArchive("/x/" + name) == false)
    }

    /// Seen on a real Mac, 13 Oct 2026: `parts.z01` was taken for a
    /// part of `parts.rar`, which didn't exist.
    @Test(arguments: [
        ("photos.zip", "photos.zip"),
        ("photos.z01", "photos.zip"),
        ("photos.z12", "photos.zip"),
        ("photos.7z.001", "photos.7z.001"),
        ("photos.7z.003", "photos.7z.001"),
        ("my.dotted name.zip.120", "my.dotted name.zip.001"),
        ("photos.rar", "photos.rar"),
        ("photos.r05", "photos.rar"),
        ("photos.part3.rar", "photos.part1.rar"),
        ("photos.tar.gz", "photos.tar.gz"),
    ])
    func aPartGoesByItsArchive(part: String, archive: String) {
        #expect(ArchiveName.archive(of: "/x/" + part) == "/x/" + archive)
    }

    @Test(arguments: [
        ("photos.zip", "zip", "photos"),
        ("photos.7z.001", "7z", "photos"),
        ("photos.zip.002", "zip", "photos"),
        ("photos.tar.gz.001", "gz", "photos"),
        ("photos.tar.gz", "gz", "photos"),
        ("my.dotted name.7z.001", "7z", "my.dotted name"),
    ])
    func aNumberedPieceIsOfItsArchivesKind(name: String, type: String, base: String) {
        #expect(ArchiveName.typeExtension(of: "/x/" + name) == type)
        #expect(ArchiveName.baseName(of: "/x/" + name) == base)
    }

    @Test func aNumberedPieceOfAnIndexedArchiveHasAnIndex() {
        #expect(ArchiveName.hasIndex("/x/photos.7z.001"))
        #expect(ArchiveName.hasIndex("/x/photos.zip.001"))
        #expect(ArchiveName.hasIndex("/x/photos.tar.gz.001") == false)
        #expect(ArchiveName.isCompressed("/x/photos.tar.gz.001"))
        #expect(ArchiveName.isCompressed("/x/photos.7z.001") == false)
    }

    @Test func thePiecesFollowOneAnotherByTheirNumbers() {
        #expect(Array(ArchiveName.numberedParts(from: "/x/photos.7z.001").prefix(3))
            == ["/x/photos.7z.001", "/x/photos.7z.002", "/x/photos.7z.003"])
        #expect(Array(ArchiveName.numberedParts(from: "/x/photos.7z.998")) == ["/x/photos.7z.998", "/x/photos.7z.999"])
        #expect(Array(ArchiveName.numberedParts(from: "/x/photos.7z")) == ["/x/photos.7z"])
    }
}
