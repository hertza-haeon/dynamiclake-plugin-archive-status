// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// What Firefox Downloads' own code (`human_pair`, `human_amount`,
// `human_speed`, `human_time`, run as they are) writes for these values
// once it counts in thousands, the Finder's way, instead of in 1024s.
// Archive Status must write the same. (Totals exactly halfway between two
// figures are left out: there Firefox Downloads' answer depends on how the
// computer holds the fraction.) Written by a script; not edited by hand.

enum CardTextFixtures {
    static let pairs: [(done: UInt64, total: UInt64, text: String)] = [
        (0, 600, "0/1KB"),
        (999, 1000, "0/1KB"),
        (1500, 900000, "1/900KB"),
        (123456, 999999, "123/1000KB"),
        (1, 1000000, "0/1MB"),
        (294123456, 871654321, "294/872MB"),
        (870999999, 871000000, "870/871MB"),
        (999400000, 999600001, "999/1000MB"),
        (1, 1000000000, "0.00/1.00GB"),
        (834567890, 2000000000, "0.83/2.00GB"),
        (850123456, 2559400215, "0.85/2.56GB"),
        (2559400214, 2559400215, "2.55/2.56GB"),
        (2559400215, 2559400215, "2.55/2.56GB"),
        (7031111111, 8388608000, "7.03/8.39GB"),
        (9999999999, 17150648656, "9.99/17.15GB"),
        (123456789012, 4000000000123, "123.45/4000.00GB"),
    ]
    static let amounts: [(done: UInt64, text: String)] = [
        (0, "0KB"),
        (1, "0KB"),
        (999, "0KB"),
        (1000, "1KB"),
        (51234, "51KB"),
        (999999, "999KB"),
        (1000000, "1MB"),
        (294123456, "294MB"),
        (999999999, "999MB"),
        (1000000000, "1.00GB"),
        (834567890123, "834.56GB"),
    ]
    static let speeds: [(bytesPerSecond: Double, text: String)] = [
        (0.0, "-- KB/s"),
        (0.5, "-- KB/s"),
        (1.0, "1 B/s"),
        (512.4, "512 B/s"),
        (998.9, "999 B/s"),
        (999.6, "1.0 KB/s"),
        (1000.0, "1.0 KB/s"),
        (5940.0, "5.9 KB/s"),
        (13849.0, "13.8 KB/s"),
        (99940.0, "99.9 KB/s"),
        (99960.0, "100 KB/s"),
        (512300.0, "512 KB/s"),
        (999499.0, "999 KB/s"),
        (999600.0, "1.0 MB/s"),
        (1250000.0, "1.2 MB/s"),
        (13849000.0, "13.8 MB/s"),
        (155000000.0, "155 MB/s"),
        (751600000.0, "752 MB/s"),
        (1340000000.0, "1.3 GB/s"),
        (2050000000.0, "2.0 GB/s"),
    ]
    static let times: [(seconds: Int, text: String)] = [
        (-5, "0 seconds"),
        (0, "0 seconds"),
        (1, "1 second"),
        (2, "2 seconds"),
        (45, "45 seconds"),
        (59, "59 seconds"),
        (60, "1 min 0 s"),
        (61, "1 min 1 s"),
        (154, "2 min 34 s"),
        (3599, "59 min 59 s"),
        (3600, "1 h 0 min 0 s"),
        (3661, "1 h 1 min 1 s"),
        (4805, "1 h 20 min 5 s"),
        (86399, "23 h 59 min 59 s"),
        (90061, "25 h 1 min 1 s"),
    ]
}
