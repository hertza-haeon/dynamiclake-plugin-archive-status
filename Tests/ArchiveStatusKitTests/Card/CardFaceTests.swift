// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

struct CardFaceTests {
    let mac = FakeMac()
    let pictures = Pictures()
    let face: CardFace

    init() {
        face = CardFace(ruler: testRuler(), pictures: pictures, numericText: true)
    }

    /// An extraction of `name` as the tracker would hold it after these looks
    /// at one file being written: (when, bytes written).
    private func extraction(_ name: String = "photos.zip", total: UInt64? = 2_000_000_000,
                            looks: [(Double, UInt64)] = [(0, 100_000_000)]) throws -> Extraction {
        let archive = "/Users/me/Downloads/" + name
        if let total {
            mac.setIndex([ArchiveEntry(path: "big.bin", size: total)], for: archive)
        } else {
            mac.setIndexFailure(.locked, for: archive)
        }
        var tracker = mac.tracker()
        for (now, written) in looks {
            _ = tracker.step(now: now, processes: [macPacker([reading(archive), writing("/Users/me/Desktop/big.bin", size: written)])])
        }
        return try #require(tracker.extractions.first)
    }

    private func text(_ component: Component?) -> String? {
        if case .text(let text, _)? = component { text } else { nil }
    }

    @Test func theExtractingFaceIsFirefoxDownloadsWithShowInFinderWhereStopWas() throws {
        let extraction = try extraction(looks: [(0, 100_000_000), (1, 250_000_000)])
        let built = face.extracting(extraction, activityID: "extraction-1", cardSince: 0, settings: PluginSettings(), now: 6)
        #expect(built.surfaces.pillLeft == .picture(base64: try #require(pictures.base64(.type("zip")))))
        #expect(built.surfaces.pillRight == .ring(value: 0.125, tint: "blue"))
        #expect(built.surfaces.peekLeft == .button(title: "Show in Finder", symbol: "folder.fill", actionID: "show:extraction-1", tint: "blue"))
        // No time left can be told yet: the speed stands in for it.
        #expect(built.surfaces.peekCenter == .text("0.25/2.00GB · 150 MB/s", style: "marquee"))
        #expect(built.surfaces.peekRight == .text("12%", style: "numeric"))
        #expect(built.surfaces.capsule == built.surfaces.pillLeft)
    }

    // MARK: Several extractions on the one card (decided on 12 Oct 2026)

    @Test func severalShowTheirNumberAndTheirAmountsAddedUp() throws {
        let progress = CardFace.Progress(written: 2_700_000_000, total: 5_000_000_000, speed: 200_000_000, secondsLeft: 18,
                                         secondsLeftChangeAt: 101, startedAt: 90)
        let built = face.extracting(progress, of: .several(3), activityID: "extraction-1", cardSince: 100,
                                    settings: PluginSettings(), now: 100.5)
        // The number is there from the first moment: no archive box first.
        let three = Component.picture(base64: try #require(pictures.base64(.type("3"))))
        #expect(built.surfaces.pillLeft == three)
        #expect(built.surfaces.capsule == three)
        #expect(built.surfaces.pillRight == .ring(value: 0.54, tint: "blue"))
        #expect(built.surfaces.peekCenter == .text("2.70/5.00GB · 18 seconds", style: "marquee"))
        #expect(built.surfaces.peekRight == .text("54%", style: "numeric"))
        #expect(built.changesAt == 101)
        let stalled = face.extracting(progress, of: .several(3), activityID: "extraction-1", cardSince: 100, stalledSince: 120,
                                      settings: PluginSettings(), now: 121)
        #expect(stalled.surfaces.peekCenter == .text("Stalled • 3 Extractions", style: "marquee"))
    }

    @Test(arguments: [(3, 3, "3 Extractions Completed"), (2, 3, "2/3 Extractions Completed"), (0, 2, "0/2 Extractions Completed"),
                      (12, 12, "12 Extractions Completed")])
    func severalThatAreOverAreSaidInTheChosenWords(completed: Int, count: Int, text: String) {
        #expect(CardFace.summaryText(completed: completed, of: count) == text)
    }

    @Test func severalThatAreOverHaveTheCheckOrTheCrossAndShowInFinderAlone() throws {
        let all = face.summary(completed: 3, of: 3, activityID: "extraction-1", cardSince: 0, lineSince: 50, hasItems: true,
                               settings: PluginSettings(), now: 50)
        #expect(all.surfaces.pillLeft == .picture(base64: try #require(pictures.base64(.type("3")))))
        #expect(all.surfaces.pillRight == .picture(base64: try #require(pictures.base64(.done))))
        #expect(all.surfaces.peekLeft == CardFace.showButton("extraction-1"))
        #expect(all.surfaces.peekCenter == .text("3 Extractions Completed", style: "marquee"))
        #expect(all.surfaces.peekRight == nil)
        let some = face.summary(completed: 2, of: 3, activityID: "extraction-1", cardSince: 0, lineSince: 50, hasItems: false,
                                settings: PluginSettings(), now: 50)
        #expect(some.surfaces.pillRight == .picture(base64: try #require(pictures.base64(.stopped))))
        #expect(some.surfaces.peekLeft == nil, "nothing of them is there to show")
        #expect(some.surfaces.peekCenter == .text("2/3 Extractions Completed", style: "marquee"))
    }

    @Test func aCardShowsTheArchiveBoxForItsFirstFourSecondsThenTheType() throws {
        let extraction = try extraction()
        let box = Component.picture(base64: try #require(pictures.base64(.box)))
        let zip = Component.picture(base64: try #require(pictures.base64(.type("zip"))))
        let early = face.extracting(extraction, activityID: "x", cardSince: 100, settings: PluginSettings(), now: 103.9)
        #expect(early.surfaces.pillLeft == box)
        #expect(early.changesAt == 104, "the plugin comes back when the box gives way to the type")
        // The capsule is drawn once: it has the type from the first second.
        #expect(early.surfaces.capsule == zip)
        let later = face.extracting(extraction, activityID: "x", cardSince: 100, settings: PluginSettings(), now: 104)
        #expect(later.surfaces.pillLeft == zip)
    }

    @Test func withFileTypeIconsOffTheBoxStays() throws {
        var settings = PluginSettings()
        settings.fileTypeIcons = false
        let box = Component.picture(base64: try #require(pictures.base64(.box)))
        let built = face.extracting(try extraction(), activityID: "x", cardSince: 0, settings: settings, now: 60)
        #expect(built.surfaces.pillLeft == box)
        #expect(built.surfaces.capsule == box)
    }

    @Test(arguments: [
        ("photos.zip", "zip"), ("GAME.PART1.RAR", "rar"), ("backup.7z", "7z"), ("sources.tar.gz", "gz"),
        ("old.tbz2", "tbz2"), ("weird.extension", "exte"), ("noending", ""), ("accent.zïp", ""), ("dots.", ""),
    ])
    func theTypeIsTheNamesEndingInSmallLetters(name: String, type: String) {
        #expect(CardFace.typeText(of: name) == type)
    }

    @Test func withoutATotalTheRingSpinsAndTheAmountStandsAlone() throws {
        let extraction = try extraction("sealed.rar", total: nil, looks: [(0, 100_000_000), (1, 300_000_000)])
        let built = face.extracting(extraction, activityID: "x", cardSince: 0, settings: PluginSettings(), now: 6)
        #expect(built.surfaces.pillRight == .ring(value: nil, tint: "blue"))
        #expect(built.surfaces.peekCenter == .text("300MB · 200 MB/s", style: "marquee"))
        #expect(built.surfaces.peekRight == .text("—", style: "numeric"))
    }

    // MARK: Extraction Details

    /// 100 MB a second for five seconds, of 2 GB.
    private func steady() throws -> Extraction {
        try extraction(looks: (0...10).map { (Double($0) / 2, UInt64($0) * 50_000_000) })
    }

    @Test func detailsOnSpeedShowsTheSpeed() throws {
        var settings = PluginSettings()
        settings.details = .speed
        let built = face.extracting(try steady(), activityID: "x", cardSince: 0, settings: settings, now: 5)
        #expect(text(built.surfaces.peekCenter) == "0.50/2.00GB · 100 MB/s")
    }

    @Test func detailsOnTimeShowsTheTimeLeftAndComesBackWhenItsSecondChanges() throws {
        let extraction = try steady()
        #expect(extraction.secondsLeft == 15)
        let built = face.extracting(extraction, activityID: "x", cardSince: 0, settings: PluginSettings(), now: 5)
        #expect(text(built.surfaces.peekCenter) == "0.50/2.00GB · 15 seconds")
        #expect(built.changesAt == extraction.secondsLeftChangeAt)
        #expect(try #require(built.changesAt) > 5)
    }

    @Test func detailsOnAllTakesTurnsEveryThreeSecondsWithoutMovingTheLine() throws {
        var settings = PluginSettings()
        settings.details = .both
        let extraction = try steady()
        // Seconds 3 to 6 of the extraction: the time left's turn. Then the speed's.
        let time = face.extracting(extraction, activityID: "x", cardSince: 0, settings: settings, now: 5)
        let speed = face.extracting(extraction, activityID: "x", cardSince: 0, settings: settings, now: 6.5)
        let timeText = try #require(text(time.surfaces.peekCenter))
        let speedText = try #require(text(speed.surfaces.peekCenter))
        #expect(timeText.hasPrefix("0.50/2.00GB · 15 seconds"))
        #expect(speedText.hasPrefix("0.50/2.00GB · 100 MB/s"))
        // Each is padded to the width of the widest (the time left counting
        // as "88 seconds" in its last minute): the line stays where it is.
        let ruler = testRuler()
        #expect(ruler.width(timeText) == ruler.width(speedText))
        #expect(ruler.width(timeText) == ruler.width("0.50/2.00GB · 88 seconds"))
        // The plugin comes back at the next turn, or sooner for the next second.
        #expect(try #require(time.changesAt) <= 6)
        #expect(speed.changesAt == 9)
    }

    @Test func whileNoTimeLeftCanBeToldAllShowsTheSpeedAlone() throws {
        var settings = PluginSettings()
        settings.details = .both
        let built = face.extracting(try extraction(looks: [(0, 0), (1, 100_000_000)]), activityID: "x", cardSince: 0,
                                    settings: settings, now: 4)
        #expect(text(built.surfaces.peekCenter) == "0.10/2.00GB · 100 MB/s")
    }

    @Test func withoutDigitsThatChangeInPlaceThePercentSignIsDropped() throws {
        let plain = CardFace(ruler: testRuler(), pictures: pictures, numericText: false)
        var built = plain.extracting(try extraction(), activityID: "x", cardSince: 0, settings: PluginSettings(), now: 6)
        #expect(built.surfaces.peekRight == .text("5", style: "compact"))
        // Three characters don't fit there: left out.
        built = plain.extracting(try extraction(total: nil), activityID: "x", cardSince: 0, settings: PluginSettings(), now: 6)
        #expect(built.surfaces.peekRight == .text("—", style: "compact"))
    }

    // MARK: Complete

    private func ended(_ name: String) throws -> Extraction {
        let archive = "/Users/me/Downloads/" + name
        mac.setIndex([ArchiveEntry(path: "big.bin", size: 1_000)], for: archive)
        mac.put(.file(size: 1_000), at: "/Users/me/Desktop/big.bin")
        var tracker = mac.tracker()
        _ = tracker.step(now: 0, processes: [macPacker([reading(archive), writing("/Users/me/Desktop/big.bin", size: 500)])])
        _ = tracker.step(now: 1, processes: [macPacker([])])
        return try #require(tracker.ended.last)
    }

    @Test func theCompleteFaceHasTheGreenCheckTheNameAndBothButtons() throws {
        let built = face.complete(try ended("photos.zip"), activityID: "extraction-4", cardSince: 0, lineSince: 20,
                                  settings: PluginSettings(), now: 20)
        #expect(built.surfaces.pillLeft == .picture(base64: try #require(pictures.base64(.type("zip")))))
        #expect(built.surfaces.pillRight == .picture(base64: try #require(pictures.base64(.done))))
        #expect(built.surfaces.peekLeft == .button(title: "Show in Finder", symbol: "folder.fill", actionID: "show:extraction-4", tint: "blue"))
        #expect(built.surfaces.peekCenter == .text("Complete • photos.zip", style: "marquee"))
        #expect(built.surfaces.peekRight == .button(title: "Open", symbol: "arrow.up.forward.app.fill", actionID: "open:extraction-4", tint: "blue"))
        #expect(built.linePhase == .whole)
        #expect(built.changesAt == nil)
    }

    @Test func aFinishedCardShowsItsTypeEvenInItsFirstFourSeconds() throws {
        let built = face.complete(try ended("photos.zip"), activityID: "x", cardSince: 19, lineSince: 20,
                                  settings: PluginSettings(), now: 20)
        #expect(built.surfaces.pillLeft == .picture(base64: try #require(pictures.base64(.type("zip")))))
    }

    @Test func aLineTooLongStaysStillCutShortThenScrollsWhole() throws {
        let name = "Some.Very.Long.Archive.Name.2026.part1.rar"
        let extraction = try ended(name)
        let held = face.complete(extraction, activityID: "x", cardSince: 0, lineSince: 20, settings: PluginSettings(), now: 21)
        let heldText = try #require(text(held.surfaces.peekCenter))
        #expect(held.linePhase == .held)
        #expect(heldText.hasPrefix("Complete • Some.Very"))
        #expect(heldText.hasSuffix("…"))
        #expect(held.changesAt == 23, "three seconds after the line came up")

        let scrolling = face.complete(extraction, activityID: "x", cardSince: 0, lineSince: 20, settings: PluginSettings(), now: 23)
        #expect(scrolling.linePhase == .scrolling)
        // Whole, with a blank before it that keeps its first letter clear of the fade.
        #expect(text(scrolling.surfaces.peekCenter) == "\u{2800}Complete • Some.Very.Long.Archive.Name.2026.part1.rar")
        #expect(scrolling.changesAt == nil)
    }

    @Test func aNameLongerThanDynamicLakeAcceptsIsShortenedInItsMiddle() {
        let name = String(repeating: "a", count: 200) + String(repeating: "z", count: 200) + ".zip"
        let line = CardFace.statusText("Complete", name: name)
        #expect(line.count + TextRuler.leadBlank.count == CardFace.maxTextCharacters)
        #expect(line.hasPrefix("Complete • aaaa"))
        #expect(line.hasSuffix("zzzz.zip"))
        #expect(line.contains("…"))
        #expect(CardFace.statusText("Complete", name: "short.zip") == "Complete • short.zip")
    }

    @Test func whereThePicturesCannotBeDrawnDynamicLakesOwnSymbolsStandIn() throws {
        let blind = CardFace(ruler: testRuler(), pictures: Pictures(draw: { _ in nil }), numericText: true)
        let extracting = blind.extracting(try extraction(), activityID: "x", cardSince: 0, settings: PluginSettings(), now: 6)
        #expect(extracting.surfaces.pillLeft == .symbol("archivebox", tint: "blue"))
        #expect(extracting.surfaces.capsule == .symbol("archivebox", tint: "blue"))
        let complete = blind.complete(try ended("photos.zip"), activityID: "x", cardSince: 0, lineSince: 9,
                                      settings: PluginSettings(), now: 9)
        #expect(complete.surfaces.pillRight == .status("success", tint: "green"))
    }

    @Test func aPictureTooHeavyForAMessageIsNotUsed() {
        let heavy = Pictures(draw: { _ in Data(count: 60_000) })
        #expect(heavy.base64(.box) == nil)
    }
}
