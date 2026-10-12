// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

struct AmountTests {
    @Test(arguments: [
        (UInt64(0), "0 bytes"),
        (1, "1 byte"),
        (999, "999 bytes"),
        (1_000, "1.0 KB"),
        (4_240, "4.2 KB"),
        (155_000_000, "155.0 MB"),
        (999_960_000, "1000.0 MB"),
        (2_559_400_215, "2.56 GB"),
        (17_150_648_656, "17.15 GB"),
        (UInt64.max, "18446744073.71 GB"),
    ])
    func sizesAreWrittenInTheFindersUnits(bytes: UInt64, expected: String) {
        #expect(Amount.bytes(bytes) == expected)
    }

    @Test(arguments: [
        (UInt64(0), UInt64(100), "0 %"),
        (99, 100, "99 %"),
        (100, 100, "100 %"),
        (999, 1_000, "99 %"),
        (150, 100, "100 %"),
        (0, 0, "100 %"),
        (UInt64.max - 1, UInt64.max, "99 %"),
    ])
    func percentagesAreRoundedDown(done: UInt64, total: UInt64, expected: String) {
        #expect(Amount.percent(done, of: total) == expected)
    }

    @Test(arguments: [(0, "0"), (999, "999"), (1_000, "1,000"), (12_000, "12,000"), (1_234_567, "1,234,567"), (-1_500, "-1,500")])
    func countsAreGroupedByThousands(value: Int, expected: String) {
        #expect(Amount.count(value) == expected)
    }

    @Test func speedsAndTimesKeepOneDecimal() {
        #expect(Amount.speed(155_000_000) == "155.0 MB/s")
        #expect(Amount.speed(-1) == "0 bytes/s")
        #expect(Amount.speed(.nan) == "0 bytes/s")
        #expect(Amount.seconds(13.24) == "13.2 s")
        #expect(Amount.seconds(0) == "0.0 s")
    }
}
