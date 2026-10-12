// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Amounts as the log writes them: sizes in the units the Finder uses
/// (1 GB = 1,000,000,000 bytes), always with a full stop for the decimals,
/// whatever the Mac's language and region.
enum Amount {
    /// `812 bytes`, `4.2 KB`, `155.0 MB`, `2.56 GB`
    static func bytes(_ value: UInt64) -> String {
        switch value {
        case ..<1_000:
            "\(value) byte\(value == 1 ? "" : "s")"
        case ..<1_000_000:
            decimal(value, per: 1_000, places: 1) + " KB"
        case ..<1_000_000_000:
            decimal(value, per: 1_000_000, places: 1) + " MB"
        default:
            decimal(value, per: 1_000_000_000, places: 2) + " GB"
        }
    }

    /// `155.0 MB/s`
    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(whole(bytesPerSecond)) + "/s"
    }

    /// `13.2 s`
    static func seconds(_ value: Double) -> String {
        decimal(whole(value * 10), per: 10, places: 1) + " s"
    }

    /// `33 %`, rounded down so that 100 % is only said when it is all there.
    static func percent(_ done: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "100 %" }
        // (Done never counts for more than the total, so the result fits;
        // worked out on twice the width, so that no size overflows.)
        let product = min(done, total).multipliedFullWidth(by: 100)
        let value = total.dividingFullWidth(product).quotient
        return "\(value) %"
    }

    /// `12,000`
    static func count(_ value: Int) -> String {
        var digits = String(abs(value))
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(digits, at: 0)
        return (value < 0 ? "-" : "") + groups.joined(separator: ",")
    }

    /// `value / per` with that many decimals, rounded to the nearest.
    private static func decimal(_ value: UInt64, per unit: UInt64, places: Int) -> String {
        let scale: UInt64 = places == 2 ? 100 : 10
        // (In two steps, so that the largest sizes don't overflow.)
        let wholePart = value / unit
        let fraction = ((value % unit) * scale + unit / 2) / unit
        let carried = wholePart + fraction / scale
        let digits = String(fraction % scale)
        return "\(carried)." + String(repeating: "0", count: places - digits.count) + digits
    }

    private static func whole(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? .max : UInt64(value.rounded())
    }
}
