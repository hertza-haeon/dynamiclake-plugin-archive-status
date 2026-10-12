// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The plugin's pictures written out as files, to look at them
/// (`archive-status --pictures <folder>`).
public enum Preview {
    /// Writes each picture as a PNG into `folder` and returns the files' names.
    public static func writePictures(to folder: String) -> [String] {
        let kinds: [(String, PictureKind)] = [
            ("box", .box), ("done", .done), ("stopped", .stopped), ("stalled", .stalled),
            ("type-zip", .type("zip")), ("type-rar", .type("rar")), ("type-7z", .type("7z")),
            ("type-tgz", .type("tgz")), ("type-gz", .type("gz")),
            ("several-2", .type("2")), ("several-3", .type("3")), ("several-4", .type("4")), ("several-7", .type("7")),
            ("several-12", .type("12")),
        ]
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var written: [String] = []
        for (name, kind) in kinds {
            guard let data = Pictures.png(kind) else { continue }
            let file = folder + "/" + name + ".png"
            if FileManager.default.createFile(atPath: file, contents: data) {
                written.append(name + ".png (\(data.count) bytes)")
            }
        }
        if writeSheet(of: kinds.map(\.1), to: folder + "/sheet.png") {
            written.append("sheet.png (all of them on black, as on the notch, three times their size)")
        }
        return written
    }

    /// A stand-in for the plugin's icon, until it has one of its own: the
    /// archive box in its blue circle, on black, 512 pixels a side.
    public static func writeStandInIcon(to file: String) -> Bool {
        let side = 512
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = Pictures.png(.box, pixels: 384), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let box = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(box, in: CGRect(x: 64, y: 64, width: 384, height: 384))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(filePath: file) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// The messages of one card's life, as they go to DynamicLake (JSON, one
    /// a line): made, brought up to date, complete, taken away. For checking
    /// them against a real DynamicLake (`archive-status --messages`).
    public static func sampleMessages() -> [String] {
        let face = CardFace(ruler: .system(), pictures: Pictures(), numericText: true)
        let index = ArchiveIndex(format: .zip, entries: [ArchiveEntry(path: "photos/one.jpg", size: 2_559_400_215)],
                                 parts: ["/tmp/Some.Long.Archive.Name.2026.photos.zip"])
        var extraction = Extraction(id: 1, tool: .archiveUtility, archivePath: index.parts[0], startedAt: 0, pace: Pace(now: 0))
        extraction.total = index.totalSize
        extraction.written = 850_000_000
        extraction.secondsLeft = 11
        let settings = PluginSettings()
        let id = "extraction-sample"
        let extracting = face.extracting(extraction, activityID: id, cardSince: 0, settings: settings, now: 1).surfaces
        let later = face.extracting(extraction, activityID: id, cardSince: 0, settings: settings, now: 6).surfaces
        extraction.ending = .complete
        let held = face.complete(extraction, activityID: id, cardSince: 0, lineSince: 20, settings: settings, now: 20).surfaces
        let scrolling = face.complete(extraction, activityID: id, cardSince: 0, lineSince: 20, settings: settings, now: 24).surfaces
        let messages: [LakeMessage] = [
            .create(id, surfaces: extracting), .update(id, surfaces: later), .update(id, surfaces: held, presentSneakPeek: 7),
            .update(id, surfaces: scrolling, presentSneakPeek: 4), .dismiss(id),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return messages.compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
    }

    /// All the pictures side by side on black, enlarged.
    private static func writeSheet(of kinds: [PictureKind], to file: String) -> Bool {
        let scale = 3
        let cell = Pictures.pixels * scale
        let gap = 36
        let width = kinds.count * cell + (kinds.count + 1) * gap
        let height = cell + 2 * gap
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (place, kind) in kinds.enumerated() {
            guard let data = Pictures.png(kind), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            context.draw(image, in: CGRect(x: gap + place * (cell + gap), y: gap, width: cell, height: cell))
        }
        guard let sheet = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(filePath: file) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, sheet, nil)
        return CGImageDestinationFinalize(destination)
    }
}
