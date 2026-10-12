// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import os
import Testing
@testable import ArchiveStatusKit

/// What a made-up Mac is running, changed by the test between two looks.
private struct Programs: Sendable {
    private struct State {
        var names: [pid_t: String] = [:]
        var asked: [pid_t: Int] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var names: [pid_t: String] {
        get { state.withLock { $0.names } }
        nonmutating set { state.withLock { $0.names = newValue } }
    }

    /// How many times each program's name was asked for.
    var asked: [pid_t: Int] { state.withLock { $0.asked } }

    func scanner() -> ToolScanner {
        ToolScanner(runningPrograms: { state.withLock { Array($0.names.keys) } },
                    nameOf: { pid in
                        state.withLock {
                            $0.asked[pid, default: 0] += 1
                            return $0.names[pid]
                        }
                    })
    }
}

struct ToolScannerTests {
    @Test func theUnarchiversAreFoundByTheirNames() {
        let programs = Programs()
        programs.names = [10: "Finder", 20: "MacPacker", 30: "ArchiveService", 40: "Archive Utility"]
        var scanner = programs.scanner()
        let found = scanner.scan().sorted { $0.pid < $1.pid }
        #expect(found.map(\.pid) == [20, 30])
        #expect(found.map(\.tool) == [.macPacker, .archiveUtility])
    }

    /// Keka gives each archive to a helper named after what it runs; the
    /// app itself, and what it adds to the Finder, extract nothing.
    @Test func kekasHelpersAreFoundByHowTheirNamesBegin() {
        let programs = Programs()
        programs.names = [10: "Keka", 11: "KekaFinderIntegration", 20: "kekaunar", 21: "keka7zz", 22: "kekatar", 23: "kekaunrar",
                          30: "The Unarchiver"]
        var scanner = programs.scanner()
        let found = scanner.scan().sorted { $0.pid < $1.pid }
        #expect(found.map(\.pid) == [20, 21, 22, 23, 30])
        #expect(found.map(\.tool) == [.keka, .keka, .keka, .keka, .theUnarchiver])
        #expect(scanner.heraldIsRunning, "Keka has appeared: a helper may follow")
    }

    /// Seen on the real Mac (11 Oct): Archive Utility's helper is started
    /// under the name `xpcproxy` and takes its own a moment later. Asked
    /// once, too early, it stayed invisible for good.
    @Test func aHelperThatTakesItsNameAMomentLaterIsStillFound() {
        let programs = Programs()
        programs.names = [77: "xpcproxy"]
        var scanner = programs.scanner()
        #expect(scanner.scan().isEmpty)
        programs.names[77] = "ArchiveService"
        #expect(scanner.scan().map(\.pid) == [77])
    }

    /// Seen on the real Mac (12 Oct): Keka's helper is `Keka` itself for a
    /// few milliseconds, then takes its own name. Asked once, just then,
    /// it was taken for the app and a whole extraction went unseen.
    @Test func aHelperThatStartsUnderItsAppsNameIsStillFound() {
        let programs = Programs()
        programs.names = [50: "Keka", 77: "Keka"]
        var scanner = programs.scanner()
        #expect(scanner.scan().isEmpty)
        #expect(scanner.heraldIsRunning)
        programs.names[77] = "kekaunar"
        #expect(scanner.scan().map(\.pid) == [77])
        #expect(scanner.scan().map(\.tool) == [.keka])
        // The app itself stays what it is, and isn't asked for ever.
        for _ in 0..<50 {
            _ = scanner.scan()
        }
        #expect(programs.asked[50] == ToolScanner.looksBeforeSettled)
        #expect(scanner.heraldIsRunning)
    }

    @Test func aNameIsNotAskedForEverOnceSettled() {
        let programs = Programs()
        programs.names = [10: "Finder", 20: "MacPacker"]
        var scanner = programs.scanner()
        for _ in 0..<50 {
            _ = scanner.scan()
        }
        #expect(programs.asked[10] == ToolScanner.looksBeforeSettled)
        #expect(programs.asked[20] == 1, "an unarchiver that was recognised isn't asked again")
    }

    @Test func aNumberTakenByAnotherProgramIsAskedAfresh() {
        let programs = Programs()
        programs.names = [10: "Finder"]
        var scanner = programs.scanner()
        for _ in 0..<10 {
            _ = scanner.scan()
        }
        programs.names = [:]
        #expect(scanner.scan().isEmpty)
        programs.names = [10: "MacPacker"]
        #expect(scanner.scan().map(\.tool) == [.macPacker])
    }

    @Test func theArchiveUtilityAppIsAHeraldNotATool() {
        let programs = Programs()
        programs.names = [10: "Finder"]
        var scanner = programs.scanner()
        #expect(scanner.scan().isEmpty)
        #expect(scanner.heraldIsRunning == false)
        programs.names[40] = "Archive Utility"
        #expect(scanner.scan().isEmpty)
        #expect(scanner.heraldIsRunning)
        programs.names[40] = nil
        _ = scanner.scan()
        #expect(scanner.heraldIsRunning == false)
    }

    @Test func thisMacsOwnListHoldsThisVeryProgram() {
        let me = ProcessInfo.processInfo.processIdentifier
        #expect(ToolScanner.runningPrograms().contains(me))
        #expect(ToolScanner.name(of: me)?.isEmpty == false)
        #expect(ToolScanner.name(of: -5) == nil)
    }
}
