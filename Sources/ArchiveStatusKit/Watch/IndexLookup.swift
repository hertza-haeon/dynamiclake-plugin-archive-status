// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// An archive's index, laid out to answer one question fast: this file is
/// being written, so how far is the extraction?
///
/// Unarchivers extract the items in the order of the index. The place of
/// the file being written gives everything that is already done: all the
/// items before it. No folder has to be listed or added up.
struct IndexLookup: Sendable {
    let index: ArchiveIndex
    /// For each item, the size of all the items before it.
    let before: [UInt64]
    /// For each item, how many files there are up to and including it.
    let fileNumber: [Int]
    /// The last file that isn't empty: the one whose presence, whole, says
    /// that an extraction reached its end.
    let lastSizedPlace: Int?
    /// The places of the files (not the folders), in the index's order.
    let filePlaces: [Int]
    /// The files that can't be checked one by one on a disk: those whose
    /// path the archive holds more than once, or twice but for capital
    /// letters. On a Mac they end up as one file.
    let sharedPlaces: Set<Int>
    /// The places of the files, by their path in the archive.
    private let places: [String: [Int]]
    /// The most folders deep any file is, counting its own name.
    private let maxDepth: Int

    /// A file on disk recognised as an item of the archive.
    struct Match: Equatable {
        /// The item's place in the index.
        var place: Int
        /// How many parts of the path matched, the file's name included.
        var depth: Int
        /// The folder the archive is being extracted into: the path on disk
        /// without the item's own path.
        var root: String
    }

    init(_ index: ArchiveIndex) {
        self.index = index
        var before: [UInt64] = []
        var fileNumber: [Int] = []
        var places: [String: [Int]] = [:]
        var sum: UInt64 = 0
        var files = 0
        var maxDepth = 1
        var lastSized: Int?
        var filePlaces: [Int] = []
        before.reserveCapacity(index.entries.count)
        fileNumber.reserveCapacity(index.entries.count)
        for (place, entry) in index.entries.enumerated() {
            before.append(sum)
            sum = sum.addingSaturating(entry.size)
            if entry.isFolder == false {
                files += 1
                filePlaces.append(place)
                places[entry.path, default: []].append(place)
                maxDepth = max(maxDepth, entry.path.split(separator: "/").count)
                if entry.size > 0 { lastSized = place }
            }
            fileNumber.append(files)
        }
        self.before = before
        self.fileNumber = fileNumber
        self.places = places
        self.maxDepth = maxDepth
        self.lastSizedPlace = lastSized
        self.filePlaces = filePlaces
        var byName: [String: [Int]] = [:]
        for place in filePlaces {
            byName[index.entries[place].path.lowercased(), default: []].append(place)
        }
        self.sharedPlaces = Set(byName.values.filter { $0.count > 1 }.joined())
    }

    /// The item of the archive that the file at `path` is, going by the end
    /// of its path: the longest end that is an item's path wins. Where the
    /// archive holds several items of that path, the first one at or after
    /// `position` (an extraction only moves forward).
    func match(_ path: String, notBefore position: Int = 0) -> Match? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.isEmpty == false else { return nil }
        for depth in stride(from: min(maxDepth, parts.count), through: 1, by: -1) {
            let candidate = parts.suffix(depth).joined(separator: "/")
            guard let found = places[candidate] else { continue }
            let place = found.first { $0 >= position } ?? found[found.count - 1]
            let root = "/" + parts.dropLast(depth).joined(separator: "/")
            return Match(place: place, depth: depth, root: root)
        }
        return nil
    }

    /// How much is extracted once `written` bytes of the item at `place`
    /// are on disk.
    func bytesDone(place: Int, written: UInt64) -> UInt64 {
        before[place].addingSaturating(min(written, index.entries[place].size))
    }
}
