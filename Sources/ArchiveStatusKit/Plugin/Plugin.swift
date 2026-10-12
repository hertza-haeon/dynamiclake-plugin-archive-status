// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Shows items in the Finder and opens them, for the cards' two buttons.
/// The real one starts macOS's own `open`; tests put a stand-in in its
/// place.
public struct Opener {
    /// Shows the items selected in the Finder, where they are.
    public var reveal: ([String]) -> Void
    /// Does what a double-click on the item would do: a folder opens in a
    /// Finder window, a file in its app.
    public var open: (String) -> Void

    public init(reveal: @escaping ([String]) -> Void, open: @escaping (String) -> Void) {
        self.reveal = reveal
        self.open = open
    }

    public static var live: Opener {
        Opener(reveal: { run(["-R"] + $0) }, open: { run([$0]) })
    }

    /// Starts `/usr/bin/open`, by its full path, and doesn't wait for it.
    private static func run(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// The plugin itself: it looks at the unarchivers, follows the extractions
/// and keeps their card in the notch.
///
/// **One card for everything** (decided on 12 Oct 2026). The extractions
/// under way together are a group: the card adds up their sizes, shows
/// their number where the type is, and says at the end how they went, on
/// one card. An extraction that begins while others run joins them; one
/// that begins when all are over starts anew, on the same card if it is
/// still up.
///
/// Everything happens on one thread, one step after the other: a step looks
/// and brings the card up to date, then the plugin waits on DynamicLake's
/// socket until the next step is due or a button is pressed. Nothing runs
/// beside it, so there is nothing to protect from anything else.
public struct Plugin {
    /// How long an extraction must have been followed before its whole
    /// length is estimated, in seconds: the first readings of a speed are
    /// too rough to go by.
    static let judgeAfter = 1.5
    /// While it only counts up, a card is sent again at most this often.
    static let updateEvery = 0.6
    /// ...and not when its text is due to change by itself within this long.
    static let dueSoon = 0.3
    /// Whatever is due, a card that counts up is never sent again sooner
    /// than this: DynamicLake refuses updates that come too fast ("Update
    /// rate limit exceeded"), and the one that matters could be among them.
    static let updateFloor = 0.25
    /// The plugin never comes back sooner than this, whatever is due.
    static let shortestPause = 0.05
    /// The longest a look is taken to have lasted, in seconds (the Mac's
    /// clock, which tells it, can be set meanwhile).
    static let longestLook = 60.0
    /// A sneak peek asked for in the same breath as its card is ignored by
    /// DynamicLake: it is asked for this long after the card was made. And
    /// one asked for while the card takes the main place is dropped: it is
    /// asked for again this long after.
    static let peekAfterCreate = 0.2
    /// A card that goes with its sneak peek open asks for the sneak peek
    /// this much longer than it stays, so that it doesn't close first.
    static let peekMargin = 2
    /// A card lowered to give the main place back keeps the low priority
    /// this long: DynamicLake decides who moves up a moment after.
    static let handBack = 0.8
    /// What is to be said waits for the owner to be back at most this
    /// long, in seconds.
    static let holdMax = 12 * 3600.0
    /// While it waits, whether they are back is asked this often.
    static let awayCheckEvery = 1.0

    public private(set) var tracker: Tracker
    private var lookout: any Lookout
    private var link: (any LakeLink)?
    private var settings: SettingsReader
    private let surroundings: Surroundings
    private let presence: Presence
    private let face: CardFace
    private let opener: Opener
    private let supportsPresent: Bool
    private let log: (String) -> Void

    /// The group: the extractions the card stands for while any of them is
    /// under way, in the order they joined, each as last seen (those that
    /// are over stay in it, counted, until all are).
    private var members: [Extraction] = []
    /// Why the first of them got a card, for the log.
    private var whyShown = ""
    /// Extractions that are over, complete or stopped short, and still to
    /// be said on the card.
    private var unsaid: [Extraction] = []
    /// The card, while it is up.
    private var card: Card?
    private var cardsMade = 0

    /// The plugin's one card in the notch.
    private struct Card {
        let activityID: String
        let createdAt: Double
        /// Since when it shows what it shows now: extractions under way
        /// (an archive box at first, then the type), or how they ended.
        var since: Double
        var sent: Surfaces
        var sentAt: Double
        /// When what the card says changes by itself.
        var changesAt: Double?
        /// Whether it says how the extractions ended.
        var saysEnd = false
        /// When that was said to the owner (the sneak peek opened): the
        /// card stays its time from then.
        var endShownAt: Double?
        /// Since when that waits for the owner to be back.
        var heldSince: Double?
        /// Whether anything of the extractions is there for Show in Finder.
        var hasItems = false
        /// Since when its status line shows: it stays still at first.
        var lineSince = 0.0
        var linePhase = CardFace.LinePhase.whole
        /// A sneak peek still to ask for, and when.
        var peekOwed: (seconds: Int, at: Double)?
        /// Until when the sneak peek the plugin opened is open.
        var peekUntil: Double?
        /// Whether it has the high priority, for what it says.
        var isRaised = false
        /// Lowered to give the main place back: its usual priority again
        /// at that time.
        var normalAt: Double?
    }

    /// - Parameters:
    ///   - link: DynamicLake; nothing when the plugin is run by hand, to
    ///     watch and write its log only.
    ///   - features: what this DynamicLake offers (`numericText`,
    ///     `presentSneakPeek`), from its environment.
    public init(lookout: any Lookout, link: (any LakeLink)?, surroundings: Surroundings = .live,
                presence: Presence = .live,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                opener: Opener = .live, log: @escaping (String) -> Void) {
        self.init(lookout: lookout, link: link, surroundings: surroundings, presence: presence,
                  settings: SettingsReader(environment: environment),
                  features: Self.features(environment), ruler: .system(), opener: opener, log: log)
    }

    init(lookout: any Lookout, link: (any LakeLink)?, surroundings: Surroundings, presence: Presence = .live,
         settings: SettingsReader, features: Set<String>, ruler: TextRuler, opener: Opener, log: @escaping (String) -> Void) {
        self.tracker = Tracker(surroundings: surroundings)
        self.lookout = lookout
        self.link = link
        self.settings = settings
        self.surroundings = surroundings
        self.presence = presence
        self.face = CardFace(ruler: ruler, pictures: Pictures(), numericText: features.contains("numericText"))
        self.opener = opener
        self.supportsPresent = features.contains("presentSneakPeek")
        self.log = log
    }

    static func features(_ environment: [String: String]) -> Set<String> {
        Set((environment["DYNAMICLAKE_PLUGIN_FEATURES"] ?? "").split(separator: ",").map(String.init))
    }

    // MARK: The loop

    /// Runs until DynamicLake closes the connection (or, run by hand, until
    /// the program is stopped).
    public mutating func run() {
        var incoming: [LakeIncoming] = []
        while true {
            do {
                let pause = try step(now: ProcessInfo.processInfo.systemUptime, incoming: incoming)
                if link != nil {
                    incoming = try link?.receive(wait: pause) ?? []
                } else {
                    incoming = []
                    Thread.sleep(forTimeInterval: pause)
                }
            } catch {
                log("DynamicLake closed the connection: stopping")
                return
            }
        }
    }

    /// One step: the settings, the buttons pressed, a look, the card.
    /// Returns how long to wait before the next, in seconds.
    mutating func step(now: Double, incoming: [LakeIncoming]) throws(LakeError) -> Double {
        if let changed = settings.refresh(now: now) {
            log(changed)
        }
        for message in incoming {
            switch message {
            case .action(let action): press(action)
            case .refusal(let answer): log("DynamicLake refused a message: \(answer)")
            }
        }

        // A look can take a while: reading an index, or going through
        // every file of a large archive at its end. What follows is as of
        // when it was over, not as of when it began. (Seen on a real
        // Mac, 12 Oct 2026: after half a second spent on the 150,000 files
        // of an archive, the sneak peek was asked for twice within a
        // millisecond, where a fifth of a second must lie between.)
        let began = surroundings.wallClock()
        let processes = lookout.look(now: now)
        for line in tracker.step(now: now, processes: processes) {
            log(line)
        }
        let now = now + min(max(0, surroundings.wallClock() - began), Self.longestLook)

        var next = lookout.pause(attention: tracker.attention, now: now)
        guard link != nil else { return next }

        // 1. The group, as it is now: its extractions under way, and those
        //    of it that are over.
        let underWay = Dictionary(uniqueKeysWithValues: tracker.extractions.map { ($0.id, $0) })
        for index in members.indices where members[index].ending == nil {
            let id = members[index].id
            if let current = underWay[id] {
                members[index] = current
            } else if let ended = tracker.ended.last(where: { $0.id == id }) {
                members[index] = ended
            } else {
                members[index].ending = .unknown
            }
        }
        // 2. An extraction long enough to show joins it, or begins one.
        //    A shorter one is left out of everything.
        for extraction in underWay.values.sorted(by: { $0.id < $1.id })
        where members.contains(where: { $0.id == extraction.id }) == false {
            if let why = reasonToShow(extraction, now: now) {
                join(extraction, because: why)
            } else {
                // Back, at the latest, when it has lasted long enough.
                next = min(next, extraction.startedAt + Double(settings.settings.minimumSeconds) - now)
            }
        }
        // 3. Under way: the card says how far. All over: how they ended.
        if members.contains(where: { $0.ending == nil }) {
            try showProgress(now: now)
        } else if members.isEmpty == false {
            try endGroup(now: now)
        }
        try showEnd(now: now)

        // 4. Lowered to give the main place back: its usual priority again.
        if let at = card?.normalAt, now >= at, let activityID = card?.activityID {
            try link?.send(.priority(activityID, "normal"))
            card?.normalAt = nil
        }

        if let card {
            // (Only what is still to come: something due that has passed
            // was dealt with in this step, or waits for the next look.)
            for due in [card.changesAt, card.peekOwed?.at, card.normalAt] {
                if let due, due > now { next = min(next, due - now) }
            }
            if let endShownAt = card.endShownAt, endShownAt + keepSeconds > now {
                next = min(next, endShownAt + keepSeconds - now)
            }
            if card.heldSince != nil {
                next = min(next, Self.awayCheckEvery)
            }
        }
        return max(Self.shortestPause, next)
    }

    // MARK: Which extractions the card stands for

    /// Whether an extraction gets its pill and its card now, and why (for
    /// the log). An extraction shorter than "Minimum Duration" gets none
    /// (decided on 12 Oct 2026): the plugin can't know how long one will
    /// take, so it works that out from how fast it goes, a moment after it
    /// began. Expected to take long enough, it shows at once; expected to
    /// be short, it shows nothing, unless it turns out longer after all.
    /// Without a total nothing can be worked out: it shows once it has
    /// lasted that long.
    ///
    /// One that waits for its turn (The Unarchiver takes its archives one
    /// after the other) hasn't begun: how long it has waited says nothing
    /// of its length. Behind others that are running, it is judged by
    /// their speed; alone, when it begins.
    private func reasonToShow(_ extraction: Extraction, now: Double) -> String? {
        let minimum = Double(settings.settings.minimumSeconds)
        if extraction.isWaiting {
            if minimum <= 0 { return "every extraction shows" }
            let speed = members.filter { $0.ending == nil && $0.isWaiting == false }.reduce(0) { $0 + $1.speed }
            guard let total = extraction.total, speed > 0 else { return nil }
            let expected = Double(total) / speed
            guard expected >= minimum else { return nil }
            return "it waits for its turn, and is expected to take about \(Int(expected.rounded())) s then; "
                + "\(settings.settings.minimumSeconds) s is the least"
        }
        let elapsed = now - extraction.startedAt
        if elapsed >= minimum {
            return minimum > 0 ? "it has lasted \(settings.settings.minimumSeconds) s" : "every extraction shows"
        }
        guard let total = extraction.total, elapsed >= Self.judgeAfter, extraction.speed > 0 else { return nil }
        let expected = elapsed + Double(total - min(total, extraction.written)) / extraction.speed
        guard expected >= minimum else { return nil }
        return "expected to take about \(Int(expected.rounded())) s, and \(settings.settings.minimumSeconds) s is the least"
    }

    private mutating func join(_ extraction: Extraction, because why: String) {
        members.append(extraction)
        if members.count == 1 {
            whyShown = why
        } else {
            log("\(extraction.name): joins the card (\(why)): it stands for \(members.count) extractions now")
        }
    }

    /// What the card stands for: the one extraction, or their number.
    private var subject: CardFace.Subject {
        if members.count == 1, let only = members.first { return .one(name: only.name) }
        return .several(members.count)
    }

    /// How far the group is, its extractions added up (decided on 12 Oct
    /// 2026).
    ///
    /// - The sizes: those of the extractions whose size is known. One that
    ///   is over counts as done, for what it wrote, so that the ring ends
    ///   full.
    /// - The time left: that of the one that will be the last to finish.
    ///   They run at the same time: a sum would be wrong.
    /// - An extraction whose size can't be told counts in the number only,
    ///   while others with a size run. When only such ones are left, there
    ///   is no total: the ring spins, and the amount is all that the group
    ///   has written.
    /// - One that waits for its turn counts with its size from the start,
    ///   and adds to the time left what it will take at the speed of
    ///   those that run. While none has begun, the ring spins.
    private var progress: CardFace.Progress {
        let startedAt = members.map(\.startedAt).min() ?? 0
        let running = members.filter { $0.ending == nil }
        let sizedRunning = running.filter { $0.total != nil }
        let noneBegun = running.allSatisfy(\.isWaiting) && members.allSatisfy { $0.written == 0 }
        guard sizedRunning.isEmpty == false else {
            let written = members.reduce(UInt64(0)) { $0.addingSaturating($1.written) }
            return CardFace.Progress(written: written, total: nil, speed: running.reduce(0) { $0 + $1.speed },
                                     secondsLeft: nil, secondsLeftChangeAt: nil, startedAt: startedAt, isWaiting: noneBegun)
        }
        var written: UInt64 = 0
        var total: UInt64 = 0
        for member in members {
            guard let size = member.total else { continue }
            let done = min(member.written, size)
            written = written.addingSaturating(done)
            // (Stopped short: there is no more of it to come.)
            total = total.addingSaturating(member.ending == nil || member.ending == .complete ? size : done)
        }
        // Until every one of those that run can tell its time left, none
        // is told. Those that wait take, each in its turn, what their size
        // makes at the speed of those that run.
        let begun = sizedRunning.filter { $0.isWaiting == false }
        let speed = begun.reduce(0) { $0 + $1.speed }
        var secondsLeft: Int?
        if begun.isEmpty == false, begun.allSatisfy({ $0.secondsLeft != nil }) {
            let waiting = sizedRunning.filter(\.isWaiting).reduce(UInt64(0)) { $0.addingSaturating($1.total ?? 0) }
            if waiting == 0 {
                secondsLeft = begun.compactMap(\.secondsLeft).max()
            } else if speed > 0 {
                secondsLeft = (begun.compactMap(\.secondsLeft).max() ?? 0) + Int((Double(waiting) / speed).rounded(.up))
            }
        }
        return CardFace.Progress(written: written, total: total, speed: speed, secondsLeft: secondsLeft,
                                 secondsLeftChangeAt: secondsLeft == nil ? nil : begun.compactMap(\.secondsLeftChangeAt).min(),
                                 startedAt: startedAt, isWaiting: noneBegun)
    }

    /// Since when the group is stalled: when none of its extractions under
    /// way writes anything.
    private var stalledSince: Double? {
        // (One that waits for its turn writes nothing, and isn't stalled.)
        let running = members.filter { $0.ending == nil && $0.isWaiting == false }
        guard running.isEmpty == false, running.allSatisfy({ $0.stalledSince != nil }) else { return nil }
        return running.compactMap(\.stalledSince).max()
    }

    // MARK: The card while extractions are under way

    private mutating func showProgress(now: Double) throws(LakeError) {
        guard var card else {
            // No card yet: this one is made.
            cardsMade += 1
            let activityID = "extraction-\(cardsMade)"
            let built = face.extracting(progress, of: subject, activityID: activityID, cardSince: now, stalledSince: stalledSince,
                                        settings: settings.settings, now: now)
            try link?.send(.create(activityID, surfaces: built.surfaces))
            self.card = Card(activityID: activityID, createdAt: now, since: now, sent: built.surfaces, sentAt: now,
                             changesAt: built.changesAt)
            log("\(members.first?.name ?? ""): its card is shown (\(whyShown))")
            return
        }
        if card.saysEnd {
            // The card still says how the last ones ended: it is taken
            // over at once. What it said was said, unless it was waiting
            // for the owner to be back: that is said with these.
            if card.endShownAt != nil {
                unsaid.removeAll()
            }
            card.saysEnd = false
            card.endShownAt = nil
            card.heldSince = nil
            card.peekOwed = nil
            card.peekUntil = nil
            card.since = now
            if card.isRaised {
                // It had the main place for what it said: given back.
                try link?.send(.priority(card.activityID, "low"))
                card.isRaised = false
                card.normalAt = now + Self.handBack
            }
            let built = face.extracting(progress, of: subject, activityID: card.activityID, cardSince: card.since,
                                        stalledSince: stalledSince, settings: settings.settings, now: now)
            try link?.send(.update(card.activityID, surfaces: built.surfaces))
            card.sent = built.surfaces
            card.sentAt = now
            card.changesAt = built.changesAt
            self.card = card
            log("\(members.first?.name ?? ""): the card is taken over (\(whyShown))"
                + (unsaid.isEmpty ? "" : "; \(names(unsaid)) will be said with it"))
            return
        }
        let built = face.extracting(progress, of: subject, activityID: card.activityID, cardSince: card.since,
                                    stalledSince: stalledSince, settings: settings.settings, now: now)
        // Sent when it says something new: at once when its text was due to
        // change, otherwise not more often than DynamicLake is meant to
        // redraw, and not just before a change that is due anyway (which
        // will carry the new amounts too).
        let wasDue = card.changesAt.map { now >= $0 } ?? false
        let dueSoon = built.changesAt.map { $0 > now && $0 - now <= Self.dueSoon } ?? false
        let sinceSent = now - card.sentAt
        if built.surfaces != card.sent, sinceSent >= Self.updateFloor,
           wasDue || (sinceSent >= Self.updateEvery && dueSoon == false) {
            try link?.send(.update(card.activityID, surfaces: built.surfaces))
            card.sent = built.surfaces
            card.sentAt = now
        }
        card.changesAt = built.changesAt
        self.card = card
    }

    // MARK: The card when they are over

    /// Every extraction of the group is over: what the card will say of
    /// them. One whose end can't be told is left out, saying nothing that
    /// can't be known (decided on 12 Oct 2026).
    private mutating func endGroup(now: Double) throws(LakeError) {
        let untold = members.filter { $0.ending != .complete && $0.ending != .stopped }
        unsaid += members.filter { $0.ending == .complete || $0.ending == .stopped }
        members.removeAll()
        guard var card else {
            unsaid.removeAll()
            return
        }
        guard unsaid.isEmpty == false else {
            try link?.send(.dismiss(card.activityID))
            self.card = nil
            log("\(names(untold)): its card is taken away (whether the extraction got to its end can't be told)")
            return
        }
        if untold.isEmpty == false {
            log("\(names(untold)): left out of what the card says (whether the extraction got to its end can't be told)")
        }
        card.saysEnd = true
        card.endShownAt = nil
        card.heldSince = nil
        card.peekOwed = nil
        card.hasItems = unsaid.contains { $0.revealPaths.contains { surroundings.fileState($0) != .missing } }
        self.card = card
    }

    /// The card that says how the extractions ended: said at once, with
    /// the sneak peek opened, or when the owner is back ("Delayed
    /// Display"); then kept its time, and taken away.
    private mutating func showEnd(now: Double) throws(LakeError) {
        guard var card, card.saysEnd else { return }

        if card.endShownAt == nil {
            let isAway = settings.settings.delayedDisplay && presence.isAway(after: settings.settings.awaySeconds)
            if card.heldSince == nil, isAway {
                // The owner is away: the card says it, closed, and opens
                // when they are back.
                card.heldSince = now
                card.lineSince = now
                let built = endFace(card, now: now)
                try link?.send(.update(card.activityID, surfaces: built.surfaces))
                card.sent = built.surfaces
                card.sentAt = now
                card.changesAt = nil
                card.linePhase = built.linePhase
                self.card = card
                log("\(names(unsaid)): \(word) while you're away; shown when you're back")
                return
            }
            if let since = card.heldSince {
                if now - since > Self.holdMax {
                    // Waited long enough: it stays its usual time from now,
                    // and goes.
                    card.heldSince = nil
                    card.endShownAt = now
                    self.card = card
                    return
                }
                guard isAway == false else { return }
                log("\(names(unsaid)): \(word), shown now that you're back (\(Int(now - since)) s later)")
            }
            // Its last word: the check or the cross, the name or the
            // number, and the sneak peek opened. The card takes the main
            // place for it (another app's activity may have it: the
            // plugin can't tell), and a sneak peek asked for while it
            // does is dropped: it is asked for again a moment later.
            card.heldSince = nil
            card.endShownAt = now
            card.lineSince = now
            let built = endFace(card, now: now)
            var message = LakeMessage.update(card.activityID, surfaces: built.surfaces)
            if supportsPresent {
                message.priority = "high"
                card.isRaised = true
                card.normalAt = nil
                if now - card.createdAt >= Self.peekAfterCreate {
                    message.presentSneakPeek = presentSeconds
                    card.peekUntil = now + Double(presentSeconds)
                    card.peekOwed = (presentSeconds, now + Self.peekAfterCreate)
                } else {
                    card.peekOwed = (presentSeconds, card.createdAt + Self.peekAfterCreate)
                }
            }
            try link?.send(message)
            card.sent = built.surfaces
            card.sentAt = now
            card.changesAt = built.changesAt
            card.linePhase = built.linePhase
            self.card = card
            log("\(names(unsaid)): \(word) is shown" + (supportsPresent ? ", its sneak peek open for \(presentSeconds) s" : ""))
            return
        }

        if let owed = card.peekOwed, now >= owed.at {
            // The sneak peek that couldn't be asked for with the card, or
            // asked for again now that the card has the main place.
            card.peekOwed = nil
            card.endShownAt = now                       // (it stays its usual time, from now)
            card.lineSince = now
            let built = endFace(card, now: now)
            try link?.send(.update(card.activityID, surfaces: built.surfaces, presentSneakPeek: owed.seconds))
            card.peekUntil = now + Double(owed.seconds)
            card.sent = built.surfaces
            card.sentAt = now
            card.changesAt = built.changesAt
            card.linePhase = built.linePhase
            self.card = card
            return
        }

        if let endShownAt = card.endShownAt, now >= endShownAt + keepSeconds, card.peekOwed == nil {
            // (Dismissed, it leaves the main place to whatever comes next.)
            try link?.send(.dismiss(card.activityID))
            log("\(names(unsaid)): its card has had its time and goes")
            self.card = nil
            unsaid.removeAll()
            return
        }

        let built = endFace(card, now: now)
        if built.surfaces != card.sent {
            var message = LakeMessage.update(card.activityID, surfaces: built.surfaces)
            // The line starts to scroll while the sneak peek the plugin
            // opened is still open. DynamicLake only shows a new text in it
            // when it is asked for again: for the time that is left.
            if supportsPresent, card.linePhase == .held, built.linePhase == .scrolling,
               let until = card.peekUntil, until - now >= 0.5 {
                message.presentSneakPeek = max(1, min(PluginSettings.maxSneakPeekSeconds, Int((until - now).rounded())))
            }
            try link?.send(message)
            card.sent = built.surfaces
            card.sentAt = now
        }
        card.changesAt = built.changesAt
        card.linePhase = built.linePhase
        self.card = card
    }

    /// The face of the card that says how the extractions ended: one alone
    /// as `Complete` or `Stopped`, with its name; several by their number.
    private func endFace(_ card: Card, now: Double) -> CardFace.Built {
        if unsaid.count == 1, let only = unsaid.first {
            if only.ending == .stopped {
                return face.stopped(only, activityID: card.activityID, cardSince: card.createdAt, lineSince: card.lineSince,
                                    hasLeftovers: card.hasItems, settings: settings.settings, now: now)
            }
            return face.complete(only, activityID: card.activityID, cardSince: card.createdAt, lineSince: card.lineSince,
                                 settings: settings.settings, now: now)
        }
        return face.summary(completed: unsaid.filter { $0.ending == .complete }.count, of: unsaid.count,
                            activityID: card.activityID, cardSince: card.createdAt, lineSince: card.lineSince,
                            hasItems: card.hasItems, settings: settings.settings, now: now)
    }

    /// What the card says of them, for the log.
    private var word: String {
        if unsaid.count == 1, let only = unsaid.first {
            return only.ending == .complete ? "Complete" : "Stopped"
        }
        return CardFace.summaryText(completed: unsaid.filter { $0.ending == .complete }.count, of: unsaid.count)
    }

    /// Their names in a line, for the log.
    private func names(_ extractions: [Extraction]) -> String {
        extractions.map(\.name).joined(separator: ", ")
    }

    /// A finished or stopped card goes with its sneak peek still open
    /// ("Remain Visible" at 0), not after a while as the closed pill.
    private var goesWithPeek: Bool { settings.settings.remainSeconds <= 0 }

    /// How long the sneak peek is asked for: the setting "Sneak Peek
    /// Duration", and a little more for a card that goes with it open,
    /// within what DynamicLake accepts.
    private var presentSeconds: Int {
        let seconds = settings.settings.sneakPeekSeconds + (goesWithPeek ? Self.peekMargin : 0)
        return max(1, min(PluginSettings.maxSneakPeekSeconds, seconds))
    }

    /// How long a finished card stays: its sneak peek, then the closed pill
    /// for the time of "Remain Visible".
    private var keepSeconds: Double {
        let peek = settings.settings.sneakPeekSeconds
        if goesWithPeek == false { return Double(peek + settings.settings.remainSeconds) }
        // (The longest sneak peek there is: gone just before it would close.)
        return peek + Self.peekMargin > PluginSettings.maxSneakPeekSeconds ? Double(peek) - 0.25 : Double(peek)
    }

    // MARK: The buttons

    private func press(_ action: LakeAction) {
        guard let card, card.activityID == action.activityID else { return }
        // What the card stands for at this moment.
        let shown = card.saysEnd ? unsaid : members
        guard shown.isEmpty == false else { return }
        let what = names(shown)
        let exists = { (path: String) in self.surroundings.fileState(path) != .missing }
        switch action.actionID.split(separator: ":").first {
        case "show":
            // What is there of each; before anything is, the folder it
            // goes into.
            var found: [String] = []
            for extraction in shown {
                var paths = extraction.revealPaths.filter(exists)
                if paths.isEmpty {
                    let folder = extraction.result.map(ArchiveName.folder) ?? extraction.destination
                    paths = [folder].compactMap { $0 }.filter(exists)
                }
                for path in paths where found.contains(path) == false {
                    found.append(path)
                }
            }
            guard found.isEmpty == false else {
                log("\(what): Show in Finder: nothing of it is there yet")
                return
            }
            opener.reveal(Array(found.prefix(Tracker.maxRevealed)))
            log("\(what): Show in Finder")
        case "open":
            // Open is on the card of one finished extraction only.
            guard card.saysEnd, shown.count == 1, let only = shown.first, only.ending == .complete,
                  let result = only.result, exists(result) else {
                log("\(what): Open: the extracted item isn't there")
                return
            }
            opener.open(result)
            log("\(what): Open")
        default:
            break
        }
    }
}
