// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

struct PluginLogTests {
    let scratch: ScratchFolder

    init() throws {
        scratch = try ScratchFolder()
    }

    private func text(of path: String) throws -> String {
        try String(contentsOf: URL(filePath: path), encoding: .utf8)
    }

    @Test func eachEventIsOneLineWithItsTime() throws {
        // (A folder that isn't there yet: the log makes it.)
        let path = scratch.path + "/Logs/ArchiveStatus/plugin.log"
        let log = PluginLog(path: path)
        log.write("first")
        log.write("second: été, 中")
        let lines = try text(of: path).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].wholeMatch(of: #/\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  first/#) != nil)
        #expect(lines[1].hasSuffix("  second: été, 中"))
    }

    @Test func aPreciseLineHasItsMilliseconds() throws {
        let path = scratch.path + "/trace.log"
        PluginLog(path: path).write("looked", precise: true)
        #expect(try text(of: path).wholeMatch(of: #/\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}  looked\n/#) != nil)
    }

    @Test func aLogGrownTooLongIsSetAsideAndBegunAnew() throws {
        let path = scratch.path + "/plugin.log"
        try scratch.write([UInt8](repeating: 0x78, count: Int(PluginLog.maxBytes) + 1), as: "plugin.log")
        PluginLog(path: path).write("after")
        #expect(try text(of: path).hasSuffix("  after\n"))
        #expect(try text(of: path).count < 100)
        let attributes = try FileManager.default.attributesOfItem(atPath: path + ".1")
        #expect(attributes[.size] as? Int == Int(PluginLog.maxBytes) + 1)
    }

    @Test func aLogThatCannotBeWrittenBreaksNothing() {
        // A file stands where the log's folder should be.
        let blocked = scratch.path + "/blocked"
        FileManager.default.createFile(atPath: blocked, contents: nil)
        PluginLog(path: blocked + "/plugin.log").write("lost")
        #expect(FileManager.default.fileExists(atPath: blocked + "/plugin.log") == false)
    }

    @Test func theTimeIsWrittenTheSameWhateverTheMacsLanguage() {
        // 1 January 2026, 12:00:00 UTC, in this Mac's own time zone.
        let date = Date(timeIntervalSince1970: 1_767_268_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { String(repeating: "0", count: (value ?? 0) < 10 ? 1 : 0) + String(value ?? 0) }
        let expected = "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day)) \(two(parts.hour)):\(two(parts.minute)):\(two(parts.second))"
        #expect(PluginLog.stamp(date) == expected)
    }

    @Test func theDefaultLogIsOutsideThePluginsPackage() {
        #expect(PluginLog.defaultPath.hasSuffix("/Library/Logs/ArchiveStatus/plugin.log"))
    }
}
