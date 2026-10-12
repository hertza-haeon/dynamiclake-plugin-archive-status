// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

struct PluginSettingsTests {
    private func file(_ json: String) -> Data {
        Data(json.utf8)
    }

    @Test func withoutAnythingTheDefaultsAreFirefoxDownloads() {
        let settings = PluginSettings.read(environment: [:], file: nil)
        #expect(settings.fileTypeIcons)
        #expect(settings.details == .time)
        #expect(settings.delayedDisplay)
        #expect(settings.awaySeconds == 60)
        #expect(settings.sneakPeekSeconds == 5)
        #expect(settings.remainSeconds == 0)
        #expect(settings.minimumSeconds == 10)
    }

    /// The order chosen (12 Oct 2026), which the log's line follows.
    @Test func theLogNamesTheSettingsInTheirOrder() {
        #expect(PluginSettings().summary == "fileTypeIcons on, extractionDetails time, delayedDisplay on, awayAfter 1 min, "
            + "sneakPeekDuration 5 s, remainVisible 0 s, minimumDuration 10 s")
    }

    @Test func delayedDisplayAndAwayAfterAreReadAsDynamicLakeWritesThem() {
        var settings = PluginSettings.read(environment: [:], file: file(#"{"values":{"waitWhenAway":false,"awayAfter":"5 min"}}"#))
        #expect(settings.delayedDisplay == false)
        #expect(settings.awaySeconds == 300)
        settings = PluginSettings.read(environment: ["DYNAMICLAKE_SETTING_WAIT_WHEN_AWAY": "1", "DYNAMICLAKE_SETTING_AWAY_AFTER": "10 min"],
                                       file: nil)
        #expect(settings.delayedDisplay)
        #expect(settings.awaySeconds == 600)
    }

    @Test(arguments: [("1 min", 1), ("3 min", 3), (" 10 minutes ", 10), ("5", 5), ("60 min", 60)])
    func aNumberOfMinutesIsReadHoweverItIsWritten(text: String, expected: Int) {
        #expect(PluginSettings.asMinutes(text) == expected)
    }

    @Test(arguments: ["0", "0 min", "61 min", "5 s", "soon", "", "-3", "1.5 min", String(repeating: "9", count: 60)])
    func aNumberOfMinutesOutOfRangeOrUnreadableKeepsTheDefault(text: String) {
        #expect(PluginSettings.asMinutes(text) == nil)
        #expect(PluginSettings.read(environment: [:], file: file(#"{"values":{"awayAfter":"\#(text)"}}"#)).awaySeconds == 60)
    }

    @Test func theMinimumDurationIsANumberOfSecondsFromZeroToSixty() {
        func minimum(_ json: String) -> Int {
            PluginSettings.read(environment: [:], file: file(json)).minimumSeconds
        }
        #expect(minimum(#"{"values":{"minimumDuration":0}}"#) == 0)
        #expect(minimum(#"{"values":{"minimumDuration":60}}"#) == 60)
        #expect(minimum(#"{"values":{"minimumDuration":17.0}}"#) == 17)
        #expect(minimum(#"{"values":{"minimumDuration":"4 s"}}"#) == 4)
        // Out of range, or no number: the default.
        #expect(minimum(#"{"values":{"minimumDuration":61}}"#) == 10)
        #expect(minimum(#"{"values":{"minimumDuration":-1}}"#) == 10)
        #expect(minimum(#"{"values":{"minimumDuration":true}}"#) == 10)
        #expect(PluginSettings.read(environment: ["DYNAMICLAKE_SETTING_MINIMUM_DURATION": "0.0"], file: nil).minimumSeconds == 0)
    }

    @Test func theSettingsFileIsReadAsDynamicLakeWritesIt() {
        let settings = PluginSettings.read(environment: [:], file: file(#"""
            {"identifier":"com.hertzahaeon.plugins.archive-status","schemaVersion":1,
             "values":{"fileTypeIcons":false,"extractionDetails":"All","sneakPeekDuration":"8 s","remainVisible":12}}
            """#))
        #expect(settings.fileTypeIcons == false)
        #expect(settings.details == .both, "the choice was called All until 0.2.8")
        #expect(settings.sneakPeekSeconds == 8)
        #expect(settings.remainSeconds == 12)
    }

    @Test func theEnvironmentGivesTheValuesAtLaunchAndTheFileWins() {
        let environment = [
            "DYNAMICLAKE_SETTING_FILE_TYPE_ICONS": "0",
            "DYNAMICLAKE_SETTING_EXTRACTION_DETAILS": "Speed",
            "DYNAMICLAKE_SETTING_SNEAK_PEEK_DURATION": "3 s",
            "DYNAMICLAKE_SETTING_REMAIN_VISIBLE": "20",
        ]
        var settings = PluginSettings.read(environment: environment, file: nil)
        #expect(settings.fileTypeIcons == false)
        #expect(settings.details == .speed)
        #expect(settings.sneakPeekSeconds == 3)
        #expect(settings.remainSeconds == 20)

        settings = PluginSettings.read(environment: environment, file: file(#"{"values":{"extractionDetails":"Time","remainVisible":0}}"#))
        #expect(settings.details == .time)
        #expect(settings.remainSeconds == 0)
        #expect(settings.sneakPeekSeconds == 3, "what the file doesn't say stays as the environment said")
    }

    @Test(arguments: [
        ("true", true), ("TRUE", true), ("1", true), ("yes", true), (" on ", true),
        ("false", false), ("0", false), ("no", false), ("off", false),
    ])
    func aSwitchIsReadHoweverItIsWritten(text: String, expected: Bool) {
        #expect(PluginSettings.asBool(text) == expected)
    }

    @Test func aSwitchThatSaysNothingClearKeepsItsDefault() {
        #expect(PluginSettings.asBool("maybe") == nil)
        #expect(PluginSettings.asBool("") == nil)
        #expect(PluginSettings.read(environment: [:], file: file(#"{"values":{"fileTypeIcons":"maybe"}}"#)).fileTypeIcons)
        #expect(PluginSettings.read(environment: [:], file: file(#"{"values":{"fileTypeIcons":0}}"#)).fileTypeIcons == false)
    }

    @Test(arguments: [("5 s", 5), ("5", 5), ("5 seconds", 5), (" 10 s. ", 10), ("3sec", 3), ("7,4 s", 7), ("2.6", 3)])
    func aNumberOfSecondsIsReadHoweverItIsWritten(text: String, expected: Int) {
        #expect(PluginSettings.asSeconds(text, 1...10) == expected)
    }

    @Test(arguments: ["0", "11", "5 min", "five", "", "-3", "1e9", String(repeating: "9", count: 60)])
    func aNumberOfSecondsOutOfRangeOrUnreadableKeepsTheDefault(text: String) {
        #expect(PluginSettings.asSeconds(text, 1...10) == nil)
    }

    @Test func trueIsNotANumberOfSeconds() {
        let settings = PluginSettings.read(environment: [:], file: file(#"{"values":{"remainVisible":true,"sneakPeekDuration":false}}"#))
        #expect(settings.remainSeconds == 0)
        #expect(settings.sneakPeekSeconds == 5)
    }

    @Test func bothIsReadUnderItsNewNameAndItsOldOne() {
        #expect(PluginSettings.read(environment: [:], file: file(#"{"values":{"extractionDetails":"Both"}}"#)).details == .both)
        #expect(PluginSettings.read(environment: [:], file: file(#"{"values":{"extractionDetails":"All"}}"#)).details == .both)
    }

    @Test func aChoiceThatIsNotOfferedKeepsTheDefault() {
        #expect(PluginSettings.read(environment: [:], file: file(#"{"values":{"extractionDetails":"Queue"}}"#)).details == .time)
        #expect(PluginSettings.read(environment: [:], file: file(#"{"values":{"extractionDetails":7}}"#)).details == .time)
    }

    @Test func aSettingsFileThatIsNotJSONLeavesTheDefaults() {
        #expect(PluginSettings.read(environment: [:], file: file("{ half a fi")) == PluginSettings())
        #expect(PluginSettings.read(environment: [:], file: file("[1, 2, 3]")) == PluginSettings())
    }

    // MARK: Read again every few seconds

    /// DynamicLake's settings file, changed by the test between two reads.
    private final class SettingsFile {
        var contents: Data?
        var reads = 0
    }

    private func reader(_ file: SettingsFile) -> SettingsReader {
        SettingsReader(environment: ["DYNAMICLAKE_PLUGIN_SETTINGS_PATH": "/settings.json"]) { _ in
            file.reads += 1
            return file.contents
        }
    }

    @Test func aChangeInDynamicLakeAppliesWithinFiveSecondsWithoutARestart() {
        let stored = SettingsFile()
        stored.contents = file(#"{"values":{"remainVisible":0}}"#)
        var reader = reader(stored)
        #expect(reader.refresh(now: 0) == "settings: fileTypeIcons on, extractionDetails time, delayedDisplay on, "
            + "awayAfter 1 min, sneakPeekDuration 5 s, remainVisible 0 s, minimumDuration 10 s")
        stored.contents = file(#"{"values":{"remainVisible":15,"extractionDetails":"Both"}}"#)
        #expect(reader.refresh(now: 2) == nil, "not read again yet")
        #expect(reader.settings.remainSeconds == 0)
        #expect(reader.refresh(now: 5) == "settings: fileTypeIcons on, extractionDetails both, delayedDisplay on, "
            + "awayAfter 1 min, sneakPeekDuration 5 s, remainVisible 15 s, minimumDuration 10 s")
        #expect(reader.settings.remainSeconds == 15)
        #expect(reader.refresh(now: 10) == nil, "nothing changed: nothing for the log")
        #expect(stored.reads == 3)
    }

    @Test func aFileCaughtWhileItIsBeingWrittenKeepsTheSettingsAndIsReadAgainSoon() {
        let stored = SettingsFile()
        stored.contents = file(#"{"values":{"remainVisible":9}}"#)
        var reader = reader(stored)
        _ = reader.refresh(now: 0)
        stored.contents = file(#"{"values":{"remainVis"#)
        #expect(reader.refresh(now: 5) == nil)
        #expect(reader.settings.remainSeconds == 9)
        stored.contents = file(#"{"values":{"remainVisible":3}}"#)
        #expect(reader.refresh(now: 5.5) == nil, "a second later, not sooner")
        #expect(reader.refresh(now: 6) != nil)
        #expect(reader.settings.remainSeconds == 3)
    }

    @Test func noSettingsFileYetMeansTheDefaults() {
        let stored = SettingsFile()
        var reader = reader(stored)
        #expect(reader.refresh(now: 0)?.hasPrefix("settings: fileTypeIcons on") == true)
        #expect(reader.settings == PluginSettings())
    }
}
