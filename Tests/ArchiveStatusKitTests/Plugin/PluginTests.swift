// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

/// Made-up looks, set by the test.
private final class FakeLookout: Lookout {
    var processes: [ToolProcess] = []
    var basePause = 0.1

    func look(now: Double) -> [ToolProcess] { processes }
    func pause(attention: Tracker.Attention, now: Double) -> Double { basePause }
}

/// DynamicLake's place: keeps what the plugin sends.
private final class FakeLink: LakeLink {
    var sent: [LakeMessage] = []
    var isClosed = false

    func send(_ message: LakeMessage) throws(LakeError) {
        if isClosed { throw .closed }
        sent.append(message)
    }

    func receive(wait seconds: Double) throws(LakeError) -> [LakeIncoming] { [] }
}

/// What the test collects from the plugin, and what it changes under it.
private final class Notes {
    var log: [String] = []
    var revealed: [[String]] = []
    var opened: [String] = []
    var settingsFile: Data?
}

/// The whole plugin on a made-up Mac: the tracker, the cards and their
/// messages, with stand-ins for macOS, for DynamicLake and for the Finder.
private struct Rig {
    let mac = FakeMac()
    let owner = FakePresence()
    let lookout = FakeLookout()
    let link = FakeLink()
    let notes = Notes()
    var plugin: Plugin
    let pictures = Pictures()

    let archive = "/Users/me/Downloads/photos.zip"
    let written = "/Users/me/Desktop/big.bin"
    /// A second archive, of 3 GB, which another MacPacker extracts.
    let other = "/Users/me/Downloads/music.rar"
    let otherWritten = "/Users/me/Music/album.flac"
    let otherTotal: UInt64 = 3_000_000_000
    /// What the archive holds, and how fast it is extracted: 2 GB at 100 MB
    /// a second, twenty seconds, unless a test says otherwise.
    let total: UInt64
    var rate = 100_000_000.0

    init(total: UInt64 = 2_000_000_000, features: Set<String> = ["numericText", "presentSneakPeek"],
         settings: String? = nil, connected: Bool = true) {
        self.total = total
        notes.settingsFile = settings.map { Data($0.utf8) }
        let reader = SettingsReader(environment: ["DYNAMICLAKE_PLUGIN_SETTINGS_PATH": "/settings.json"]) { [notes] _ in
            notes.settingsFile
        }
        plugin = Plugin(lookout: lookout, link: connected ? link : nil, surroundings: mac.surroundings,
                        presence: owner.presence, settings: reader,
                        features: features, ruler: testRuler(),
                        opener: Opener(reveal: { [notes] in notes.revealed.append($0) }, open: { [notes] in notes.opened.append($0) }),
                        log: { [notes] in notes.log.append($0) })
        mac.setIndex([ArchiveEntry(path: "big.bin", size: total)], for: archive)
        mac.setIndex([ArchiveEntry(path: "album.flac", size: otherTotal)], format: .rar4, for: other)
        mac.put(.folder(items: 3), at: "/Users/me/Desktop")
        mac.put(.folder(items: 3), at: "/Users/me/Music")
    }

    /// MacPacker with the rig's own archive at `now`: extracting since
    /// `began`, or, from `until` on, done with it (the file whole, or left
    /// at `leftAt` when it stopped short).
    func first(at now: Double, since began: Double = 0, until end: Double = .infinity, leftAt: UInt64? = nil) -> ToolProcess {
        if now >= end {
            mac.put(.file(size: leftAt ?? total), at: written)
            return macPacker([], pid: 500)
        }
        guard now >= began else { return macPacker([], pid: 500) }
        return macPacker([reading(archive), writing(written, size: min(total, UInt64((now - began) * rate)))], pid: 500)
    }

    /// The same for the second archive, in another MacPacker.
    func second(at now: Double, since began: Double, until end: Double = .infinity, leftAt: UInt64? = nil) -> ToolProcess {
        if now >= end {
            mac.put(.file(size: leftAt ?? otherTotal), at: otherWritten)
            return macPacker([], pid: 501)
        }
        guard now >= began else { return macPacker([], pid: 501) }
        return macPacker([reading(other), writing(otherWritten, size: min(otherTotal, UInt64((now - began) * rate)))], pid: 501)
    }

    /// The Unarchiver with the rig's archives, as it takes them: it has
    /// them open from the start (the second too when `both`), extracts the
    /// first from 0 to `firstEnd` and the second from `secondStart` to
    /// `secondEnd`, each into a hidden folder where its result goes, and
    /// quits six seconds after the last.
    func unarchiving(at now: Double, both: Bool = true, firstEnd: Double = 20, secondStart: Double = 20.5,
                     secondEnd: Double = 50.5) -> [ToolProcess] {
        let temp = "/Users/me/Downloads/.TheUnarchiverTemp"
        var files = [reading(archive)] + (both ? [reading(other)] : [])
        if now < firstEnd {
            mac.put(.folder(items: 1), at: temp + "0")
            // (It reads the archive through for a second before it writes.)
            if now >= 1 {
                files.append(writing(temp + "0/big.bin", size: min(total, UInt64((now - 1) * Double(total) / (firstEnd - 1)))))
            }
        } else {
            mac.put(.missing, at: temp + "0")
            mac.put(.file(size: total), at: "/Users/me/Downloads/big.bin")
        }
        if both, now >= secondStart {
            if now < secondEnd {
                mac.put(.folder(items: 1), at: temp + "1")
                files.append(writing(temp + "1/album.flac",
                                     size: min(otherTotal, UInt64((now - secondStart) * Double(otherTotal) / (secondEnd - secondStart)))))
            } else {
                mac.put(.missing, at: temp + "1")
                mac.put(.file(size: otherTotal), at: "/Users/me/Downloads/album.flac")
            }
        }
        return now >= (both ? secondEnd : firstEnd) + 6 ? [] : [unarchiver(files)]
    }

    /// Keka with the rig's two archives, as it takes them: a helper each,
    /// from the start, each extracting into a folder Keka made for it
    /// beside the archive, the first until `firstEnd` and the second until
    /// `secondEnd`. A helper reads for a second before it writes; a tenth
    /// of a second after it is gone, its result is in place and its folder
    /// gone.
    func kekaExtracting(at now: Double, firstEnd: Double = 20, secondEnd: Double = 30) -> [ToolProcess] {
        var helpers: [ToolProcess] = []
        let jobs: [(String, String, String, UInt64, Double, Int32)] = [
            (archive, "photos", "big.bin", total, firstEnd, 801),
            (other, "music", "album.flac", otherTotal, secondEnd, 802),
        ]
        for (path, name, item, size, end, pid) in jobs {
            let work = "/Users/me/Downloads/\(name).kextraction"
            if now < end {
                mac.put(.folder(items: 1), at: work)
                var files = [reading(path)]
                if now >= 1 {
                    files.append(writing(work + "/Operation/" + item, size: min(size, UInt64((now - 1) * Double(size) / (end - 1)))))
                }
                helpers.append(kekaHelper(files, pid: pid))
            } else if now >= end + 0.1 {
                mac.put(.missing, at: work)
                mac.put(.file(size: size), at: "/Users/me/Downloads/" + item)
            }
        }
        return helpers
    }

    /// Steps the plugin every tenth of a second with what is open at each
    /// moment.
    mutating func run(from start: Double, to end: Double, _ processes: (Double) -> [ToolProcess]) throws {
        var tenth = Int((start * 10).rounded())
        while Double(tenth) / 10 <= end + 0.0001 {
            let now = Double(tenth) / 10
            lookout.processes = processes(now)
            _ = try plugin.step(now: now, incoming: [])
            tenth += 1
        }
    }

    /// MacPacker extracting the archive, at its rate, from `began`.
    func extracting(at now: Double, since began: Double = 0) {
        let size = min(total, UInt64(max(0, now - began) * rate))
        lookout.processes = [macPacker([reading(archive), writing(written, size: size)])]
    }

    /// Steps the plugin every tenth of a second over a stretch of the extraction.
    mutating func run(from start: Double, to end: Double, since began: Double = 0) throws {
        var tenth = Int((start * 10).rounded())
        while Double(tenth) / 10 <= end + 0.0001 {
            let now = Double(tenth) / 10
            extracting(at: now, since: began)
            _ = try plugin.step(now: now, incoming: [])
            tenth += 1
        }
    }

    /// The extraction ends: MacPacker lets go of the archive, with the file
    /// whole (complete) or as far as it got (stopped short).
    func end(complete: Bool, written size: UInt64 = 1_200_000_000) {
        mac.put(.file(size: complete ? total : size), at: written)
        lookout.processes = [macPacker([])]
    }

    var kinds: [LakeMessage.Kind] { link.sent.map(\.type) }
}

private func text(_ component: Component?) -> String? {
    if case .text(let text, _)? = component { text } else { nil }
}

/// The card's life, as the plugin tells it to DynamicLake.
struct PluginTests {
    // MARK: Which extractions get a card (the setting "Minimum Duration")

    @Test func anExtractionShorterThanTheMinimumShowsNothingAtAll() throws {
        // 500 MB at 100 MB a second: five seconds, and ten is the least.
        var rig = Rig(total: 500_000_000)
        try rig.run(from: 0, to: 4.9)
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 5, incoming: [])
        _ = try rig.plugin.step(now: 30, incoming: [])
        #expect(rig.link.sent.isEmpty, "no pill, no card, not even Complete")
        // The log still says what happened.
        #expect(rig.notes.log.contains { $0.contains("photos.zip: complete") })
        #expect(rig.notes.log.contains { $0.contains("card") } == false)
    }

    /// The same when its index takes a while to be read (very many items,
    /// a compressed tar): that time isn't the extraction's, and what was
    /// written meanwhile says nothing of its speed. Seen on a real
    /// Mac (12 Oct): an extraction was expected to take 475 s on a speed
    /// of a twentieth of the true one.
    @Test func aSlowIndexDoesNotMakeAShortExtractionLookLong() throws {
        var rig = Rig(total: 500_000_000)
        rig.mac.indexReadSeconds = 1.4
        // The first look at 0; the index is read by 1.4, when 140 MB are
        // written already, and the plugin looks again from then. Five
        // seconds in all, as above.
        rig.extracting(at: 0)
        rig.mac.put(.file(size: 140_000_000), at: rig.written)
        _ = try rig.plugin.step(now: 0, incoming: [])
        try rig.run(from: 1.4, to: 4.9)
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 5, incoming: [])
        _ = try rig.plugin.step(now: 30, incoming: [])
        #expect(rig.link.sent.isEmpty, "no pill, no card")
        #expect(rig.notes.log.contains { $0.contains("card") } == false)
    }

    /// Decided on 12 Oct: an extraction that is long enough shows from its
    /// start, not once it has lasted that long.
    @Test func anExtractionExpectedToTakeLongEnoughShowsAMomentAfterItBegins() throws {
        var rig = Rig()
        // The first readings of a speed are too rough to go by.
        try rig.run(from: 0, to: 1.4)
        #expect(rig.link.sent.isEmpty)
        try rig.run(from: 1.5, to: 1.5)
        let message = try #require(rig.link.sent.first)
        #expect(rig.link.sent.count == 1)
        #expect(message.type == .create)
        #expect(message.activityID == "extraction-1")
        #expect(message.title == "Extraction")
        #expect(message.priority == "normal")
        #expect(message.size == "small")
        #expect(message.presentSneakPeek == nil)
        let surfaces = try #require(message.surfaces)
        // Its first seconds: the archive box; the capsule has the type at once.
        #expect(surfaces.pillLeft == .picture(base64: try #require(rig.pictures.base64(.box))))
        #expect(surfaces.capsule == .picture(base64: try #require(rig.pictures.base64(.type("zip")))))
        #expect(surfaces.pillRight == .ring(value: 0.075, tint: "blue"))
        #expect(surfaces.peekLeft == .button(title: "Show in Finder", symbol: "folder.fill", actionID: "show:extraction-1", tint: "blue"))
        // (Too early for a time left: the speed stands in for it.)
        #expect(text(surfaces.peekCenter) == "0.15/2.00GB · 100 MB/s")
        #expect(surfaces.peekRight == .text("7%", style: "numeric"))
        #expect(rig.notes.log.last == "photos.zip: its card is shown (expected to take about 20 s, and 10 s is the least)")
    }

    @Test func anExtractionThatTurnsOutLongerShowsAfterAll() throws {
        // 800 MB: eight seconds at the rate it starts with, so no card…
        var rig = Rig(total: 800_000_000)
        try rig.run(from: 0, to: 4)
        #expect(rig.link.sent.isEmpty)
        // …but then it slows to a tenth of that: it will take far longer.
        for tenth in 41...60 {
            let now = Double(tenth) / 10
            let size = UInt64(400_000_000 + (now - 4) * 10_000_000)
            rig.lookout.processes = [macPacker([reading(rig.archive), writing(rig.written, size: size)])]
            _ = try rig.plugin.step(now: now, incoming: [])
        }
        #expect(rig.kinds.first == .create)
        #expect(rig.notes.log.contains { $0.contains("its card is shown (expected to take about") })
    }

    @Test func withoutATotalACardShowsOnceTheMinimumHasPassed() throws {
        // Nothing to work a length out from: only time tells.
        var rig = Rig()
        rig.mac.setIndexFailure(.locked, for: rig.archive)
        try rig.run(from: 0, to: 9.9)
        #expect(rig.link.sent.isEmpty)
        try rig.run(from: 10, to: 10)
        #expect(rig.kinds == [.create])
        #expect(rig.link.sent.first?.surfaces?.pillRight == .ring(value: nil, tint: "blue"))
        #expect(rig.notes.log.last == "photos.zip: its card is shown (it has lasted 10 s)")
    }

    @Test func withTheMinimumAtZeroEveryExtractionShowsAtOnce() throws {
        var rig = Rig(total: 500_000_000, settings: #"{"values":{"minimumDuration":0}}"#)
        try rig.run(from: 0, to: 0)
        #expect(rig.kinds == [.create])
        #expect(rig.notes.log.last == "photos.zip: its card is shown (every extraction shows)")
        // And a short one gets its Complete too.
        try rig.run(from: 0.1, to: 4.9)
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 5, incoming: [])
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "Complete • photos.zip")
    }

    @Test func theMinimumIsTheSettings() throws {
        // Twenty seconds of extraction, and thirty asked for: nothing.
        var rig = Rig(settings: #"{"values":{"minimumDuration":30}}"#)
        try rig.run(from: 0, to: 19.9)
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        #expect(rig.link.sent.isEmpty)
    }

    @Test func aCardThatWasShownStaysEvenIfTheExtractionEndsSooner() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 3)                       // expected: twenty seconds
        #expect(rig.kinds.first == .create)
        // It speeds up and is over at six seconds: its card goes on to Complete.
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 6, incoming: [])
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "Complete • photos.zip")
    }

    // MARK: A card's life

    @Test func aCardIsBroughtUpToDateWithoutFloodingDynamicLake() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 7.5)
        // Six seconds of card, looked at sixty times: an update when the
        // text is due to change (the time left, every second) and otherwise
        // at most every 0.6 s. About one a second, which is what DynamicLake
        // is meant to be sent.
        let updates = rig.link.sent.dropFirst()
        #expect(updates.allSatisfy { $0.type == .update && $0.activityID == "extraction-1" && $0.presentSneakPeek == nil })
        #expect((5...12).contains(updates.count), "\(updates.count) updates in six seconds")
        // Four seconds after the card came, the box gives way to the type.
        let zip = Component.picture(base64: try #require(rig.pictures.base64(.type("zip"))))
        #expect(rig.link.sent.last?.surfaces?.pillLeft == zip)
        // (The last one sent: at 7 seconds, when the time left last changed.)
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "0.70/2.00GB · 13 seconds")
    }

    @Test func theSameFaceIsNotSentTwice() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 15)
        let before = rig.link.sent.count
        // Nothing is written for a while: the amounts stand still. (The
        // time left, counted from the last readings, may still tick.)
        for tenth in 0..<20 {
            rig.extracting(at: 15)
            _ = try rig.plugin.step(now: 15.1 + Double(tenth) / 10, incoming: [])
        }
        let after = rig.link.sent.dropFirst(before)
        #expect(Set(after.map { text($0.surfaces?.peekCenter) }).count == after.count, "each update says something new")
    }

    @Test func completeOpensTheSneakPeekAndTheCardGoesWithIt() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 19.9)
        rig.end(complete: true)
        let sentBefore = rig.link.sent.count
        _ = try rig.plugin.step(now: 20, incoming: [])
        #expect(rig.link.sent.count == sentBefore + 1)
        let message = try #require(rig.link.sent.last)
        #expect(message.type == .update)
        // "Remain Visible" at 0: the sneak peek is asked for a little longer
        // than the card stays (5 s), so that it doesn't close first.
        #expect(message.presentSneakPeek == 7)
        // The card takes the main place to say it: beside another app's
        // activity (music, say) it would be the capsule, where DynamicLake
        // opens no sneak peek.
        #expect(message.priority == "high")
        let surfaces = try #require(message.surfaces)
        #expect(surfaces.pillRight == .picture(base64: try #require(rig.pictures.base64(.done))))
        #expect(text(surfaces.peekCenter) == "Complete • photos.zip")
        #expect(surfaces.peekRight == .button(title: "Open", symbol: "arrow.up.forward.app.fill", actionID: "open:extraction-1", tint: "blue"))
        #expect(rig.notes.log.last == "photos.zip: Complete is shown, its sneak peek open for 7 s")

        // A sneak peek asked for while the card takes the main place is
        // dropped: it is asked for once more, a moment later, as it is.
        _ = try rig.plugin.step(now: 20.25, incoming: [])
        #expect(rig.link.sent.count == sentBefore + 2)
        #expect(rig.link.sent.last?.presentSneakPeek == 7)
        #expect(rig.link.sent.last?.priority == nil)
        #expect(rig.link.sent.last?.surfaces == surfaces)

        // It stays five seconds, then goes, sneak peek and all: dismissed,
        // it leaves the main place to whatever comes next.
        _ = try rig.plugin.step(now: 25.2, incoming: [])
        #expect(rig.link.sent.count == sentBefore + 2)
        _ = try rig.plugin.step(now: 25.25, incoming: [])
        #expect(rig.link.sent.last == .dismiss("extraction-1"))
        #expect(rig.notes.log.last == "photos.zip: its card has had its time and goes")
        // And nothing more is ever sent for it.
        _ = try rig.plugin.step(now: 40, incoming: [])
        #expect(rig.link.sent.count == sentBefore + 3)
    }

    @Test func withRemainVisibleThePillStaysAfterItsSneakPeek() throws {
        var rig = Rig(settings: #"{"values":{"remainVisible":10,"sneakPeekDuration":"3 s"}}"#)
        try rig.run(from: 0, to: 19.9)
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        #expect(rig.link.sent.last?.presentSneakPeek == 3, "the sneak peek's own time, no more: the pill outlives it")
        _ = try rig.plugin.step(now: 20.25, incoming: [])      // (asked for once more: the time counts from here)
        _ = try rig.plugin.step(now: 33.2, incoming: [])
        #expect(rig.link.sent.last?.type == .update)
        _ = try rig.plugin.step(now: 33.25, incoming: [])
        #expect(rig.link.sent.last == .dismiss("extraction-1"))
    }

    @Test func theLongestSneakPeekThereIsEndsTheCardJustBeforeItWouldClose() throws {
        var rig = Rig(settings: #"{"values":{"sneakPeekDuration":"10 s"}}"#)
        try rig.run(from: 0, to: 19.9)
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        #expect(rig.link.sent.last?.presentSneakPeek == 10)
        _ = try rig.plugin.step(now: 20.25, incoming: [])      // (asked for once more: the time counts from here)
        _ = try rig.plugin.step(now: 29.95, incoming: [])
        #expect(rig.link.sent.last?.type == .update)
        _ = try rig.plugin.step(now: 30, incoming: [])
        #expect(rig.link.sent.last == .dismiss("extraction-1"))
    }

    @Test func aSneakPeekIsNeverAskedForInTheSameBreathAsItsCard() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 1.5)                     // the card is made at 1.5
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 1.6, incoming: [])
        // Complete goes up at once, without the sneak peek (DynamicLake
        // would ignore it so soon after the card was made)…
        #expect(rig.kinds == [.create, .update])
        #expect(rig.link.sent.last?.presentSneakPeek == nil)
        // …which is asked for 0.2 s after the card was made.
        _ = try rig.plugin.step(now: 1.7, incoming: [])
        #expect(rig.kinds == [.create, .update, .update])
        #expect(rig.link.sent.last?.presentSneakPeek == 7)
        // The card stays its usual time from then.
        _ = try rig.plugin.step(now: 6.6, incoming: [])
        #expect(rig.kinds.last == .update)
        _ = try rig.plugin.step(now: 6.7, incoming: [])
        #expect(rig.kinds.last == .dismiss)
    }

    // MARK: Stopped short, stalled, an end that can't be told

    @Test func anExtractionStoppedShortSaysSoAndNeverClaimsComplete() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 12)
        rig.end(complete: false)                          // MacPacker leaves what it had written
        _ = try rig.plugin.step(now: 12.1, incoming: [])
        let message = try #require(rig.link.sent.last)
        #expect(message.type == .update)
        #expect(message.presentSneakPeek == 7)
        let surfaces = try #require(message.surfaces)
        #expect(surfaces.pillLeft == .picture(base64: try #require(rig.pictures.base64(.type("zip")))))
        #expect(surfaces.pillRight == .picture(base64: try #require(rig.pictures.base64(.stopped))))
        #expect(text(surfaces.peekCenter) == "Stopped • photos.zip")
        // Something was left: Show in Finder is there to show it. No Open.
        #expect(surfaces.peekLeft == .button(title: "Show in Finder", symbol: "folder.fill", actionID: "show:extraction-1", tint: "blue"))
        #expect(surfaces.peekRight == nil)
        #expect(rig.link.sent.contains { text($0.surfaces?.peekCenter)?.contains("Complete") == true } == false)
        #expect(rig.notes.log.contains { $0.contains("photos.zip: stopped short at 60 %") })
        #expect(rig.notes.log.last == "photos.zip: Stopped is shown, its sneak peek open for 7 s")

        #expect(message.priority == "high")

        // It stays as long as a finished card does, then goes.
        _ = try rig.plugin.step(now: 12.35, incoming: [])      // (asked for once more: the time counts from here)
        _ = try rig.plugin.step(now: 17.3, incoming: [])
        #expect(rig.kinds.last == .update)
        _ = try rig.plugin.step(now: 17.35, incoming: [])
        #expect(rig.link.sent.last == .dismiss("extraction-1"))
        #expect(rig.kinds.count { $0 == .dismiss } == 1)
    }

    @Test func anExtractionThatLeftFilesOutSaysStoppedNotComplete() throws {
        // MacPacker goes through a damaged archive to its end, leaving out
        // what it can't read (a run of 12 Oct).
        var rig = Rig()
        rig.mac.setIndex([ArchiveEntry(path: "album/one.bin", size: 1_000_000_000), ArchiveEntry(path: "album/damaged.bin", size: 500),
                          ArchiveEntry(path: "album/two.bin", size: 1_000_000_000)], for: rig.archive)
        for tenth in 0...150 {
            let now = Double(tenth) / 10
            rig.lookout.processes = [macPacker([reading(rig.archive), writing("/Users/me/Desktop/album/one.bin", size: UInt64(now * 60_000_000))])]
            _ = try rig.plugin.step(now: now, incoming: [])
        }
        rig.mac.put(.file(size: 1_000_000_000), at: "/Users/me/Desktop/album/one.bin")
        rig.mac.put(.file(size: 1_000_000_000), at: "/Users/me/Desktop/album/two.bin")
        rig.mac.put(.folder(items: 2), at: "/Users/me/Desktop/album")
        rig.lookout.processes = [macPacker([])]
        _ = try rig.plugin.step(now: 15.1, incoming: [])
        let surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(text(surfaces.peekCenter) == "Stopped • photos.zip")
        #expect(surfaces.peekLeft == CardFace.showButton("extraction-1"), "what was extracted is there to be shown")
        #expect(rig.notes.log.contains("photos.zip: not complete after 15.1 s: 1 of its 3 files is missing or cut short; "
            + "at /Users/me/Desktop/album"))
    }

    @Test func showInFinderOnAStoppedCardShowsWhatWasLeftAndOpenDoesNothing() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 12)
        rig.end(complete: false)
        _ = try rig.plugin.step(now: 12.1, incoming: [])
        _ = try rig.plugin.step(now: 13, incoming: [
            .action(LakeAction(activityID: "extraction-1", actionID: "show:extraction-1")),
            .action(LakeAction(activityID: "extraction-1", actionID: "open:extraction-1")),
        ])
        #expect(rig.notes.revealed == [[rig.written]])
        #expect(rig.notes.opened.isEmpty)
    }

    @Test func aStoppedCardHasNoButtonWhenNothingWasLeft() throws {
        // Archive Utility takes everything away on a cancel.
        var rig = Rig()
        let archive = "/Users/me/Downloads/album.zip"
        let placeholder = "/Users/me/Downloads/album"
        rig.mac.setIndex([ArchiveEntry(path: "album/one.bin", size: 1_000_000_000), ArchiveEntry(path: "album/two.bin", size: 1_000_000_000)],
                         for: archive)
        rig.mac.put(.folder(items: 0), at: placeholder)
        for tenth in 0...120 {
            let now = Double(tenth) / 10
            rig.lookout.processes = [helper([reading(archive), writing(helperFolder + "/album/one.bin", size: UInt64(now * 50_000_000))])]
            _ = try rig.plugin.step(now: now, incoming: [])
        }
        rig.mac.put(.missing, at: placeholder)            // cancelled: the placeholder is taken away
        rig.lookout.processes = []
        for tenth in 121...126 {
            _ = try rig.plugin.step(now: Double(tenth) / 10, incoming: [])
        }
        let surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(text(surfaces.peekCenter) == "Stopped • album.zip")
        #expect(surfaces.peekLeft == nil)
        #expect(surfaces.peekRight == nil)
    }

    @Test func anEndThatCannotBeToldTakesTheCardAwayQuietly() throws {
        // No index: whether MacPacker got to the end can't be known.
        var rig = Rig()
        rig.mac.setIndexFailure(.locked, for: rig.archive)
        try rig.run(from: 0, to: 12)
        #expect(rig.kinds == [.create] + Array(repeating: .update, count: rig.kinds.count - 1))
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 12.1, incoming: [])
        #expect(rig.link.sent.last == .dismiss("extraction-1"))
        let lines = rig.link.sent.compactMap { text($0.surfaces?.peekCenter) }
        #expect(lines.contains { $0.contains("Complete") || $0.contains("Stopped") } == false)
        #expect(rig.notes.log.last == "photos.zip: its card is taken away (whether the extraction got to its end can't be told)")
    }

    /// Decided on 12 Oct: an archive without an index shows how far it has
    /// been read, in the archive's own size.
    @Test func anArchiveWithoutAnIndexShowsHowFarItHasBeenRead() throws {
        var rig = Rig()
        let archive = "/Users/me/Downloads/sources.tar.gz"
        let size: UInt64 = 600_000_000
        rig.mac.setIndexFailure(.notAnArchive, for: archive)
        rig.mac.put(.folder(items: 0), at: "/Users/me/Downloads/project")
        for tenth in 0...100 {
            let now = Double(tenth) / 10
            rig.lookout.processes = [helper([reading(archive, size: size), reading(archive, size: size, at: UInt64(1_000_000 + now * 20_000_000)),
                                             writing(helperFolder + "/project/a.c", size: 300)])]
            _ = try rig.plugin.step(now: now, incoming: [])
        }
        // Its length can be worked out: its card comes at once, not after ten seconds.
        #expect(rig.notes.log.contains { $0.hasPrefix("sources.tar.gz: its card is shown (expected to take about 30 s") })
        let surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(surfaces.pillRight == .ring(value: 0.335, tint: "blue"))
        #expect(text(surfaces.peekCenter) == "201/600MB · 20 seconds")
        #expect(surfaces.peekRight == .text("33%", style: "numeric"))
        #expect(surfaces.capsule == .picture(base64: try #require(rig.pictures.base64(.type("gz")))))
        // And it ends as any other does.
        rig.mac.put(.folder(items: 5), at: "/Users/me/Downloads/project")
        rig.lookout.processes = [helper([])]
        _ = try rig.plugin.step(now: 10.1, incoming: [])
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "Complete • sources.tar.gz")
    }

    @Test func anExtractionThatWritesNothingForFifteenSecondsSaysStalledThenCarriesOn() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 5)
        // The tool goes on holding the archive but writes nothing more.
        for tenth in 51...199 {
            rig.extracting(at: 5)
            _ = try rig.plugin.step(now: Double(tenth) / 10, incoming: [])
        }
        #expect(rig.link.sent.contains { text($0.surfaces?.peekCenter)?.contains("Stalled") == true } == false, "not before fifteen seconds")
        for tenth in 200...210 {
            rig.extracting(at: 5)
            _ = try rig.plugin.step(now: Double(tenth) / 10, incoming: [])
        }
        let stalled = try #require(rig.link.sent.last?.surfaces)
        #expect(text(stalled.peekCenter) == "Stalled • photos.zip")
        #expect(stalled.pillRight == .picture(base64: try #require(rig.pictures.base64(.stalled))))
        // How far it got, and Show in Finder, stay.
        #expect(stalled.peekRight == .text("25%", style: "numeric"))
        #expect(stalled.peekLeft == CardFace.showButton("extraction-1"))
        #expect(rig.link.sent.allSatisfy { $0.presentSneakPeek == nil }, "a stall doesn't open the sneak peek")
        #expect(rig.notes.log.contains("photos.zip: stalled: nothing written for 15 s (at 25 %)"))

        // It writes again: the card is the extracting one again.
        for tenth in 211...230 {
            let now = Double(tenth) / 10
            rig.lookout.processes = [macPacker([reading(rig.archive), writing(rig.written, size: UInt64(500_000_000 + (now - 21) * 100_000_000))])]
            _ = try rig.plugin.step(now: now, incoming: [])
        }
        let again = try #require(rig.link.sent.last?.surfaces)
        #expect(again.pillRight != stalled.pillRight)
        // The speed is measured afresh after the standstill: no time left
        // of hours, the speed of now, until a time left can be told again.
        let all = rig.link.sent.compactMap { text($0.surfaces?.peekCenter) }
        let since = try #require(all.lastIndex { $0.contains("Stalled") })
        let lines = all.suffix(from: since + 1)
        #expect(lines.isEmpty == false)
        #expect(lines.allSatisfy { $0.hasSuffix("· 100 MB/s") }, "\(lines)")
        #expect(rig.notes.log.contains { $0.hasPrefix("photos.zip: writing again, after 16.") })
    }

    @Test func withoutSneakPeeksOnOfferNoneIsAskedFor() throws {
        var rig = Rig(features: [])
        try rig.run(from: 0, to: 19.9)
        // Without digits that change in place either: the bare number.
        #expect(rig.link.sent.first?.surfaces?.peekRight == .text("7", style: "compact"))
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "Complete • photos.zip")
        #expect(rig.link.sent.allSatisfy { $0.presentSneakPeek == nil })
        _ = try rig.plugin.step(now: 25, incoming: [])
        #expect(rig.kinds.last == .dismiss)
    }

    @Test func aLongNameStaysStillThenScrollsInTheOpenSneakPeek() throws {
        var rig = Rig()
        let long = "/Users/me/Downloads/Some.Very.Long.Archive.Name.2026.part1.rar"
        rig.mac.setIndex([ArchiveEntry(path: "big.bin", size: rig.total)], format: .rar4, for: long)
        func look(_ now: Double) {
            rig.lookout.processes = [macPacker([reading(long), writing(rig.written, size: UInt64(now * 100_000_000))])]
        }
        for tenth in 0...199 {
            look(Double(tenth) / 10)
            _ = try rig.plugin.step(now: Double(tenth) / 10, incoming: [])
        }
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        let held = try #require(text(rig.link.sent.last?.surfaces?.peekCenter))
        #expect(held.hasPrefix("Complete • Some.Very"))
        #expect(held.hasSuffix("…"))
        _ = try rig.plugin.step(now: 20.25, incoming: [])      // (asked for once more: the line stays still from here)
        let count = rig.link.sent.count
        _ = try rig.plugin.step(now: 23.2, incoming: [])
        #expect(rig.link.sent.count == count)
        // Three seconds on, the whole line, to scroll. The sneak peek is
        // asked for again for the time it has left: DynamicLake only shows
        // a new text in an open sneak peek when it is.
        _ = try rig.plugin.step(now: 23.25, incoming: [])
        let scrolling = try #require(rig.link.sent.last)
        #expect(text(scrolling.surfaces?.peekCenter) == "\u{2800}Complete • Some.Very.Long.Archive.Name.2026.part1.rar")
        #expect(scrolling.presentSneakPeek == 4)
        _ = try rig.plugin.step(now: 25.25, incoming: [])
        #expect(rig.kinds.last == .dismiss)
    }

    // MARK: The buttons

    @Test func showInFinderShowsTheItemWhereItIs() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 12)
        // While it extracts, nothing of that name may be there yet: the folder it goes into.
        _ = try rig.plugin.step(now: 12.1, incoming: [.action(LakeAction(activityID: "extraction-1", actionID: "show:extraction-1"))])
        #expect(rig.notes.revealed == [["/Users/me/Desktop"]])
        // Once it is there, the item itself, selected.
        rig.mac.put(.file(size: 1_300_000_000), at: rig.written)
        _ = try rig.plugin.step(now: 13, incoming: [.action(LakeAction(activityID: "extraction-1", actionID: "show:extraction-1"))])
        #expect(rig.notes.revealed.last == [rig.written])
        #expect(rig.notes.log.contains("photos.zip: Show in Finder"))
        #expect(rig.notes.opened.isEmpty)
    }

    @Test func openOpensTheFinishedItemAndNothingBeforeThat() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 12)
        let open = LakeIncoming.action(LakeAction(activityID: "extraction-1", actionID: "open:extraction-1"))
        // (The button isn't on the card yet; a press that came anyway does nothing.)
        _ = try rig.plugin.step(now: 12.1, incoming: [open])
        #expect(rig.notes.opened.isEmpty)
        try rig.run(from: 12.2, to: 19.9)
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        _ = try rig.plugin.step(now: 21, incoming: [open])
        #expect(rig.notes.opened == [rig.written])
        #expect(rig.notes.log.contains("photos.zip: Open"))
    }

    @Test func openOnAnItemThatIsGoneOpensNothing() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 19.9)
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        rig.mac.put(.missing, at: rig.written)          // moved away meanwhile
        _ = try rig.plugin.step(now: 21, incoming: [.action(LakeAction(activityID: "extraction-1", actionID: "open:extraction-1"))])
        #expect(rig.notes.opened.isEmpty)
        #expect(rig.notes.log.last == "photos.zip: Open: the extracted item isn't there")
    }

    @Test func aPressForACardThatIsNotThereDoesNothing() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 12)
        _ = try rig.plugin.step(now: 12.1, incoming: [
            .action(LakeAction(activityID: "extraction-99", actionID: "show:extraction-99")),
            .action(LakeAction(activityID: "extraction-1", actionID: "delete:extraction-1")),
        ])
        #expect(rig.notes.revealed.isEmpty)
        #expect(rig.notes.opened.isEmpty)
    }

    // MARK: Things going wrong

    @Test func aMessageDynamicLakeRefusesGoesToTheLog() throws {
        var rig = Rig()
        _ = try rig.plugin.step(now: 0, incoming: [.refusal(#"{"ok":false,"error":"Invalid field 'text'"}"#)])
        #expect(rig.notes.log.contains(#"DynamicLake refused a message: {"ok":false,"error":"Invalid field 'text'"}"#))
    }

    @Test func dynamicLakeGoingAwayEndsTheStep() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 9.9)
        rig.link.isClosed = true
        rig.extracting(at: 10)
        #expect(throws: LakeError.closed) {
            _ = try rig.plugin.step(now: 10, incoming: [])
        }
    }

    @Test func runByHandThePluginWatchesAndShowsNothing() throws {
        var rig = Rig(connected: false)
        rig.lookout.basePause = 1
        try rig.run(from: 0, to: 12)
        rig.end(complete: true)
        #expect(try rig.plugin.step(now: 12.1, incoming: []) == 1)
        #expect(rig.link.sent.isEmpty)
        #expect(rig.notes.log.contains { $0.contains("photos.zip: complete") })
    }

    // MARK: Not too fast for DynamicLake

    /// Seen on a real Mac (12 Oct): the time left had counted down to
    /// `1 second` and the extraction went on. The plugin sent an update at
    /// every look, some fifty a second; DynamicLake refused them ("Update
    /// rate limit exceeded"), and with them the sneak peek of the card that
    /// said `Complete`. Replayed as the loop runs: each step comes after
    /// the pause the one before asked for.
    @Test func withTheTimeLeftRunOutTheCardIsNotSentAtEveryLook() throws {
        var rig = Rig()
        // 100 MB a second up to 1.95 GB of the 2: half a second left.
        try rig.run(from: 0, to: 19.5)
        let before = rig.link.sent.count
        // Then it crawls: a megabyte more at every look, for three seconds.
        var now = 19.5
        var steps = 0
        var shortest = Double.infinity
        while now < 22.5 {
            steps += 1
            let size = UInt64(1_950_000_000 + (now - 19.5) * 10_000_000)
            rig.lookout.processes = [macPacker([reading(rig.archive), writing(rig.written, size: size)])]
            let pause = try rig.plugin.step(now: now, incoming: [])
            shortest = min(shortest, pause)
            now += pause
        }
        let sent = rig.link.sent.count - before
        #expect(sent <= 12, "\(sent) updates in three seconds")
        #expect(shortest >= 0.05, "the plugin came back after \(shortest) s")
        #expect(steps <= 40, "\(steps) looks in three seconds")
    }

    /// Whatever is due, two updates of a card that counts up are a quarter
    /// of a second apart at least.
    @Test func updatesAreNeverCloserTogetherThanDynamicLakeTakes() throws {
        var rig = Rig(settings: #"{"values":{"extractionDetails":"Both","minimumDuration":0}}"#)
        var times: [Double] = []
        var seen = 0
        var now = 0.0
        while now < 12 {
            rig.extracting(at: now)
            _ = try rig.plugin.step(now: now, incoming: [])
            if rig.link.sent.count > seen {
                times.append(now)
                seen = rig.link.sent.count
            }
            now += 0.02
        }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= 0.249 }, "\(gaps.min() ?? 0)")
        #expect(times.count >= 12, "and it is still kept up to date")
    }

    /// Seen on a real Mac (12 Oct): at the end of an archive of
    /// 150,000 files, looking at each of them took half a second, and the
    /// sneak peek was asked for twice within a millisecond. The second
    /// asking comes a fifth of a second after the first was sent.
    @Test func aLongLookAtTheEndDoesNotBringTheTwoAskingsTogether() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 19.9)
        rig.end(complete: true)
        // Each question about a file takes a tenth of a second here: the
        // look that finds the end lasts a few tenths.
        rig.mac.fileStateSeconds = 0.1
        let clock = rig.mac.clock
        let before = rig.link.sent.count
        _ = try rig.plugin.step(now: 20, incoming: [])
        let lasted = rig.mac.clock - clock
        rig.mac.fileStateSeconds = 0
        #expect(lasted >= 0.3)
        #expect(rig.link.sent.count == before + 1)
        #expect(rig.link.sent.last?.presentSneakPeek == 7)
        // The loop is back right after that look: not yet.
        _ = try rig.plugin.step(now: 20 + lasted + 0.05, incoming: [])
        #expect(rig.link.sent.count == before + 1, "not again in the same breath")
        _ = try rig.plugin.step(now: 20 + lasted + 0.21, incoming: [])
        #expect(rig.link.sent.count == before + 2)
        #expect(rig.link.sent.last?.presentSneakPeek == 7)
    }

    // MARK: Several extractions, one card (decided on 12 Oct 2026)

    @Test func aSecondExtractionJoinsTheCardAndTheirSizesAreAddedUp() throws {
        var rig = Rig()
        // 2 GB from 0 and 3 GB from 3, each at 100 MB a second.
        try rig.run(from: 0, to: 15) { [rig] now in [rig.first(at: now), rig.second(at: now, since: 3)] }
        #expect(rig.kinds.filter { $0 == .create }.count == 1, "the whole plugin is one activity")
        #expect(Set(rig.link.sent.map(\.activityID)) == ["extraction-1"])
        #expect(rig.notes.log.contains("music.rar: joins the card (expected to take about 30 s, and 10 s is the least): "
            + "it stands for 2 extractions now"))

        let surfaces = try #require(rig.link.sent.last?.surfaces)
        // Their number where the type was, in the pill and in the capsule.
        let two = Component.picture(base64: try #require(rig.pictures.base64(.type("2"))))
        #expect(surfaces.pillLeft == two)
        #expect(surfaces.capsule == two)
        // 1.5 GB of 2 and 1.2 GB of 3: one ring, one percentage, one pair
        // of amounts.
        let line = try #require(text(surfaces.peekCenter))
        #expect(line.hasPrefix("2.6") || line.hasPrefix("2.70"), "\(line)")
        #expect(line.contains("/5.00GB · "))
        #expect(["52%", "53%", "54%"].contains(text(surfaces.peekRight)), "\(String(describing: surfaces.peekRight))")
        // The time left is that of the one that finishes last (18 s), not
        // the first's (5 s), and no sum.
        #expect(line.hasSuffix("· 18 seconds") || line.hasSuffix("· 19 seconds"), "\(line)")
        #expect(surfaces.peekLeft == CardFace.showButton("extraction-1"))
        // Before the second joined, the card was the first's own.
        let before = try #require(rig.link.sent.last { text($0.surfaces?.peekCenter)?.contains("/2.00GB") == true }?.surfaces)
        #expect(before.capsule == .picture(base64: try #require(rig.pictures.base64(.type("zip")))))
    }

    @Test func oneThatIsOverStaysCountedAndTheCardSaysItAllAtTheEnd() throws {
        var rig = Rig()
        // The first is complete at 20; the second goes on until 33.
        try rig.run(from: 0, to: 25) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 3)] }
        #expect(rig.link.sent.allSatisfy { $0.presentSneakPeek == nil }, "nothing is said while another goes on")
        var surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(surfaces.pillLeft == .picture(base64: try #require(rig.pictures.base64(.type("2")))), "the number counts them all to the end")
        // 2 GB of 2, done, and 2.2 GB of 3.
        #expect(text(surfaces.peekCenter)?.contains("/5.00GB") == true)
        #expect(["83%", "84%"].contains(text(surfaces.peekRight)))

        try rig.run(from: 25.1, to: 33) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 3, until: 33)] }
        let message = try #require(rig.link.sent.last)
        #expect(message.type == .update)
        #expect(message.presentSneakPeek == 7)
        #expect(message.priority == "high")
        surfaces = try #require(message.surfaces)
        #expect(text(surfaces.peekCenter) == "2 Extractions Completed")
        #expect(surfaces.pillLeft == .picture(base64: try #require(rig.pictures.base64(.type("2")))))
        #expect(surfaces.pillRight == .picture(base64: try #require(rig.pictures.base64(.done))))
        // Show in Finder alone: there is no one item to open.
        #expect(surfaces.peekLeft == CardFace.showButton("extraction-1"))
        #expect(surfaces.peekRight == nil)
        #expect(rig.notes.log.last == "photos.zip, music.rar: 2 Extractions Completed is shown, its sneak peek open for 7 s")

        // Show in Finder shows every extracted item; Open does nothing.
        _ = try rig.plugin.step(now: 33.5, incoming: [
            .action(LakeAction(activityID: "extraction-1", actionID: "show:extraction-1")),
            .action(LakeAction(activityID: "extraction-1", actionID: "open:extraction-1")),
        ])
        #expect(rig.notes.revealed == [[rig.written, rig.otherWritten]])
        #expect(rig.notes.opened.isEmpty)

        // The one card stays its time and goes.
        _ = try rig.plugin.step(now: 38.6, incoming: [])
        #expect(rig.link.sent.last == .dismiss("extraction-1"))
        #expect(rig.kinds.filter { $0 == .dismiss }.count == 1)
    }

    @Test func oneThatStopsShortIsSaidAtTheEndNotWhenItHappens() throws {
        var rig = Rig()
        // The first is stopped at 12, with 1.2 GB of its 2 written.
        try rig.run(from: 0, to: 14) { [rig] now in
            [rig.first(at: now, until: 12, leftAt: 1_200_000_000), rig.second(at: now, since: 3)]
        }
        #expect(rig.notes.log.contains { $0.contains("photos.zip: stopped short at 60 %") })
        #expect(rig.link.sent.contains { text($0.surfaces?.peekCenter)?.contains("Stopped") == true } == false)
        #expect(rig.link.sent.allSatisfy { $0.presentSneakPeek == nil })
        // What it wrote stays counted, and there is no more of it to come:
        // 1.2 GB, and the second's 3.
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter)?.contains("/4.20GB") == true)

        try rig.run(from: 14.1, to: 33) { [rig] now in
            [rig.first(at: now, until: 12, leftAt: 1_200_000_000), rig.second(at: now, since: 3, until: 33)]
        }
        let surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(text(surfaces.peekCenter) == "1/2 Extractions Completed")
        #expect(surfaces.pillRight == .picture(base64: try #require(rig.pictures.base64(.stopped))), "never the green check")
        #expect(surfaces.peekLeft == CardFace.showButton("extraction-1"))
        #expect(surfaces.peekRight == nil)
        #expect(rig.notes.log.last == "photos.zip, music.rar: 1/2 Extractions Completed is shown, its sneak peek open for 7 s")
    }

    @Test func whenNoneGotToItsEndTheCardSaysSo() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 20) { [rig] now in
            [rig.first(at: now, until: 12, leftAt: 1_200_000_000), rig.second(at: now, since: 3, until: 20, leftAt: 1_700_000_000)]
        }
        let surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(text(surfaces.peekCenter) == "0/2 Extractions Completed")
        #expect(surfaces.pillRight == .picture(base64: try #require(rig.pictures.base64(.stopped))))
    }

    /// An extraction whose size can't be told counts in the number only,
    /// while one with a size runs; alone, it makes the ring spin. And its
    /// end can't be told: it is left out of what the card says.
    @Test func anExtractionWithoutASizeLeavesTheRingToTheOthersUntilItIsAlone() throws {
        var rig = Rig()
        rig.mac.setIndexFailure(.locked, for: rig.other)
        try rig.run(from: 0, to: 19.9) { [rig] now in [rig.first(at: now), rig.second(at: now, since: 3)] }
        #expect(rig.notes.log.contains("music.rar: joins the card (it has lasted 10 s): it stands for 2 extractions now"))
        var surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(surfaces.pillLeft == .picture(base64: try #require(rig.pictures.base64(.type("2")))))
        #expect(text(surfaces.peekCenter)?.contains("/2.00GB") == true, "the amounts are the first's alone")
        #expect(["98%", "99%"].contains(text(surfaces.peekRight)))

        // The first is complete: only the one without a size is left.
        try rig.run(from: 20, to: 25) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 3)] }
        surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(surfaces.pillRight == .ring(value: nil, tint: "blue"), "the ring spins")
        // All that the two have written (2 GB and 2.2), and the speed.
        let line = try #require(text(surfaces.peekCenter))
        #expect(line.hasPrefix("4.1") || line.hasPrefix("4.2"), "\(line)")
        #expect(line.contains("GB · "), "the amount alone, no total: \(line)")
        #expect(line.contains("/2.00GB") == false && line.contains("/5") == false)
        #expect(line.hasSuffix("· 100 MB/s"))
        #expect(surfaces.peekRight == .text("—", style: "numeric"))

        // It ends, and whether it got to its end can't be told: the card
        // says what it knows, the first one's `Complete`, with its Open.
        try rig.run(from: 25.1, to: 30) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 3, until: 30)] }
        surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(text(surfaces.peekCenter) == "Complete • photos.zip")
        #expect(surfaces.peekRight == CardFace.openButton("extraction-1"))
        #expect(rig.notes.log.contains("music.rar: left out of what the card says (whether the extraction got to its end can't be told)"))
    }

    /// Decided on 12 Oct: an extraction shorter than Minimum Duration that
    /// runs beside a long one is left out entirely.
    @Test func aShortExtractionBesideALongOneIsNeitherCountedNorAddedUp() throws {
        var rig = Rig()
        // The second holds 400 MB: over in four seconds.
        rig.mac.setIndex([ArchiveEntry(path: "album.flac", size: 400_000_000)], format: .rar4, for: rig.other)
        try rig.run(from: 0, to: 19.9) { [rig] now in
            [rig.first(at: now), rig.second(at: now, since: 5, until: 9, leftAt: 400_000_000)]
        }
        #expect(rig.notes.log.contains { $0.contains("music.rar: complete") })
        #expect(rig.notes.log.contains { $0.contains("joins the card") } == false)
        let zip = Component.picture(base64: try #require(rig.pictures.base64(.type("zip"))))
        #expect(rig.link.sent.dropFirst(40).allSatisfy { $0.surfaces?.pillLeft == zip })
        #expect(rig.link.sent.allSatisfy { text($0.surfaces?.peekCenter)?.contains("/2.00GB") == true })
        try rig.run(from: 20, to: 20) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 5, until: 9)] }
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "Complete • photos.zip")
        #expect(rig.link.sent.last?.surfaces?.peekRight == CardFace.openButton("extraction-1"))
    }

    @Test func anExtractionThatBeginsWhenAllAreOverTakesTheCardOverAtOnce() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 21) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 22)] }
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "Complete • photos.zip")
        let before = rig.link.sent.count
        // The second begins at 22 and is found long enough at 23.5, with
        // `Complete` still up: the card is its own from then.
        try rig.run(from: 21.1, to: 23.5) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 22)] }
        let since = Array(rig.link.sent.dropFirst(before))
        // The card had the main place for what it said: given back first.
        #expect(since.first == .priority("extraction-1", "low"))
        let progress = try #require(since.last?.surfaces)
        #expect(text(progress.peekCenter)?.contains("/3.00GB") == true)
        #expect(progress.capsule == .picture(base64: try #require(rig.pictures.base64(.type("rar")))))
        #expect(rig.kinds.filter { $0 == .create }.count == 1)
        #expect(rig.kinds.contains(.dismiss) == false)
        #expect(rig.notes.log.last == "music.rar: the card is taken over (expected to take about 30 s, and 10 s is the least)")
        // Its usual priority again a moment later.
        try rig.run(from: 23.6, to: 24.4) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 22)] }
        #expect(rig.link.sent.contains(.priority("extraction-1", "normal")))

        // At its end the card speaks of it alone: the first was said.
        try rig.run(from: 24.5, to: 52) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 22, until: 52)] }
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "Complete • music.rar")
    }

    @Test func severalAreStalledOnlyWhenNoneOfThemWrites() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 8) { [rig] now in [rig.first(at: now), rig.second(at: now, since: 3)] }
        // The first writes nothing more; the second goes on: no standstill.
        try rig.run(from: 8.1, to: 26) { [rig] now in [rig.first(at: 8), rig.second(at: now, since: 3)] }
        #expect(rig.link.sent.contains { text($0.surfaces?.peekCenter)?.contains("Stalled") == true } == false)
        // Then the second stops writing too.
        try rig.run(from: 26.1, to: 42) { [rig] _ in [rig.first(at: 8), rig.second(at: 26, since: 3)] }
        let stalled = try #require(rig.link.sent.last?.surfaces)
        #expect(text(stalled.peekCenter) == "Stalled • 2 Extractions")
        #expect(stalled.pillRight == .picture(base64: try #require(rig.pictures.base64(.stalled))))
    }

    @Test func showInFinderWhileSeveralAreUnderWayShowsWhatIsThereOfEach() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 14) { [rig] now in [rig.first(at: now), rig.second(at: now, since: 3)] }
        rig.mac.put(.file(size: 1), at: rig.written)
        _ = try rig.plugin.step(now: 14.1, incoming: [.action(LakeAction(activityID: "extraction-1", actionID: "show:extraction-1"))])
        // The first's file is there; of the second nothing yet: its folder.
        #expect(rig.notes.revealed == [[rig.written, "/Users/me/Music"]])
        #expect(rig.notes.log.last == "photos.zip, music.rar: Show in Finder")
    }

    /// Decided on 12 Oct: the number of extractions shows even with
    /// File-Type Icons off. It is no file type.
    @Test func withFileTypeIconsOffTheNumberOfSeveralStillShows() throws {
        var rig = Rig(settings: #"{"values":{"fileTypeIcons":false}}"#)
        try rig.run(from: 0, to: 15) { [rig] now in [rig.first(at: now), rig.second(at: now, since: 3)] }
        let box = Component.picture(base64: try #require(rig.pictures.base64(.box)))
        let two = Component.picture(base64: try #require(rig.pictures.base64(.type("2"))))
        // One alone keeps the archive box, as the setting says…
        let alone = try #require(rig.link.sent.first?.surfaces)
        #expect(alone.pillLeft == box && alone.capsule == box)
        // …and from the moment there are two, their number.
        let both = try #require(rig.link.sent.last?.surfaces)
        #expect(both.pillLeft == two && both.capsule == two)
        #expect(rig.link.sent.allSatisfy { $0.surfaces?.pillLeft == box || $0.surfaces?.pillLeft == two })
        // And at the end.
        try rig.run(from: 15.1, to: 33) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 3, until: 33)] }
        #expect(rig.link.sent.last?.surfaces?.pillLeft == two)
    }

    // MARK: The Unarchiver, and its queue

    /// The Unarchiver has every archive it was given open from the start
    /// and takes them one after the other (a real Mac, 12 Oct): the
    /// one that waits is counted from the start, with its size.
    @Test func anArchiveThatWaitsForItsTurnIsCountedFromTheStart() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 10) { [rig] now in rig.unarchiving(at: now) }
        #expect(rig.notes.log.contains { $0.hasPrefix("music.rar: The Unarchiver has it open, to extract it: 3.00 GB in 1 file") })
        #expect(rig.notes.log.contains { $0.hasPrefix("music.rar: joins the card (it waits for its turn, and is expected to take about 2") })
        var surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(surfaces.pillLeft == .picture(base64: try #require(rig.pictures.base64(.type("2")))))
        // About 0.95 GB of the first's 2, and the second's 3 still to come.
        let line = try #require(text(surfaces.peekCenter))
        #expect(line.contains("/5.00GB · "), "\(line)")
        // The time left: the first's (about 10 s), then the second's 3 GB at that speed (about 29 s).
        let seconds = try #require(Int(line.split(separator: " ").dropLast().last ?? ""), "\(line)")
        #expect((35...43).contains(seconds), "\(line)")

        // The first is done at 20: nothing is said yet, the second waits
        // (it begins at 23 here).
        try rig.run(from: 10.1, to: 22.5) { [rig] now in rig.unarchiving(at: now, secondStart: 23, secondEnd: 53) }
        #expect(rig.notes.log.contains { $0.hasPrefix("photos.zip: complete: 2.00 GB") })
        #expect(rig.link.sent.allSatisfy { $0.presentSneakPeek == nil })
        surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(text(surfaces.peekCenter)?.hasPrefix("2.00/5.00GB") == true)
        #expect(surfaces.peekRight == .text("40%", style: "numeric"))
        #expect(surfaces.pillLeft == .picture(base64: try #require(rig.pictures.base64(.type("2")))))

        // Its turn, then the end: one card for the two.
        try rig.run(from: 22.6, to: 53) { [rig] now in rig.unarchiving(at: now, secondStart: 23, secondEnd: 53) }
        let end = try #require(rig.link.sent.last)
        #expect(text(end.surfaces?.peekCenter) == "2 Extractions Completed")
        #expect(end.presentSneakPeek == 7)
        #expect(rig.kinds.filter { $0 == .create }.count == 1)
        // The Unarchiver holds the archives for seconds more, then quits:
        // nothing comes of that, and the card goes at its time.
        try rig.run(from: 53.1, to: 62) { [rig] now in rig.unarchiving(at: now, secondStart: 23, secondEnd: 53) }
        #expect(rig.kinds.last == .dismiss)
        #expect(rig.kinds.filter { $0 == .dismiss }.count == 1)
        #expect(rig.kinds.filter { $0 == .create }.count == 1)
    }

    /// Decided on 12 Oct: the pill at once, with a ring that spins until
    /// there is something to count. With Minimum Duration at 0, The
    /// Unarchiver's archive shows from the moment it has it open.
    @Test func withMinimumDurationAtZeroTheUnarchiversArchiveShowsBeforeItsFirstFile() throws {
        var rig = Rig(settings: #"{"values":{"minimumDuration":0}}"#)
        try rig.run(from: 0, to: 0.5) { [rig] now in rig.unarchiving(at: now, both: false) }
        let first = try #require(rig.link.sent.first)
        #expect(first.type == .create)
        #expect(first.surfaces?.pillRight == .ring(value: nil, tint: "blue"), "the ring spins")
        #expect(text(first.surfaces?.peekCenter)?.hasPrefix("0.00/2.00GB") == true)
        #expect(rig.notes.log.contains("photos.zip: its card is shown (every extraction shows)"))
        // It begins at 1: the ring fills.
        try rig.run(from: 0.6, to: 6) { [rig] now in rig.unarchiving(at: now, both: false) }
        guard case .ring(let value?, _)? = rig.link.sent.last?.surfaces?.pillRight else {
            Issue.record("the ring should fill once the first file is written")
            return
        }
        #expect(value > 0.2 && value < 0.3)
        #expect(rig.kinds.filter { $0 == .create }.count == 1)
    }

    /// With Minimum Duration above 0, an archive that only waits isn't
    /// shown: how long it has waited says nothing of its length.
    @Test func anArchiveThatOnlyWaitsShowsNothingHoweverLongItWaits() throws {
        var rig = Rig()
        for second in 0...40 {
            rig.lookout.processes = [unarchiver([reading(rig.archive)])]
            _ = try rig.plugin.step(now: Double(second), incoming: [])
        }
        #expect(rig.link.sent.isEmpty)
        // Let go of without a file written: nothing ever shows.
        rig.lookout.processes = [unarchiver([])]
        _ = try rig.plugin.step(now: 41, incoming: [])
        #expect(rig.link.sent.isEmpty)
        #expect(rig.notes.log.contains("photos.zip: let go of without being extracted"))
    }

    /// A short one that waits behind a long one is left out, as any short
    /// one is.
    @Test func aShortArchiveInTheQueueIsLeftOut() throws {
        var rig = Rig()
        rig.mac.setIndex([ArchiveEntry(path: "album.flac", size: 300_000_000)], format: .rar4, for: rig.other)
        try rig.run(from: 0, to: 20.4) { [rig] now in rig.unarchiving(at: now, secondEnd: 23.5) }
        #expect(rig.notes.log.contains { $0.contains("joins the card") } == false)
        // The first is over, and it was alone on its card: said at once.
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "Complete • photos.zip")
    }

    // MARK: Keka, and its helpers

    /// Keka gives each archive to a helper of its own, at the same time
    /// (a real Mac, 12 Oct): one card for them, as for any two.
    @Test func kekasTwoHelpersAtTheSameTimeAreOneCard() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 10) { [rig] now in rig.kekaExtracting(at: now) }
        #expect(rig.notes.log.contains { $0.hasPrefix("photos.zip: Keka has it open, to extract it: 2.00 GB in 1 file") })
        #expect(rig.notes.log.contains { $0.hasPrefix("music.rar: Keka is extracting it: 3.00 GB in 1 file") })
        var surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(surfaces.pillLeft == .picture(base64: try #require(rig.pictures.base64(.type("2")))))
        #expect(text(surfaces.peekCenter)?.contains("/5.00GB · ") == true)

        // The first is done at 20: nothing is said yet, the second goes on.
        try rig.run(from: 10.1, to: 25) { [rig] now in rig.kekaExtracting(at: now) }
        #expect(rig.notes.log.contains("photos.zip: complete: 2.00 GB in 19.0 s; at /Users/me/Downloads/big.bin"))
        #expect(rig.link.sent.allSatisfy { $0.presentSneakPeek == nil })
        surfaces = try #require(rig.link.sent.last?.surfaces)
        #expect(surfaces.pillLeft == .picture(base64: try #require(rig.pictures.base64(.type("2")))))

        try rig.run(from: 25.1, to: 30.5) { [rig] now in rig.kekaExtracting(at: now) }
        let end = try #require(rig.link.sent.last)
        #expect(text(end.surfaces?.peekCenter) == "2 Extractions Completed")
        #expect(end.presentSneakPeek == 7)
        try rig.run(from: 30.6, to: 40) { [rig] now in rig.kekaExtracting(at: now) }
        #expect(rig.kinds.last == .dismiss)
        #expect(rig.kinds.filter { $0 == .create }.count == 1)
        #expect(rig.kinds.filter { $0 == .dismiss }.count == 1)
    }

    /// With Minimum Duration at 0, the pill comes as soon as a helper has
    /// the archive, with a ring that spins until its first file.
    @Test func withMinimumDurationAtZeroKekasArchiveShowsBeforeItsFirstFile() throws {
        var rig = Rig(settings: #"{"values":{"minimumDuration":0}}"#)
        try rig.run(from: 0, to: 0.5) { [rig] now in [rig.kekaExtracting(at: now)[0]] }
        let first = try #require(rig.link.sent.first)
        #expect(first.type == .create)
        #expect(first.surfaces?.pillRight == .ring(value: nil, tint: "blue"), "the ring spins")
        #expect(text(first.surfaces?.peekCenter)?.hasPrefix("0.00/2.00GB") == true)
        try rig.run(from: 0.6, to: 6) { [rig] now in [rig.kekaExtracting(at: now)[0]] }
        guard case .ring(let value?, _)? = rig.link.sent.last?.surfaces?.pillRight else {
            Issue.record("the ring should fill once the first file is written")
            return
        }
        #expect(value > 0.2 && value < 0.3)
        #expect(rig.kinds.filter { $0 == .create }.count == 1)
    }

    // MARK: While the owner is away ("Delayed Display", "Away After")

    @Test func whileTheOwnerIsAwayTheCardSaysItClosedAndOpensWhenTheyAreBack() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 19.9)
        rig.owner.idle = 75                              // (a minute is the least, unless changed)
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        let closed = try #require(rig.link.sent.last)
        #expect(text(closed.surfaces?.peekCenter) == "Complete • photos.zip")
        #expect(closed.surfaces?.pillRight == .picture(base64: try #require(rig.pictures.base64(.done))))
        #expect(closed.presentSneakPeek == nil, "the notch isn't opened")
        #expect(closed.priority == nil)
        #expect(rig.notes.log.last == "photos.zip: Complete while you're away; shown when you're back")

        // It waits, however long, without another word.
        let count = rig.link.sent.count
        rig.owner.idle = 600
        for now in stride(from: 21.0, through: 600, by: 1) {
            _ = try rig.plugin.step(now: now, incoming: [])
        }
        #expect(rig.link.sent.count == count)
        #expect(try rig.plugin.step(now: 601, incoming: []) <= 1, "it looks again within a second")

        // Back: the sneak peek opens, and the card stays its time from now.
        rig.owner.idle = 0.4
        _ = try rig.plugin.step(now: 602, incoming: [])
        let opened = try #require(rig.link.sent.last)
        #expect(opened.presentSneakPeek == 7)
        #expect(opened.priority == "high")
        #expect(rig.notes.log.last == "photos.zip: Complete is shown, its sneak peek open for 7 s")
        #expect(rig.notes.log.contains("photos.zip: Complete, shown now that you're back (582 s later)"))
        _ = try rig.plugin.step(now: 602.25, incoming: [])
        _ = try rig.plugin.step(now: 607.2, incoming: [])
        #expect(rig.kinds.last == .update)
        _ = try rig.plugin.step(now: 607.3, incoming: [])
        #expect(rig.link.sent.last == .dismiss("extraction-1"))
    }

    @Test func aLockedScreenCountsAsAway() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 19.9)
        rig.owner.isLocked = true
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        #expect(rig.link.sent.last?.presentSneakPeek == nil)
        rig.owner.isLocked = false
        _ = try rig.plugin.step(now: 30, incoming: [])
        #expect(rig.link.sent.last?.presentSneakPeek == 7)
    }

    @Test(arguments: [
        (#"{"values":{"waitWhenAway":false}}"#, 75.0),          // Delayed Display off
        (#"{"values":{"awayAfter":"3 min"}}"#, 75.0),           // not away yet
        (#"{"values":{}}"#, 59.0),
    ])
    func whenTheOwnerDoesNotCountAsAwayTheCardOpensAtOnce(settings: String, idle: Double) throws {
        var rig = Rig(settings: settings)
        try rig.run(from: 0, to: 19.9)
        rig.owner.idle = idle
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        #expect(rig.link.sent.last?.presentSneakPeek == 7)
    }

    /// The Mac doesn't say how long it has been idle: nothing is held back.
    @Test func withoutWordOfTheOwnerTheCardOpensAtOnce() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 19.9)
        rig.owner.idle = nil
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        #expect(rig.link.sent.last?.presentSneakPeek == 7)
    }

    /// Decided on 12 Oct: extractions that end one by one while the owner
    /// is away show as one card when they are back.
    @Test func whatEndedOneByOneWhileAwayIsSaidOnOneCard() throws {
        var rig = Rig()
        rig.owner.idle = 3_600
        try rig.run(from: 0, to: 30) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 40)] }
        #expect(rig.notes.log.last == "photos.zip: Complete while you're away; shown when you're back")
        // The second begins at 40, with the first's `Complete` waiting.
        try rig.run(from: 30.1, to: 60) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 40)] }
        #expect(rig.notes.log.contains("music.rar: the card is taken over (expected to take about 30 s, and 10 s is the least); "
            + "photos.zip will be said with it"))
        #expect(rig.link.sent.contains { $0.priority != nil && $0.type == .update } == false, "it never had the main place to give back")
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter)?.contains("/3.00GB") == true)
        try rig.run(from: 60.1, to: 71) { [rig] now in [rig.first(at: now, until: 20), rig.second(at: now, since: 40, until: 70)] }
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "2 Extractions Completed")
        #expect(rig.link.sent.allSatisfy { $0.presentSneakPeek == nil })
        #expect(rig.notes.log.last == "photos.zip, music.rar: 2 Extractions Completed while you're away; shown when you're back")

        rig.owner.idle = 1
        _ = try rig.plugin.step(now: 500, incoming: [])
        #expect(rig.link.sent.last?.presentSneakPeek == 7)
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter) == "2 Extractions Completed")
        _ = try rig.plugin.step(now: 501, incoming: [.action(LakeAction(activityID: "extraction-1", actionID: "show:extraction-1"))])
        #expect(rig.notes.revealed == [[rig.written, rig.otherWritten]])
        #expect(rig.kinds.filter { $0 == .create }.count == 1)
    }

    @Test func whatWaitedHalfADayGoesWithoutOpening() throws {
        var rig = Rig()
        try rig.run(from: 0, to: 19.9)
        rig.owner.isLocked = true
        rig.end(complete: true)
        _ = try rig.plugin.step(now: 20, incoming: [])
        let count = rig.link.sent.count
        _ = try rig.plugin.step(now: 20 + 12 * 3600 + 1, incoming: [])
        #expect(rig.link.sent.count == count)
        _ = try rig.plugin.step(now: 20 + 12 * 3600 + 6.1, incoming: [])
        #expect(rig.link.sent.last == .dismiss("extraction-1"))
        #expect(rig.link.sent.allSatisfy { $0.presentSneakPeek == nil })
    }

    // MARK: The settings

    @Test func aSettingChangedInDynamicLakeAppliesToTheCardThatIsUp() throws {
        var rig = Rig()
        // An extraction begun at 5: its card comes at 6.5, its type at 10.5.
        try rig.run(from: 5, to: 19, since: 5)
        let zip = Component.picture(base64: try #require(rig.pictures.base64(.type("zip"))))
        #expect(rig.link.sent.last?.surfaces?.pillLeft == zip)
        // (The settings are read again every five seconds: next at 20.)
        rig.notes.settingsFile = Data(#"{"values":{"fileTypeIcons":false,"extractionDetails":"Speed"}}"#.utf8)
        try rig.run(from: 19.1, to: 21.5, since: 5)
        #expect(rig.link.sent.last?.surfaces?.pillLeft == .picture(base64: try #require(rig.pictures.base64(.box))))
        #expect(text(rig.link.sent.last?.surfaces?.peekCenter)?.hasSuffix("· 100 MB/s") == true)
        #expect(rig.notes.log.contains("settings: fileTypeIcons off, extractionDetails speed, delayedDisplay on, "
            + "awayAfter 1 min, sneakPeekDuration 5 s, remainVisible 0 s, minimumDuration 10 s"))
    }

    // MARK: When the plugin comes back

    @Test func thePluginIsBackInTimeForWhateverIsDueNext() throws {
        var rig = Rig()
        rig.lookout.basePause = 1
        // Nothing going on: as the lookout says.
        #expect(try rig.plugin.step(now: 0, incoming: []) == 1)
        // An extraction without a total that hasn't lasted the minimum yet:
        // back when it has.
        rig.mac.setIndexFailure(.locked, for: rig.archive)
        rig.extracting(at: 0.5, since: 0.5)
        _ = try rig.plugin.step(now: 0.5, incoming: [])
        rig.extracting(at: 9.9, since: 0.5)
        let pause = try rig.plugin.step(now: 9.9, incoming: [])
        #expect(abs(pause - 0.6) < 0.001)

        // A finished card: back when it is due to go.
        var other = Rig()
        other.lookout.basePause = 1
        try other.run(from: 0, to: 19.9)
        other.end(complete: true)
        // (Back first for the sneak peek that is asked for once more.)
        #expect(abs(try other.plugin.step(now: 20, incoming: []) - 0.2) < 0.001)
        _ = try other.plugin.step(now: 20.2, incoming: [])
        let last = try other.plugin.step(now: 24.5, incoming: [])
        #expect(abs(last - 0.7) < 0.001)
    }
}
