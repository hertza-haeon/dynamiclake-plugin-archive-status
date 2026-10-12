// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreText
import Foundation

/// Measures text as DynamicLake draws it in the middle of a sneak peek, and
/// shapes lines to fit there, the way Firefox Downloads does.
///
/// Measured on a notch for Firefox Downloads: the text is in the system's
/// semibold at 14 pt; a line up to 196 pt wide is shown whole, a wider one
/// scrolls.
///
/// It keeps what it measured, so it is a class, and it is used from the
/// plugin's one thread only.
final class TextRuler {
    /// The sneak peek's font and size.
    static let fontName = ".AppleSystemUIFontDemi"
    static let fontSize = 14.0
    /// The widest text shown whole, in points.
    static let fitPoints = 196.0
    /// The same in characters, where widths can't be measured.
    static let fitCharacters = 28
    /// An invisible character after padding spaces, which keeps DynamicLake
    /// from trimming them. (Others make it refuse the whole message.)
    static let padEnd = "\u{034F}"
    /// An empty braille cell, put before a line that scrolls: it starts
    /// where the left side fades out, which would cut its first letter, and
    /// spaces there are trimmed.
    static let leadBlank = "\u{2800}"

    private let measure: (String) -> Double?
    private var widths: [String: Double?] = [:]

    /// A ruler that measures with the given function; tests give their own.
    init(measure: @escaping (String) -> Double?) {
        self.measure = measure
    }

    /// The ruler that measures in the sneak peek's own font.
    static func system() -> TextRuler {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: font]
        return TextRuler { text in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
    }

    /// How wide `text` is drawn, in points; nothing where it can't be measured.
    func width(_ text: String) -> Double? {
        if let known = widths[text] { return known }
        if widths.count > 4_000 { widths.removeAll() }
        let width = measure(text)
        widths[text] = width
        return width
    }

    /// `text` cut to what the sneak peek shows whole, ending with `…`;
    /// nothing when all of it fits.
    func fitted(_ text: String) -> String? {
        let characters = Array(text)
        func cut(_ count: Int) -> String {
            var kept = characters.prefix(count)
            while let last = kept.last, " .•".contains(last) { kept.removeLast() }
            return String(kept) + "…"
        }
        guard let whole = width(text) else {
            return characters.count <= Self.fitCharacters ? nil : cut(Self.fitCharacters - 1)
        }
        if whole <= Self.fitPoints { return nil }
        // The longest beginning that fits with its "…".
        var low = 0
        var high = characters.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if (width(cut(middle)) ?? 0) <= Self.fitPoints {
                low = middle
            } else {
                high = middle
            }
        }
        return cut(low)
    }

    /// `shown`, followed by enough space to be as wide as the widest of
    /// them all: where one text takes another's place (the speed and the
    /// time left, in turn), the line then stays where it is. Digits count
    /// as the widest one, so that it doesn't move every second either. As
    /// it is where widths can't be measured.
    func sameWidth(_ shown: String, as others: [String]) -> String {
        var widest = 0.0
        for text in [shown] + others {
            guard let width = width(String(text.map { $0.isASCII && $0.isNumber ? "8" : $0 })) else { return shown }
            widest = max(widest, width)
        }
        guard let actual = width(shown) else { return shown }
        return shown + padding(widest - actual)
    }

    /// Spaces adding up to `points` (to within half a point), followed by
    /// the character that keeps them from being trimmed; nothing for less.
    func padding(_ points: Double) -> String {
        var left = points
        var spaces = ""
        // An ordinary space, a thin one, a hair one.
        for space in [" ", "\u{2009}", "\u{200A}"] {
            guard let both = width("x" + space + "x"), let none = width("xx"), both - none > 0.1 else { continue }
            let each = both - none
            let count = Int(((left + (space == "\u{200A}" ? each / 2 : 0)) / each).rounded(.down))
            guard count > 0 else { continue }
            spaces += String(repeating: space, count: count)
            left -= Double(count) * each
        }
        return spaces.isEmpty ? "" : spaces + Self.padEnd
    }
}
