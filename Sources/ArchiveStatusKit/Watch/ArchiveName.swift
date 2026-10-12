// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What a file's name says about it being an archive.
enum ArchiveName {
    /// Archives whose index gives the size once extracted.
    static let indexed: Set<String> = ["zip", "rar", "7z"]
    /// Archives without an index that can be read cheaply: followed without
    /// a total.
    static let unindexed: Set<String> = [
        "tar", "tgz", "gz", "tbz", "tbz2", "bz2", "txz", "xz",
    ]

    /// Whether a file of that name is an archive this plugin follows.
    static func isArchive(_ path: String) -> Bool {
        let ending = lastExtension(of: path)
        if indexed.contains(ending) || unindexed.contains(ending) { return true }
        // The older way of naming the parts of a RAR: .r00, .r01…
        return ending.wholeMatch(of: #/[r-z]\d\d/#) != nil
    }

    /// Whether a file of that name is an archive with an index in one
    /// place, quick to read (`zip`, `rar`, `7z`, and the parts of a RAR).
    static func hasIndex(_ path: String) -> Bool {
        let ending = lastExtension(of: path)
        return indexed.contains(ending) || ending.wholeMatch(of: #/[r-z]\d\d/#) != nil
    }

    /// Whether a file of that name is something compressed, which may hold
    /// a tar (`photos.tar.gz`, `photos.tgz`).
    static func isCompressed(_ path: String) -> Bool {
        let ending = lastExtension(of: path)
        return unindexed.contains(ending) && ending != "tar"
    }

    /// Whether a file lies in a Trash folder. An unarchiver set to move an
    /// archive there once it is extracted may still have it open: it is
    /// the same archive, done with, not another one.
    static func isInTrash(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// The file's name without its folder.
    static func fileName(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// The folder a file is in.
    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// The name without what marks it as an archive: `photos.zip` and
    /// `photos.tar.gz` both give `photos`.
    static func baseName(of path: String) -> String {
        var name = fileName(of: path)
        for _ in 0..<2 {
            let ending = lastExtension(of: name)
            guard indexed.contains(ending) || unindexed.contains(ending) else { break }
            name.removeLast(ending.count + 1)
        }
        return name
    }

    /// The last extension, in small letters, without its dot.
    static func lastExtension(of path: String) -> String {
        let name = fileName(of: path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}
