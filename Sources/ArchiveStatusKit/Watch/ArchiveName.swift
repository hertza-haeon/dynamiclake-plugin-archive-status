// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What a file's name says about it being an archive.
enum ArchiveName {
    /// Archives whose index gives the size once extracted: zip, RAR and
    /// 7z, and what is one of them under a name of its own (a comic book,
    /// a Java or Android package, an e-book, an office document…). What a
    /// file is is read from the file itself; its name only says whether to
    /// look.
    static let indexed: Set<String> = [
        "zip", "rar", "7z",
        "cbz", "cbr", "cb7", "zipx", "jar", "war", "ear", "aar", "apk", "ipa", "xpi", "epub", "whl", "nupkg", "vsix", "kmz",
        "docx", "xlsx", "pptx", "odt", "ods", "odp",
    ]
    /// Archives without an index that can be read cheaply: followed without
    /// a total.
    static let unindexed: Set<String> = [
        "tar", "tgz", "gz", "tbz", "tbz2", "bz2", "txz", "xz", "cbt",
    ]

    /// Where macOS, the apps and their own files are: what an unarchiver
    /// reads there is none of the user's archives.
    private static let systemPlaces = [
        "/System/", "/Library/", "/usr/", "/bin/", "/sbin/", "/opt/", "/Applications/", "/private/var/", "/var/",
        "/private/etc/", "/etc/", "/dev/", "/cores/",
    ]
    /// The folders under the user's Library that hold the user's own
    /// files: iCloud Drive, and the disks of Dropbox, OneDrive, Google
    /// Drive and the like.
    private static let cloudFolders = ["/Library/Mobile Documents/", "/Library/CloudStorage/"]

    /// Whether a path is in the user's Library and not among their own
    /// files there: an app's settings, caches and containers.
    static func isInOwnLibrary(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/Library/") else { return false }
        return cloudFolders.contains { path.hasPrefix(home + $0) } == false
    }

    /// Whether a file is among the user's own: not macOS's, not an app's,
    /// not in an app's own folders.
    static func isUsersOwn(_ path: String, home: String) -> Bool {
        guard systemPlaces.contains(where: path.hasPrefix) == false, path.contains(".app/") == false else { return false }
        return isInOwnLibrary(path, home: home) == false
    }

    /// Whether a file of that name is an archive this plugin follows, or
    /// one part of one.
    static func isArchive(_ path: String) -> Bool {
        let ending = lastExtension(of: path)
        if indexed.contains(ending) || unindexed.contains(ending) { return true }
        // The older way of naming the parts of a RAR (.r00, .r01…), and
        // the parts of a zip (.z01, .z02…).
        if ending.wholeMatch(of: #/[r-z]\d\d/#) != nil { return true }
        // An archive cut into numbered pieces: photos.7z.001, photos.7z.002…
        return numberedPart(path) != nil
    }

    /// The archive a file belongs to, going by its name alone: itself, or,
    /// for one part of several, the part the set is known by. That is the
    /// first part of a RAR (`photos.part1.rar`, `photos.rar`), the `.zip`
    /// of a zip in parts (`photos.z01` gives `photos.zip`, which holds the
    /// index), and the first piece of an archive cut into numbered ones
    /// (`photos.7z.003` gives `photos.7z.001`).
    static func archive(of path: String) -> String {
        if lastExtension(of: path).wholeMatch(of: #/z\d\d/#) != nil {
            return String(path.dropLast(3)) + "zip"
        }
        if let piece = numberedPart(path) {
            return piece.whole + "." + String(repeating: "0", count: piece.digits - 1) + "1"
        }
        return RarVolumeName.firstPart(of: path)
    }

    /// `photos.7z.003`: one piece of an archive cut into numbered pieces,
    /// which put end to end are the archive. `whole` is the archive's own
    /// name (`photos.7z`), with its folder.
    static func numberedPart(_ path: String) -> (whole: String, number: Int, digits: Int)? {
        let ending = lastExtension(of: path)
        guard ending.count == 3, ending.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(ending), number >= 1 else { return nil }
        let whole = String(path.dropLast(4))
        let inner = lastExtension(of: whole)
        guard indexed.contains(inner) || unindexed.contains(inner) else { return nil }
        return (whole, number, 3)
    }

    /// The pieces of an archive cut into numbered ones, from the one given
    /// on, by their names alone: `photos.7z.001`, `photos.7z.002`…
    static func numberedParts(from first: String) -> some Sequence<String> {
        guard let piece = numberedPart(first) else { return AnySequence([first]) }
        return AnySequence((piece.number...999).lazy.map { number in
            let text = String(number)
            return piece.whole + "." + String(repeating: "0", count: max(0, piece.digits - text.count)) + text
        })
    }

    /// A name as it says what kind of archive it is: a numbered piece
    /// goes by the archive it is a piece of (`photos.7z.001` is a 7z).
    private static func kindName(of path: String) -> String {
        numberedPart(path)?.whole ?? path
    }

    /// What the card shows as the archive's type: its extension, and for a
    /// numbered piece the archive's own (`7z` for `photos.7z.001`).
    static func typeExtension(of path: String) -> String {
        lastExtension(of: kindName(of: path))
    }

    /// Whether a file of that name is an archive with an index in one
    /// place, quick to read (`zip`, `rar`, `7z`, and the parts of a RAR).
    static func hasIndex(_ path: String) -> Bool {
        let ending = lastExtension(of: kindName(of: path))
        return indexed.contains(ending) || ending.wholeMatch(of: #/[r-y]\d\d/#) != nil
    }

    /// Whether a file of that name is a tar that isn't compressed: its
    /// list is its every header, read without unpacking anything.
    static func isPlainTar(_ path: String) -> Bool {
        lastExtension(of: kindName(of: path)) == "tar"
    }

    /// Whether a file of that name is something compressed, which may hold
    /// a tar (`photos.tar.gz`, `photos.tgz`).
    static func isCompressed(_ path: String) -> Bool {
        let ending = lastExtension(of: kindName(of: path))
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

    /// The name without what marks it as an archive: `photos.zip`,
    /// `photos.tar.gz` and `photos.7z.001` all give `photos`.
    static func baseName(of path: String) -> String {
        var name = fileName(of: kindName(of: path))
        let first = lastExtension(of: name)
        if first.isEmpty == false, indexed.contains(first) == false, unindexed.contains(first) == false {
            // An archive of a kind this plugin has no name for
            // (`photos.tar.zst`): its own ending goes, then a `tar` under it.
            name.removeLast(first.count + 1)
            if lastExtension(of: name) == "tar" {
                name.removeLast(4)
            }
            return name
        }
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
