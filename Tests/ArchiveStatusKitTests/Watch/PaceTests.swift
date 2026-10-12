// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

struct PaceTests {
    /// The same readings as Firefox Downloads' own code was given, and its
    /// answers (see Fixtures/PaceFixtures.swift): a steady extraction, one
    /// that slows down, one that stalls and resumes, one that speeds up.
    @Test(arguments: [
        ("steady", PaceFixtures.steady, PaceFixtures.steadyTotal),
        ("slows down", PaceFixtures.slowsDown, PaceFixtures.slowsDownTotal),
        ("stalls then resumes", PaceFixtures.stallsThenResumes, PaceFixtures.stallsThenResumesTotal),
        ("speeds up", PaceFixtures.speedsUp, PaceFixtures.speedsUpTotal),
    ] as [(String, [Reading], UInt64)])
    func speedAndTimeLeftAreThoseOfFirefoxDownloads(name: String, readings: [Reading], total: UInt64) throws {
        let first = try #require(readings.first)
        var pace = Pace(now: first.now)
        for reading in readings {
            pace.note(reading.bytes, now: reading.now)
            let left = pace.timeLeft(total: total, now: reading.now)
            #expect(left == reading.left, "\(name): the time left at \(reading.now)")
            #expect(abs(pace.speed - reading.speed) <= max(1e-6, abs(reading.speed) * 1e-12), "\(name): the speed at \(reading.now)")
        }
    }

    @Test func readingsAreTakenAtMostEveryHalfSecondOrSo() {
        var pace = Pace(now: 0)
        pace.note(100, now: 0)
        pace.note(900, now: 0.2)             // too soon: not taken
        #expect(pace.bytes == 100)
        pace.note(900, now: 0.45)
        #expect(pace.bytes == 900)
        #expect(pace.speed == 800 / 0.45)
    }

    @Test func theSpeedIsOverTheLastEightReadings() {
        var pace = Pace(now: 0)
        // A slow first second, then steady: once eight readings have come
        // since, the slow one no longer counts.
        pace.note(0, now: 0)
        pace.note(10, now: 1)
        for second in 2...9 {
            pace.note(UInt64(10 + (second - 1) * 1_000), now: Double(second))
        }
        #expect(pace.speed == 1_000)
    }

    @Test func noTimeLeftIsGivenWithoutATotalOrBeforeThreeSecondsOfReadings() {
        var pace = Pace(now: 0)
        pace.note(0, now: 0)
        pace.note(2_000_000, now: 2)
        #expect(pace.timeLeft(total: 10_000_000, now: 2) == nil)
        pace.note(3_000_000, now: 3)
        #expect(pace.timeLeft(total: 10_000_000, now: 3) == 7)
        #expect(pace.timeLeft(total: nil, now: 3) == nil)
        #expect(pace.timeLeft(total: 0, now: 3) == nil)
    }

    @Test func noTimeLeftIsGivenAtACrawl() {
        var pace = Pace(now: 0)
        pace.note(0, now: 0)
        pace.note(500, now: 4)               // under 1 KB a second
        #expect(pace.timeLeft(total: 1_000_000, now: 4) == nil)
    }

    @Test func theTimeLeftIsNeverLessThanOneSecondWhileItRuns() {
        var pace = Pace(now: 0)
        pace.note(0, now: 0)
        pace.note(9_999_000, now: 4)
        #expect(pace.timeLeft(total: 10_000_000, now: 4) == 1)
        // More written than the total announced: still no negative time.
        pace.note(12_000_000, now: 5)
        #expect(pace.timeLeft(total: 10_000_000, now: 5) == 1)
    }

    @Test func whenTheAmountLastGrewIsKept() {
        var pace = Pace(now: 10)
        #expect(pace.lastGrowthAt == 10)
        pace.note(100, now: 11)
        pace.note(100, now: 12)
        pace.note(100, now: 13)
        #expect(pace.lastGrowthAt == 11)
        pace.note(200, now: 14)
        #expect(pace.lastGrowthAt == 14)
    }

    @Test func anAmountThatStartsOverIsMeasuredAfresh() {
        var pace = Pace(now: 0)
        pace.note(5_000, now: 0)
        pace.note(9_000, now: 1)
        pace.note(100, now: 2)
        #expect(pace.bytes == 100)
        #expect(pace.speed == 0)
    }
}

extension PaceTests {
    @Test func afterAStandstillTheSpeedIsMeasuredAfresh() {
        var pace = Pace(now: 0)
        for second in 0...5 {
            pace.note(UInt64(second) * 1_000_000, now: Double(second))
        }
        #expect(pace.timeLeft(total: 100_000_000, now: 5) == 95)
        // Twenty seconds of nothing, then it goes on.
        for second in 6...25 {
            pace.note(5_000_000, now: Double(second))
        }
        pace.startAfresh(now: 25)
        #expect(pace.bytes == 5_000_000)
        #expect(pace.speed == 0)
        #expect(pace.timeLeft(total: 100_000_000, now: 25) == nil)
        #expect(pace.lastGrowthAt == 25)
        for second in 26...29 {
            pace.note(UInt64(5 + second - 25) * 1_000_000, now: Double(second))
        }
        #expect(pace.speed == 1_000_000)
        #expect(pace.timeLeft(total: 100_000_000, now: 29) == 91)
    }

    /// At `1 second` nothing more counts down: no change is announced, so
    /// that the plugin doesn't come back for one at every look.
    @Test func atOneSecondNoNextChangeIsAnnounced() throws {
        var pace = Pace(now: 0)
        var left: Int?
        // 100 MB a second, up to half a second from the end.
        for tenth in 0...195 {
            let now = Double(tenth) / 10
            pace.note(UInt64(now * 100_000_000), now: now)
            left = pace.timeLeft(total: 2_000_000_000, now: now)
        }
        #expect(left == 1)
        #expect(pace.nextTickAt == nil)
        // It goes on without getting there: still `1 second`, still nothing announced.
        for tenth in 196...215 {
            let now = Double(tenth) / 10
            pace.note(1_950_000_000 + UInt64(tenth - 195) * 1_000_000, now: now)
            left = pace.timeLeft(total: 2_000_000_000, now: now)
            #expect(pace.nextTickAt.map { $0 > now } ?? true, "a change is never announced for now or before")
        }
        // With seconds to go, the next one is announced, ahead.
        var early = Pace(now: 0)
        for tenth in 0...100 {
            let now = Double(tenth) / 10
            early.note(UInt64(now * 100_000_000), now: now)
            _ = early.timeLeft(total: 2_000_000_000, now: now)
        }
        let tick = try #require(early.nextTickAt)
        #expect(tick > 10 && tick <= 11)
    }
}
