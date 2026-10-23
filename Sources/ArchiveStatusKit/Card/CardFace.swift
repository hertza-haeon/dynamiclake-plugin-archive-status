// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What a card shows, in Firefox Downloads' look:
///
/// ```
///              pill                    sneak peek
///              left      right         left          center                    right
/// extracting   type      blue ring     blue folder   0.85/2.56GB · 11 seconds  33%
/// waiting      type      blue ring     (nothing)     Waiting • photos.zip
/// stalled      type      red ...       blue folder   Stalled • photos.zip      33%
/// complete     type      green check   blue folder   Complete • photos.zip     blue open
/// done         type      grey bar      blue folder   Done • photos.zip         blue open
/// stopped      type      red cross     blue folder   Stopped • photos.zip
/// incomplete   type      red ring      blue folder   Incomplete • photos.zip
/// ```
///
/// (Waiting: the tool has the archive and has written none of it yet; it
/// asks for a password, or reads the archive through first; the ring
/// spins. On the stopped card the folder is there only when something was
/// left. `Incomplete`: the tool went to the archive's end and files are
/// missing.
/// `Done` is said of an extraction whose result is in place and couldn't
/// be checked file by file: `Complete` is kept for one that was.)
///
/// "type" is the archive's type in a blue circle (`zip`, `rar`, `7z`). A
/// card's first seconds show an archive box there instead; the box stays
/// with the setting "File-Type Icons" off. Beside another activity that has
/// the main place, a card is DynamicLake's small capsule: it shows "type"
/// alone.
///
/// The plugin has one card. Several extractions under way share it (decided
/// on 12 Oct 2026): their number stands where the type is, their sizes
/// are added up, and at the end it says `3 Extractions Completed`, or
/// `2/3 Extractions Completed` with the red cross, with the folder alone
/// (`Done` for `Completed`, and the grey bar for the check, when one of
/// them couldn't be checked).
struct CardFace {
    /// A card shows the archive box this long, then the archive's type.
    static let boxSeconds = 4.0
    /// "Extraction Details" on All: the speed and the time left take turns,
    /// this long each.
    static let turnSeconds = 3.0
    /// A status line too long for the sneak peek stays still this long, cut
    /// short, before it starts to scroll.
    static let holdSeconds = 3.0
    /// The most characters of a type the circle shows.
    static let typeCharacters = 4
    /// The longest text DynamicLake accepts.
    static let maxTextCharacters = 240

    let ruler: TextRuler
    let pictures: Pictures
    /// Whether DynamicLake offers text whose digits change in place.
    let numericText: Bool

    /// A status line that doesn't fit is first shown cut short, which stays
    /// still, then whole, which scrolls.
    enum LinePhase: Equatable {
        case whole
        case held
        case scrolling
    }

    /// What a card stands for: one extraction, known by its archive's
    /// name, or several, known by their number.
    enum Subject: Equatable {
        case one(name: String)
        case several(Int)

        /// How the status lines name it: `photos.zip`, `3 Extractions`.
        var text: String {
            switch self {
            case .one(let name): name
            case .several(let count): "\(count) Extractions"
            }
        }
    }

    /// How far the extraction is, or the extractions together.
    struct Progress: Equatable {
        var written: UInt64
        /// Nothing where it can't be told: the ring spins.
        var total: UInt64?
        var speed: Double
        var secondsLeft: Int?
        var secondsLeftChangeAt: Double?
        /// From when the turns of "Both" are counted.
        var startedAt: Double
        /// Nothing is begun yet (the tool has the archive, and has not
        /// written its first file): the ring spins until it is.
        var isWaiting = false

        init(written: UInt64, total: UInt64?, speed: Double, secondsLeft: Int?, secondsLeftChangeAt: Double?, startedAt: Double,
             isWaiting: Bool = false) {
            self.written = written
            self.total = total
            self.speed = speed
            self.secondsLeft = secondsLeft
            self.secondsLeftChangeAt = secondsLeftChangeAt
            self.startedAt = startedAt
            self.isWaiting = isWaiting
        }

        init(_ extraction: Extraction) {
            self.init(written: extraction.written, total: extraction.total, speed: extraction.speed,
                      secondsLeft: extraction.secondsLeft, secondsLeftChangeAt: extraction.secondsLeftChangeAt,
                      startedAt: extraction.startedAt, isWaiting: extraction.isWaiting)
        }
    }

    /// A face, and when its text next changes by itself (the time left
    /// counting down, the turns, a held line starting to scroll).
    struct Built: Equatable {
        var surfaces: Surfaces
        var changesAt: Double?
        var linePhase = LinePhase.whole
    }

    // MARK: The pictures

    /// The archive's type as the blue circle shows it (`photos.ZIP` gives
    /// `zip`; four characters at most), or nothing when its name has no
    /// ending that can be shown: then the archive box stays.
    static func typeText(of name: String) -> String {
        let ending = ArchiveName.typeExtension(of: name)
        guard ending.isEmpty == false, ending.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return "" }
        return String(ending.prefix(typeCharacters))
    }

    /// The blue circle with a type in it, or with the archive box for "".
    private func icon(_ type: String) -> Component {
        if let picture = pictures.base64(type.isEmpty ? .box : .type(type)) {
            return .picture(base64: picture)
        }
        return .symbol("archivebox", tint: "blue")
    }

    /// What the circle says of the card's subject: the archive's type, or
    /// the number of extractions.
    private static func circleText(_ subject: Subject) -> String {
        switch subject {
        case .one(let name): typeText(of: name)
        case .several(let count): String(count)
        }
    }

    /// The pill's left side: the box for the card's first seconds, with the
    /// setting off, or for a name without an ending; else the type. The
    /// number of several extractions is there from the moment there are
    /// several, whatever the setting says (decided on 12 Oct 2026: it is
    /// no file type).
    private func pillIcon(_ subject: Subject, isOver: Bool, cardSince: Double, settings: PluginSettings, now: Double) -> Component {
        if case .several = subject { return icon(Self.circleText(subject)) }
        guard settings.fileTypeIcons else { return icon("") }
        if isOver == false, now < cardSince + Self.boxSeconds { return icon("") }
        return icon(Self.circleText(subject))
    }

    /// The capsule: the type from the first second, without the box's turn
    /// (it is drawn once and must stay true).
    private func capsule(_ subject: Subject, settings: PluginSettings) -> Component {
        if case .several = subject { return icon(Self.circleText(subject)) }
        return icon(settings.fileTypeIcons ? Self.circleText(subject) : "")
    }

    // MARK: The buttons

    /// Show in Finder: a blue folder in a blue circle.
    static func showButton(_ activityID: String) -> Component {
        .button(title: "Show in Finder", symbol: "folder.fill", actionID: "show:\(activityID)", tint: "blue")
    }

    /// Open: an arrow in an app's square (macOS's sign for "open in its
    /// app") in a blue circle, across from Show in Finder's folder.
    static func openButton(_ activityID: String) -> Component {
        .button(title: "Open", symbol: "arrow.up.forward.app.fill", actionID: "open:\(activityID)", tint: "blue")
    }

    // MARK: Extracting

    /// `stalledSince` is when the extraction was found to have stalled
    /// (nothing written for a while), if it has: the card then says so.
    func extracting(_ extraction: Extraction, activityID: String, cardSince: Double, stalledSince: Double? = nil,
                    settings: PluginSettings, now: Double) -> Built {
        extracting(Progress(extraction), of: .one(name: extraction.name), activityID: activityID, cardSince: cardSince,
                   stalledSince: stalledSince, settings: settings, now: now)
    }

    /// The same for whatever the card stands for: one extraction, or
    /// several, with their amounts added up.
    func extracting(_ progress: Progress, of subject: Subject, activityID: String, cardSince: Double,
                    stalledSince: Double? = nil, settings: PluginSettings, now: Double) -> Built {
        var changesAt: Double?
        var linePhase = LinePhase.whole
        let line: String
        if let stalledSince {
            let status = statusLine("Stalled", name: subject.text, since: stalledSince, now: now)
            (line, linePhase, changesAt) = (status.text, status.phase, status.changesAt)
        } else if progress.isWaiting {
            // Nothing of it is written yet (the tool asks for a password,
            // or reads the archive through first): no amounts to show.
            let status = statusLine("Waiting", name: subject.text, since: max(cardSince, progress.startedAt), now: now)
            (line, linePhase, changesAt) = (status.text, status.phase, status.changesAt)
        } else if let total = progress.total {
            let detail = detail(progress, settings: settings, now: now, changesAt: &changesAt)
            line = Self.line(CardText.pair(done: progress.written, total: total), detail)
        } else {
            // (No total: no time left to tell, so the speed stands in for it.)
            line = Self.line(CardText.amount(progress.written), CardText.speed(progress.speed))
        }
        if case .one = subject, now < cardSince + Self.boxSeconds {
            changesAt = min(changesAt ?? .infinity, cardSince + Self.boxSeconds)      // the box gives way to the type
        }
        let isOnlyWaiting = progress.isWaiting && stalledSince == nil
        var ring = Component.ring(value: progress.isWaiting ? nil : CardText.fraction(done: progress.written, total: progress.total),
                                  tint: "blue")
        if stalledSince != nil, let dots = pictures.base64(.stalled) {
            ring = .picture(base64: dots)
        }
        let surfaces = Surfaces(
            pillLeft: pillIcon(subject, isOver: false, cardSince: cardSince, settings: settings, now: now),
            pillRight: ring,
            // (While it waits nothing is there to show, and nothing to count.)
            peekLeft: isOnlyWaiting ? nil : Self.showButton(activityID),
            peekCenter: .text(line, style: "marquee"),
            peekRight: isOnlyWaiting ? nil : percentSlot(CardText.percent(done: progress.written, total: progress.total)),
            capsule: capsule(subject, settings: settings))
        return Built(surfaces: surfaces, changesAt: changesAt, linePhase: linePhase)
    }

    /// The amounts, then what "Extraction Details" says.
    static func line(_ amount: String, _ detail: String) -> String {
        detail.isEmpty ? amount : "\(amount) · \(detail)"
    }

    /// After the amounts: the speed, the time left, or both in turn, each
    /// then as wide as the widest, so that the line stays where it is when
    /// they change places. Under a minute the time left counts as its
    /// widest (`88 seconds`), so that the line doesn't move at `9 seconds`
    /// or at `1 second` either. The speed also shows where the time left
    /// can't be told yet.
    private func detail(_ progress: Progress, settings: PluginSettings, now: Double,
                        changesAt: inout Double?) -> String {
        let speed = CardText.speed(progress.speed)
        let timed = progress.secondsLeft.map(CardText.time)
        switch settings.details {
        case .speed:
            return speed
        case .time:
            if timed != nil { changesAt = progress.secondsLeftChangeAt }
            return timed ?? speed
        case .both:
            let turns = [speed] + (timed.map { [$0] } ?? [])
            let elapsed = max(0, now - progress.startedAt)
            let turn = Int(elapsed / Self.turnSeconds)
            changesAt = now + Self.turnSeconds - elapsed.truncatingRemainder(dividingBy: Self.turnSeconds)
            let shown = turns[turn % turns.count]
            if let timed, shown == timed, let tick = progress.secondsLeftChangeAt {
                changesAt = min(changesAt ?? tick, tick)
            }
            guard turns.count >= 2 else { return shown }
            let lastMinute = (progress.secondsLeft ?? 60) < 60 ? [CardText.lastMinuteWidest] : []
            return ruler.sameWidth(shown, as: turns + lastMinute)
        }
    }

    /// The sneak peek's right side. Side slots widen just enough for text
    /// whose digits change in place; other text shows only two characters
    /// there, so without that kind the % sign is dropped and a value that
    /// still wouldn't fit is left out.
    private func percentSlot(_ text: String) -> Component? {
        if numericText { return .text(text, style: "numeric") }
        let short = text.hasSuffix("%") ? String(text.dropLast()) : text
        return short.count > 2 ? nil : .text(short, style: "compact")
    }

    // MARK: Stopped short

    /// An extraction stopped short: cancelled, or failed; from outside the
    /// two look the same (the wording and symbol chosen on 12 Oct 2026).
    /// `hasLeftovers`: something of it was left where it was being
    /// extracted, which Show in Finder can show.
    ///
    /// `isIncomplete`: the tool went through the archive to its end and
    /// not every file is there (a damaged archive). The card then says
    /// `Incomplete`, with a red ring for the cross (13 Oct 2026).
    func stopped(_ extraction: Extraction, isIncomplete: Bool = false, activityID: String, cardSince: Double,
                 lineSince: Double, hasLeftovers: Bool, settings: PluginSettings, now: Double) -> Built {
        let line = statusLine(isIncomplete ? "Incomplete" : "Stopped", name: extraction.name, since: lineSince, now: now)
        let cross: Component = isIncomplete
            ? pictures.base64(.incomplete).map { .picture(base64: $0) } ?? .symbol("circle", tint: "red")
            : pictures.base64(.stopped).map { .picture(base64: $0) } ?? .status("failed", tint: "red")
        let surfaces = Surfaces(
            pillLeft: pillIcon(.one(name: extraction.name), isOver: true, cardSince: cardSince, settings: settings, now: now),
            pillRight: cross,
            peekLeft: hasLeftovers ? Self.showButton(activityID) : nil,
            peekCenter: .text(line.text, style: "marquee"),
            capsule: capsule(.one(name: extraction.name), settings: settings))
        return Built(surfaces: surfaces, changesAt: line.changesAt, linePhase: line.phase)
    }

    // MARK: Several, over

    /// What the card says of several extractions that are over:
    /// `3 Extractions Completed` when all of them were, `2/3 Extractions
    /// Completed` when some stopped short (the wording chosen on 12 Oct
    /// 2026). `unchecked` of them ended with a result that couldn't be
    /// checked: they count with the completed ones, and the word is then
    /// `Done`, as on the card of one alone (13 Oct 2026).
    static func summaryText(completed: Int, unchecked: Int = 0, of count: Int) -> String {
        let word = unchecked > 0 ? "Done" : "Completed"
        let ended = completed + unchecked
        return ended == count ? "\(count) Extractions \(word)" : "\(ended)/\(count) Extractions \(word)"
    }

    /// Several extractions, over: the check when all are complete, the
    /// grey bar when some couldn't be checked, the cross when some stopped
    /// short; Show in Finder (when anything of them is there) and no Open:
    /// there is no one item to open.
    func summary(completed: Int, unchecked: Int = 0, of count: Int, activityID: String, cardSince: Double,
                 lineSince: Double, hasItems: Bool, settings: PluginSettings, now: Double) -> Built {
        let line = heldLine(Self.summaryText(completed: completed, unchecked: unchecked, of: count), since: lineSince, now: now)
        let mark: Component
        if completed + unchecked < count {
            mark = pictures.base64(.stopped).map { .picture(base64: $0) } ?? .status("failed", tint: "red")
        } else if unchecked > 0 {
            mark = uncheckedMark
        } else {
            mark = pictures.base64(.done).map { .picture(base64: $0) } ?? .status("success", tint: "green")
        }
        let surfaces = Surfaces(
            pillLeft: pillIcon(.several(count), isOver: true, cardSince: cardSince, settings: settings, now: now),
            pillRight: mark,
            peekLeft: hasItems ? Self.showButton(activityID) : nil,
            peekCenter: .text(line.text, style: "marquee"),
            capsule: capsule(.several(count), settings: settings))
        return Built(surfaces: surfaces, changesAt: line.changesAt, linePhase: line.phase)
    }

    // MARK: Complete, and done

    /// The grey bar of an extraction whose result couldn't be checked.
    private var uncheckedMark: Component {
        pictures.base64(.unchecked).map { .picture(base64: $0) } ?? .symbol("minus.circle.fill", tint: "gray")
    }

    /// `lineSince` is when the line came up, or when the plugin last opened
    /// the sneak peek for it: a line too long stays still from then.
    ///
    /// `isChecked`: every file of the archive was looked at, and the card
    /// says `Complete`. Where that couldn't be done (no list of the
    /// archive's contents) and the result is in place all the same, it
    /// says `Done`, with a grey bar for the check (13 Oct 2026).
    func complete(_ extraction: Extraction, isChecked: Bool = true, activityID: String, cardSince: Double, lineSince: Double,
                  settings: PluginSettings, now: Double) -> Built {
        let line = statusLine(isChecked ? "Complete" : "Done", name: extraction.name, since: lineSince, now: now)
        let check: Component = isChecked
            ? pictures.base64(.done).map { .picture(base64: $0) } ?? .status("success", tint: "green")
            : uncheckedMark
        let surfaces = Surfaces(
            pillLeft: pillIcon(.one(name: extraction.name), isOver: true, cardSince: cardSince, settings: settings, now: now),
            pillRight: check,
            peekLeft: Self.showButton(activityID),
            peekCenter: .text(line.text, style: "marquee"),
            peekRight: Self.openButton(activityID),
            capsule: capsule(.one(name: extraction.name), settings: settings))
        return Built(surfaces: surfaces, changesAt: line.changesAt, linePhase: line.phase)
    }

    /// `Complete • photos.zip`: what happened, then the archive's name. A
    /// very long name is shortened in the middle, to what DynamicLake
    /// accepts.
    static func statusText(_ word: String, name: String) -> String {
        var shown = Array(name)
        let room = maxTextCharacters - word.count - CardText.bullet.count - TextRuler.leadBlank.count
        if shown.count > room {
            let keep = room - 1
            shown = shown.prefix(keep - keep / 2) + ["…"] + shown.suffix(keep / 2)
        }
        return word + CardText.bullet + String(shown)
    }

    /// The status line. When it is too long for the sneak peek, DynamicLake
    /// scrolls it, and starts at once: the status would be gone before it
    /// is read. So for a few seconds it is shown cut short, which stays
    /// still (`Complete • Some.Long.Na…`), and only then whole, to scroll,
    /// with a blank before it to keep its first letter clear of the fade
    /// on the left.
    func statusLine(_ word: String, name: String, since: Double, now: Double)
        -> (text: String, phase: LinePhase, changesAt: Double?) {
        heldLine(Self.statusText(word, name: name), since: since, now: now)
    }

    /// A line as the sneak peek shows it: whole when it fits; else cut
    /// short and still at first, then whole and scrolling.
    func heldLine(_ full: String, since: Double, now: Double) -> (text: String, phase: LinePhase, changesAt: Double?) {
        guard let short = ruler.fitted(full) else { return (full, .whole, nil) }
        let until = since + Self.holdSeconds
        if now < until { return (short, .held, until) }
        return (TextRuler.leadBlank + full, .scrolling, nil)
    }
}
