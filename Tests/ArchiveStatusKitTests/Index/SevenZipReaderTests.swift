// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

struct SevenZipReaderTests {
    let scratch: ScratchFolder

    init() throws {
        scratch = try ScratchFolder()
    }

    /// Makes a 7z from a few files with macOS's own `bsdtar`.
    private func makeSevenZip() throws -> String {
        try scratch.write([UInt8](repeating: 0x41, count: 70_000), as: "source/first.txt")
        try scratch.write([UInt8](repeating: 0x42, count: 123), as: "source/sub/second été.txt")
        try scratch.write([], as: "source/sub/empty.txt")
        let archive = scratch.path + "/made.7z"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        process.currentDirectoryURL = URL(filePath: scratch.path)
        process.arguments = ["--format", "7zip", "-cf", archive, "source"]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "bsdtar couldn't make the test archive")
        return archive
    }

    @Test(.tags(.systemTools))
    func a7zIsReadThroughMacOSsOwnLibrary() throws {
        let index = try ArchiveIndex.read(at: makeSevenZip())
        #expect(index.format == .sevenZip)
        let files = Dictionary(uniqueKeysWithValues: index.entries.filter { $0.isFolder == false }.map { ($0.path, $0.size) })
        #expect(files == ["source/first.txt": 70_000, "source/sub/second été.txt": 123, "source/sub/empty.txt": 0])
        #expect(index.totalSize == 70_123)
        #expect(index.entries.contains(ArchiveEntry(path: "source/sub", size: 0, isFolder: true)))
        #expect(index.isWhole)
    }

    @Test func theLibraryIsThere() {
        #expect(SystemArchiveLibrary.shared != nil, "macOS's libarchive couldn't be loaded: 7z archives get no total")
    }

    @Test(.tags(.damagedInput), arguments: [UInt8(0x00), 0xFF, 0x37])
    func somethingThatOnlyStartsLikeA7zGivesNoItems(filler: UInt8) throws {
        let path = try scratch.write(SevenZipReader.signature + [UInt8](repeating: filler, count: 200), as: "fake-\(filler).7z")
        // Refused, or read as an archive that holds nothing: never items made up.
        let index = try? ArchiveIndex.read(at: path)
        #expect(index?.entries.isEmpty ?? true)
    }

    @Test(.tags(.damagedInput, .systemTools))
    func a7zCutShortIsHandled() throws {
        let whole = try Array(Data(contentsOf: URL(filePath: makeSevenZip())))
        for length in stride(from: 0, to: whole.count, by: max(1, whole.count / 60)) {
            let path = try scratch.write(Array(whole.prefix(length)), as: "cut.7z")
            _ = try? ArchiveIndex.read(at: path)
        }
    }
}
