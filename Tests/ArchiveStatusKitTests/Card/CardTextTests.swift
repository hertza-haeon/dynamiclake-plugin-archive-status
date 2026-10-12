// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// The card's amounts, speeds and times against what Firefox Downloads' own
/// code writes when it counts the Finder's way (Fixtures/CardTextFixtures).
struct CardTextTests {
    @Test func amountsWithATotalAreFirefoxDownloads() {
        for (done, total, text) in CardTextFixtures.pairs {
            #expect(CardText.pair(done: done, total: total) == text, "\(done) of \(total)")
        }
    }

    @Test func amountsWithoutATotalAreFirefoxDownloads() {
        for (done, text) in CardTextFixtures.amounts {
            #expect(CardText.amount(done) == text, "\(done)")
        }
    }

    @Test func speedsAreFirefoxDownloads() {
        for (speed, text) in CardTextFixtures.speeds {
            #expect(CardText.speed(speed) == text, "\(speed)")
        }
    }

    @Test func timesAreFirefoxDownloads() {
        for (seconds, text) in CardTextFixtures.times {
            #expect(CardText.time(seconds) == text, "\(seconds)")
        }
    }

    @Test func sizesAreCountedTheFindersWay() {
        // A 2,559,400,215-byte file: 2.56 GB in the Finder.
        #expect(CardText.pair(done: 850_000_000, total: 2_559_400_215) == "0.85/2.56GB")
    }

    @Test func theAmountNeverReadsAsTheTotalBeforeTheEnd() {
        #expect(CardText.pair(done: 1_999_999_999, total: 2_000_000_000) == "1.99/2.00GB")
        #expect(CardText.pair(done: 870_999_999, total: 871_000_000) == "870/871MB")
        // More than the total announced never shows as more.
        #expect(CardText.pair(done: 9_000_000_000, total: 2_000_000_000) == "2.00/2.00GB")
    }

    @Test func theLargestSizesDoNotOverflow() {
        #expect(CardText.pair(done: .max, total: .max) == "18446744073.70/18446744073.71GB")
        #expect(CardText.amount(.max) == "18446744073.70GB")
        #expect(CardText.percent(done: .max - 1, total: .max) == "99%")
    }

    @Test(arguments: [
        (UInt64(0), UInt64(1_000), "0%"), (329, 1_000, "32%"), (999, 1_000, "99%"), (1_000, 1_000, "100%"),
    ])
    func thePercentageIsRoundedDown(done: UInt64, total: UInt64, text: String) {
        #expect(CardText.percent(done: done, total: total) == text)
    }

    @Test func withoutATotalThereIsNoPercentageAndNoRingValue() {
        #expect(CardText.percent(done: 500, total: nil) == "—")
        #expect(CardText.percent(done: 500, total: 0) == "—")
        #expect(CardText.fraction(done: 500, total: nil) == nil)
        #expect(CardText.fraction(done: 500, total: 0) == nil)
    }

    @Test func theRingsValueHasFourDecimals() {
        #expect(CardText.fraction(done: 1, total: 3) == 0.3333)
        #expect(CardText.fraction(done: 2, total: 3) == 0.6667)
        #expect(CardText.fraction(done: 3, total: 3) == 1)
        #expect(CardText.fraction(done: 0, total: 3) == 0)
    }

    @Test func aSpeedThatIsNotANumberShowsAsNothingMoving() {
        #expect(CardText.speed(.nan) == "-- KB/s")
        #expect(CardText.speed(.infinity) == "-- KB/s")
        #expect(CardText.speed(-10) == "-- KB/s")
    }
}
