// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

struct LookoutTests {
    @Test func nothingRunningMeansOneLookASecond() {
        #expect(SystemLookout.pause(attention: .none, toolIsRunning: false, heraldAge: nil) == 1.0)
    }

    @Test func anUnarchiverRunningIsLookedAtTwiceASecond() {
        #expect(SystemLookout.pause(attention: .none, toolIsRunning: true, heraldAge: nil) == 0.25)
    }

    @Test func anOpenArchiveIsLookedAtTenTimesASecond() {
        #expect(SystemLookout.pause(attention: .close, toolIsRunning: true, heraldAge: nil) == 0.1)
    }

    @Test func theAppJustAppearedKeepsTheLooksFrequentForAWhileOnly() {
        #expect(SystemLookout.pause(attention: .none, toolIsRunning: false, heraldAge: 0) == 0.1)
        #expect(SystemLookout.pause(attention: .none, toolIsRunning: false, heraldAge: 9.9) == 0.1)
        // The app may stay open for long: it doesn't keep the plugin busy.
        #expect(SystemLookout.pause(attention: .none, toolIsRunning: false, heraldAge: 10) == 0.25)
        #expect(SystemLookout.pause(attention: .none, toolIsRunning: false, heraldAge: 3_600) == 0.25)
    }
}
