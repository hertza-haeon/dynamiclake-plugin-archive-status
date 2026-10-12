// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// How fast an extraction goes and how long it has left, worked out the way
/// Firefox Downloads does for a download: the speed over the last few
/// readings, and a time left that follows it smoothly instead of jumping at
/// every reading.
public struct Pace: Sendable {
    /// Readings kept for the speed.
    static let window = 8
    /// Readings are taken at most this often, in seconds.
    static let minGap = 0.45
    /// Seconds of readings before a time left is given.
    static let timeLeftSpan = 3.0

    private var readings: [(at: Double, bytes: UInt64)] = []
    /// When the amount last grew.
    public private(set) var lastGrowthAt: Double

    /// The smoothed time left, and when it was estimated.
    private var estimate: Double?
    private var estimateAt = 0.0
    /// The time left as shown (it counts down by itself), and when it was that much.
    private var shown: Double?
    private var shownAt = 0.0
    /// When the time left as shown changes to its next second; nothing
    /// while no time left is given.
    public private(set) var nextTickAt: Double?

    public init(now: Double) {
        lastGrowthAt = now
    }

    /// The amount at the last reading.
    public var bytes: UInt64 { readings.last?.bytes ?? 0 }

    /// Takes a reading, unless the last one is too recent.
    public mutating func note(_ bytes: UInt64, now: Double) {
        if let last = readings.last, now - last.at < Self.minGap { return }
        if let last = readings.last, bytes < last.bytes {
            // It started over: measure afresh.
            readings.removeAll()
            estimate = nil
            shown = nil
        }
        if readings.last.map({ bytes > $0.bytes }) ?? true {
            lastGrowthAt = now
        }
        readings.append((now, bytes))
        if readings.count > Self.window {
            readings.removeFirst(readings.count - Self.window)
        }
    }

    /// Forgets the readings and measures afresh from the last amount: after
    /// a stall, the readings of the standstill would give a speed, and a
    /// time left, that mean nothing.
    public mutating func startAfresh(now: Double) {
        let amount = bytes
        readings = [(now, amount)]
        estimate = nil
        shown = nil
        nextTickAt = nil
        lastGrowthAt = now
    }

    /// Bytes per second over the readings kept.
    public var speed: Double {
        guard let first = readings.first, let last = readings.last, readings.count >= 2 else { return 0 }
        let elapsed = last.at - first.at
        return elapsed > 0 ? Double(last.bytes - first.bytes) / elapsed : 0
    }

    /// Whole seconds left, or nothing until there are enough steady readings
    /// to tell. The estimate follows the speed, smoothed; what is shown
    /// counts down by itself and is set right once it has drifted too far
    /// from the estimate.
    public mutating func timeLeft(total: UInt64?, now: Double) -> Int? {
        nextTickAt = nil
        guard let total, total > 0, let first = readings.first, let last = readings.last,
              readings.count >= 2, last.at - first.at >= Self.timeLeftSpan else {
            estimate = nil
            shown = nil
            return nil
        }
        let speed = speed
        guard speed >= 1024 else { return nil }
        let raw = max(0, Double(total - min(total, last.bytes)) / speed)
        if let previous = estimate {
            let predicted = max(0, previous - (now - estimateAt))     // it counts down by itself
            if raw > 2 * predicted + 30 || raw < 0.5 * predicted - 30 {
                estimate = raw                                          // a real change of pace
            } else {
                let weight = 1 - exp(-max(0, now - estimateAt) / 3.0)
                estimate = predicted + weight * (raw - predicted)
            }
        } else {
            estimate = raw
        }
        estimateAt = now
        let current = estimate ?? raw
        var display = shown.map { $0 - (now - shownAt) }
        if display.map({ abs(current - $0) > Self.margin(max(0, $0)) }) ?? true {
            display = current
        }
        shown = display
        shownAt = now
        let whole = max(1, Int((display ?? current).rounded(.up)))
        // (At `1 second` there is no next second to count down to: it
        // stays until the estimate says otherwise. A change announced for
        // "now", look after look, had the plugin send an update at every
        // look, and DynamicLake refuse them: a real Mac, 12 Oct 2026.)
        nextTickAt = whole >= 2 ? now + ((display ?? current) - Double(whole - 1)) : nil
        return whole
    }

    /// How far the estimate must drift from what is shown before that is set
    /// right, so that it doesn't jump at every reading of the speed.
    static func margin(_ shown: Double) -> Double {
        max(2.0, 0.06 * shown)
    }
}
