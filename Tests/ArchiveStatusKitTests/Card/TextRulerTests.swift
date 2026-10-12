// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArchiveStatusKit

/// A made-up font for the tests: every character 7 points wide, an "8" 8
/// points, a "1" 5 points, and the three spaces 4, 2 and 1 points.
func testRuler() -> TextRuler {
    TextRuler { text in
        // (Scalar by scalar: the invisible character that ends a padding
        // joins the space before it into one character.)
        text.unicodeScalars.reduce(0.0) { width, character in
            switch character {
            case " ": width + 4
            case "\u{2009}": width + 2
            case "\u{200A}": width + 1
            case "\u{034F}": width
            case "8": width + 8
            case "1": width + 5
            default: width + 7
            }
        }
    }
}

struct TextRulerTests {
    let ruler = testRuler()

    @Test func aLineThatFitsIsLeftAlone() {
        #expect(ruler.fitted("Complete • photos.zip") == nil)
        #expect(ruler.fitted(String(repeating: "x", count: 28)) == nil, "196 points exactly still fits")
    }

    @Test func aLineTooLongIsCutToWhatFitsWithItsEllipsis() throws {
        let long = "Complete • Some.Very.Long.Archive.Name.2026.part1.rar"
        let short = try #require(ruler.fitted(long))
        #expect(short.hasSuffix("…"))
        #expect(try #require(ruler.width(short)) <= TextRuler.fitPoints)
        #expect(long.hasPrefix(short.dropLast()))
        // One character more would no longer fit.
        let longer = String(long.prefix(short.count)) + "…"
        #expect(try #require(ruler.width(longer)) > TextRuler.fitPoints)
    }

    @Test func aCutNeverEndsOnASpaceADotOrTheBullet() throws {
        // 26 x's fit with the ellipsis; the cut would fall after "• ".
        let text = String(repeating: "x", count: 24) + " • " + String(repeating: "y", count: 20)
        let short = try #require(ruler.fitted(text))
        #expect(short == String(repeating: "x", count: 24) + "…")
    }

    @Test func whereWidthsCannotBeMeasuredCharactersAreCounted() {
        let blind = TextRuler { _ in nil }
        #expect(blind.fitted(String(repeating: "x", count: 28)) == nil)
        #expect(blind.fitted(String(repeating: "x", count: 29)) == String(repeating: "x", count: 27) + "…")
        #expect(blind.sameWidth("12 s", as: ["1 min 5 s"]) == "12 s")
        #expect(blind.padding(40) == "")
    }

    @Test func paddingAddsUpToTheWidthAskedFor() throws {
        // 11 points: two ordinary spaces (8), one thin one (2), one hair one (1).
        let padding = ruler.padding(11)
        #expect(padding == "  \u{2009}\u{200A}\u{034F}")
        #expect(try #require(ruler.width(padding)) == 11)
        #expect(ruler.padding(0) == "")
        #expect(ruler.padding(0.4) == "")
        #expect(ruler.padding(-5) == "")
    }

    @Test func textsThatTakeTurnsAreMadeTheSameWidth() throws {
        // "9.9 MB/s" and "12 seconds" take turns: each as wide as the wider.
        let speed = ruler.sameWidth("9.9 MB/s", as: ["9.9 MB/s", "12 seconds"])
        let time = ruler.sameWidth("12 seconds", as: ["9.9 MB/s", "12 seconds"])
        #expect(speed.hasPrefix("9.9 MB/s"))
        #expect(speed.unicodeScalars.last == "\u{034F}", "padded, and its spaces kept from being trimmed")
        // Digits count as the widest one, so the width doesn't change with them.
        let widest = try #require(ruler.width("88 seconds"))
        #expect(try #require(ruler.width(time)) == widest)
        #expect(try #require(ruler.width(speed)) == widest)
        #expect(try #require(ruler.width(ruler.sameWidth("11 seconds", as: ["9.9 MB/s", "11 seconds"]))) == widest)
    }

    @Test func aWidthIsMeasuredOnce() {
        var calls = 0
        let counting = TextRuler { text in
            calls += 1
            return Double(text.count)
        }
        for _ in 0..<10 {
            _ = counting.width("the same text")
        }
        #expect(calls == 1)
    }

    @Test func theSystemsRulerMeasuresInTheSneakPeeksFont() throws {
        let system = TextRuler.system()
        let narrow = try #require(system.width("il"))
        let wide = try #require(system.width("MW"))
        #expect(narrow > 0)
        #expect(wide > narrow)
        // A line of 14 pt text is some tens of points wide, not hundreds.
        let line = try #require(system.width("0.85/2.56GB · 11 seconds"))
        #expect((120...220).contains(line))
    }
}
