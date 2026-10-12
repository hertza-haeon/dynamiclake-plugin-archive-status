// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation

/// Whether the owner is at the Mac, for "Delayed Display". macOS tells any
/// program how long it has been since the keyboard, the mouse or the
/// trackpad was last touched, and whether the screen is locked: no
/// permission is needed, and nothing of what is typed or clicked is seen.
/// Tests put a stand-in in its place.
public struct Presence: Sendable {
    /// Whether the screen is locked, or this login isn't the one on screen.
    public var isScreenLocked: @Sendable () -> Bool
    /// How long since the last input, in seconds; nothing when macOS
    /// doesn't say.
    public var secondsSinceInput: @Sendable () -> Double?

    public init(isScreenLocked: @escaping @Sendable () -> Bool, secondsSinceInput: @escaping @Sendable () -> Double?) {
        self.isScreenLocked = isScreenLocked
        self.secondsSinceInput = secondsSinceInput
    }

    /// The owner is away: the screen is locked, or there has been no
    /// input for `seconds`.
    func isAway(after seconds: Int) -> Bool {
        if isScreenLocked() { return true }
        guard let idle = secondsSinceInput() else { return false }
        return idle >= Double(seconds)
    }

    /// The Mac itself.
    public static var live: Presence {
        Presence(
            isScreenLocked: {
                guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
                let isLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
                let isOnScreen = session["kCGSSessionOnConsoleKey"] as? Bool ?? true
                return isLocked || isOnScreen == false
            },
            secondsSinceInput: {
                // Any kind of input, by anyone or anything that posts it
                // for the owner (a remote session, Voice Control).
                guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
                return idle.isFinite && idle >= 0 ? idle : nil
            })
    }
}
