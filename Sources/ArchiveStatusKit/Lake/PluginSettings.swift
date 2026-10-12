// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The plugin's settings, as chosen in DynamicLake (`plugin.json` lists
/// them). Those it shares with Firefox Downloads have its names, choices
/// and defaults; which ones there are, and their order, is the
/// choice of 12 Oct 2026.
public struct PluginSettings: Equatable, Sendable {
    /// "Extraction Details": what follows the amounts while extracting.
    public enum Details: String, Sendable, CaseIterable {
        /// The speed.
        case speed
        /// The time left (the speed until it can be told).
        case time
        /// Both, taking turns.
        case both
    }

    /// "File-Type Icons": the archive's type in the pill. Off: the pill
    /// keeps the archive box.
    public var fileTypeIcons = true
    public var details = Details.time
    /// "Delayed Display": while the owner is away, a card that says how
    /// the extractions ended doesn't open its sneak peek; it opens when
    /// they are back.
    public var delayedDisplay = true
    /// "Away After": the owner counts as away after this long without
    /// touching the keyboard, the mouse or the trackpad, in seconds (or
    /// when the screen is locked).
    public var awaySeconds = 60
    /// "Minimum Duration": how long an extraction must take, at least, to
    /// get its pill and its card, in seconds. A shorter one shows nothing.
    /// At 0 every extraction shows.
    public var minimumSeconds = 10
    /// "Sneak Peek Duration": how long the sneak peek opens when an
    /// extraction is complete, in seconds.
    public var sneakPeekSeconds = 5
    /// "Remain Visible": how long the closed pill of a finished extraction
    /// stays after its sneak peek, in seconds. At 0 it goes with the sneak
    /// peek.
    public var remainSeconds = 0

    /// The longest sneak peek DynamicLake accepts, and the most "Remain
    /// Visible" goes to.
    static let maxSneakPeekSeconds = 10
    static let maxRemainSeconds = 30
    /// The most "Minimum Duration" goes to.
    static let maxMinimumSeconds = 60
    /// The most "Away After" is taken to say, in minutes.
    static let maxAwayMinutes = 60

    public init() {}

    /// The settings from what DynamicLake gives the plugin: its environment
    /// at launch (`DYNAMICLAKE_SETTING_…`), then the settings file, which
    /// wins. Anything missing or unreadable keeps its default.
    static func read(environment: [String: String], file: Data?) -> PluginSettings {
        var settings = PluginSettings()
        var stored: [String: Any] = [:]
        if let file, let json = try? JSONSerialization.jsonObject(with: file) as? [String: Any] {
            stored = json["values"] as? [String: Any] ?? json
        }
        func value(_ id: String) -> [Any] {
            // fileTypeIcons → FILE_TYPE_ICONS
            let snake = id.reduce(into: "") { $0 += ($1.isUppercase ? "_" : "") + $1.uppercased() }
            let names = ["DYNAMICLAKE_SETTING_\(snake)", "DYNAMICLAKE_SETTING_\(id.uppercased())", "DYNAMICLAKE_SETTING_\(id)"]
            // The file first, then the environment.
            return [stored[id]].compactMap { $0 } + names.compactMap { environment[$0] }
        }
        if let found = value("fileTypeIcons").lazy.compactMap(asBool).first { settings.fileTypeIcons = found }
        if let found = value("extractionDetails").lazy.compactMap(asDetails).first { settings.details = found }
        if let found = value("waitWhenAway").lazy.compactMap(asBool).first { settings.delayedDisplay = found }
        if let found = value("awayAfter").lazy.compactMap(asMinutes).first { settings.awaySeconds = found * 60 }
        if let found = value("minimumDuration").lazy.compactMap({ asSeconds($0, 0...maxMinimumSeconds) }).first {
            settings.minimumSeconds = found
        }
        if let found = value("sneakPeekDuration").lazy.compactMap({ asSeconds($0, 1...maxSneakPeekSeconds) }).first {
            settings.sneakPeekSeconds = found
        }
        if let found = value("remainVisible").lazy.compactMap({ asSeconds($0, 0...maxRemainSeconds) }).first {
            settings.remainSeconds = found
        }
        return settings
    }

    /// The settings in a line, for the log.
    var summary: String {
        "fileTypeIcons \(fileTypeIcons ? "on" : "off"), extractionDetails \(details.rawValue), "
            + "delayedDisplay \(delayedDisplay ? "on" : "off"), awayAfter \(awaySeconds / 60) min, "
            + "sneakPeekDuration \(sneakPeekSeconds) s, remainVisible \(remainSeconds) s, minimumDuration \(minimumSeconds) s"
    }

    // MARK: Values as they may arrive: true, 1, "1", "on", "5 s", "5 seconds"…

    private static func isBoolean(_ raw: Any) -> Bool {
        CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func asBool(_ raw: Any) -> Bool? {
        if isBoolean(raw), let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.doubleValue != 0 }
        guard let text = raw as? String else { return nil }
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    static func asDetails(_ raw: Any) -> Details? {
        guard let text = raw as? String else { return nil }
        let choice = text.trimmingCharacters(in: .whitespaces).lowercased()
        // (The choice was called "All" until 0.2.8: a setting kept from
        // then still says so.)
        return choice == "all" ? .both : Details(rawValue: choice)
    }

    /// A number of minutes (a number, or the title of a choice: `3 min`,
    /// `3 minutes`), from 1 up to `maxAwayMinutes`.
    static func asMinutes(_ raw: Any) -> Int? {
        var minutes: Double?
        if isBoolean(raw) {
            return nil
        } else if let number = raw as? NSNumber {
            minutes = number.doubleValue
        } else if let text = raw as? String, text.count <= 40,
                  let match = text.wholeMatch(of: #/\s*(\d+)\s*([A-Za-z]*)\.?\s*/#),
                  ["", "m", "min", "mins", "minute", "minutes"].contains(match.2.lowercased()) {
            minutes = Double(match.1)
        }
        guard let minutes, minutes.isFinite, minutes >= 1, minutes <= Double(maxAwayMinutes) else { return nil }
        return Int(minutes + 0.5)
    }

    /// A number of seconds (a number, or the title of a choice: `5 s`,
    /// `5 seconds`) when it is within `range`.
    static func asSeconds(_ raw: Any, _ range: ClosedRange<Int>) -> Int? {
        var seconds: Double?
        if isBoolean(raw) {
            return nil
        } else if let number = raw as? NSNumber {
            seconds = number.doubleValue
        } else if let text = raw as? String, text.count <= 40,
                  let match = text.wholeMatch(of: #/\s*(\d+(?:[.,]\d+)?)\s*([A-Za-z]*)\.?\s*/#),
                  ["", "s", "sec", "secs", "second", "seconds"].contains(match.2.lowercased()) {
            seconds = Double(match.1.replacing(",", with: "."))
        }
        guard let seconds, seconds.isFinite, seconds >= Double(range.lowerBound), seconds <= Double(range.upperBound) else {
            return nil
        }
        return Int(seconds + 0.5)
    }
}

/// Keeps the settings current: DynamicLake rewrites its settings file when
/// one changes, and the plugin reads it again every few seconds, so that a
/// change applies without a restart.
struct SettingsReader {
    /// How often the settings file is read again, in seconds.
    static let refreshEvery = 5.0

    private(set) var settings = PluginSettings()
    private let environment: [String: String]
    private let readFile: (String) -> Data?
    private var nextRead = -Double.infinity

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         readFile: @escaping (String) -> Data? = { FileManager.default.contents(atPath: $0) }) {
        self.environment = environment
        self.readFile = readFile
    }

    /// Reads the settings again when it is time. Returns a line for the log
    /// when something changed (and the first time).
    mutating func refresh(now: Double) -> String? {
        guard now >= nextRead else { return nil }
        let isFirst = nextRead == -Double.infinity
        nextRead = now + Self.refreshEvery
        var file: Data?
        if let path = environment["DYNAMICLAKE_PLUGIN_SETTINGS_PATH"] {
            file = readFile(path)
            // Caught while DynamicLake was writing it: as they were, and
            // again in a moment.
            if let file, (try? JSONSerialization.jsonObject(with: file)) == nil {
                nextRead = now + 1
                return nil
            }
        }
        let read = PluginSettings.read(environment: environment, file: file)
        guard read != settings || isFirst else { return nil }
        settings = read
        return "settings: " + read.summary
    }
}
