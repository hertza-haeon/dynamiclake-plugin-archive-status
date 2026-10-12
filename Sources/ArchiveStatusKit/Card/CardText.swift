// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The amounts and the time left as the card writes them: the way Firefox
/// Downloads writes them (`0.85/2.56GB`, `45 seconds`, `2 min 34 s`), with
/// sizes counted the way the Finder counts them (1 GB = 1,000,000,000
/// bytes; decided on 11 Oct 2026). Always with a full stop for the
/// decimals, whatever the Mac's language and region.
enum CardText {
    private static let kilo: UInt64 = 1_000
    private static let mega: UInt64 = 1_000_000
    private static let giga: UInt64 = 1_000_000_000

    /// `Complete • photos.zip`: what happened, then the name.
    static let bullet = " • "

    /// `294/871MB`, `0.83/2.00GB`: the amount extracted and the total, in
    /// the total's unit. The amount is rounded down, so that it never reads
    /// as the total before everything is extracted.
    static func pair(done: UInt64, total: UInt64) -> String {
        let (per, unit, decimals) = amountUnit(total)
        return floored(min(done, total), per: per, decimals: decimals) + "/"
            + rounded(total, per: per, decimals: decimals) + unit
    }

    /// `294MB`, `0.83GB`: the amount extracted when there is no total.
    static func amount(_ done: UInt64) -> String {
        let (per, unit, decimals) = amountUnit(done)
        return floored(done, per: per, decimals: decimals) + unit
    }

    /// `13.8 MB/s`, `512 KB/s`; `-- KB/s` when nothing moves.
    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return "-- KB/s" }
        return bytes(bytesPerSecond) + "/s"
    }

    /// `33%`, rounded down so that it never reads 100% before the end; `—`
    /// when there is no total.
    static func percent(done: UInt64, total: UInt64?) -> String {
        guard let total, total > 0, done <= total else { return "—" }
        let product = done.multipliedFullWidth(by: 100)
        return "\(total.dividingFullWidth(product).quotient)%"
    }

    /// How far along, from 0 to 1, for the ring; nothing without a total
    /// (the ring then spins).
    static func fraction(done: UInt64, total: UInt64?) -> Double? {
        guard let total, total > 0, done <= total else { return nil }
        return (Double(done) / Double(total) * 10_000).rounded() / 10_000
    }

    /// `45 seconds`, `2 min 34 s`, `1 h 20 min 5 s`: the time left, always
    /// with its seconds. Under a minute the word is written out, so that
    /// the line takes about the room it took with the minutes.
    static func time(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let (minutes, secs) = (total / 60, total % 60)
        if minutes == 0 {
            return secs == 1 ? "1 second" : "\(secs) seconds"
        }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return hours == 0 ? "\(rest) min \(secs) s" : "\(hours) h \(rest) min \(secs) s"
    }

    /// The widest the time left gets under a minute (see `CardFace`).
    static let lastMinuteWidest = "88 seconds"

    /// `5.9 MB`, `13.8 MB`, `512 KB`: one decimal below 100, whole numbers
    /// from 100 up, and the next unit before a number would need four
    /// digits.
    static func bytes(_ count: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(count, 0)
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        // (A value exactly halfway goes to the even digit, as it does in
        // Firefox Downloads.)
        if unit == 0 || value >= 99.95 {
            return "\(Int(value.rounded(.toNearestOrEven))) \(units[unit])"
        }
        let tenths = Int((value * 10).rounded(.toNearestOrEven))
        return "\(tenths / 10).\(tenths % 10) \(units[unit])"
    }

    /// The unit for the amounts: whole megabytes below 1 GB, gigabytes with
    /// two decimals from there, whole kilobytes for less than a megabyte.
    private static func amountUnit(_ reference: UInt64) -> (per: UInt64, unit: String, decimals: Int) {
        if reference >= giga { return (giga, "GB", 2) }
        if reference >= mega { return (mega, "MB", 0) }
        return (kilo, "KB", 0)
    }

    private static func floored(_ value: UInt64, per: UInt64, decimals: Int) -> String {
        let scale: UInt64 = decimals == 2 ? 100 : 1
        // (In two steps, so that the largest sizes don't overflow.)
        return fixed(whole: value / per, hundredths: (value % per) * scale / per, decimals: decimals)
    }

    private static func rounded(_ value: UInt64, per: UInt64, decimals: Int) -> String {
        let scale: UInt64 = decimals == 2 ? 100 : 1
        let fraction = ((value % per) * scale + per / 2) / per
        return fixed(whole: value / per + fraction / scale, hundredths: fraction % scale, decimals: decimals)
    }

    private static func fixed(whole: UInt64, hundredths: UInt64, decimals: Int) -> String {
        guard decimals == 2 else { return "\(whole)" }
        return "\(whole)." + (hundredths < 10 ? "0" : "") + "\(hundredths)"
    }
}
