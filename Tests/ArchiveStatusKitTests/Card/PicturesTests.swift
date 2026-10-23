// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArchiveStatusKit

struct PicturesTests {
    /// A picture's pixels: red, green, blue and alpha of each, row by row
    /// from the top.
    private func pixels(_ kind: PictureKind) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let data = try #require(Pictures.png(kind))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(rgba.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, rgba)
    }

    private func pixel(_ picture: (width: Int, height: Int, rgba: [UInt8]), _ x: Int, _ y: Int) -> [UInt8] {
        let start = (y * picture.width + x) * 4
        return Array(picture.rgba[start..<(start + 4)])
    }

    @Test(arguments: [PictureKind.box, .done, .unchecked, .incomplete, .type("zip"), .type("rar"), .type("7z"), .type("tbz2")])
    func eachPictureIsASmallSquarePNG(kind: PictureKind) throws {
        let data = try #require(Pictures.png(kind))
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let picture = try pixels(kind)
        #expect(picture.width == Pictures.pixels)
        #expect(picture.height == Pictures.pixels)
        // Well under what DynamicLake accepts inside a message.
        let text = try #require(Pictures().base64(kind))
        #expect(text.count < 12_000)
        #expect(text.count <= Pictures.maxBase64)
    }

    @Test(arguments: [PictureKind.box, .done, .type("zip")])
    func eachPictureIsADarkCircleWithNothingAroundIt(kind: PictureKind) throws {
        let picture = try pixels(kind)
        // The corners are outside the circle.
        for (x, y) in [(0, 0), (95, 0), (0, 95), (95, 95)] {
            #expect(pixel(picture, x, y)[3] == 0)
        }
        // Just inside its edge, the circle: the picture's colour, dark.
        let edge = pixel(picture, 48, 3)
        #expect((40...80).contains(edge[3]), "the circle is see-through dark, not solid")
    }

    @Test func theCheckMarkIsGreenAndTheOthersBlue() throws {
        // The brightest pixel of each picture is its symbol, fully opaque.
        func brightest(_ kind: PictureKind) throws -> [UInt8] {
            let picture = try pixels(kind)
            var best: [UInt8] = [0, 0, 0, 0]
            for y in 0..<picture.height {
                for x in 0..<picture.width where pixel(picture, x, y)[3] == 255 {
                    best = pixel(picture, x, y)
                }
            }
            return best
        }
        let check = try brightest(.done)
        #expect(check[1] > check[0] && check[1] > check[2], "green")
        for kind in [PictureKind.box, .type("zip")] {
            let symbol = try brightest(kind)
            #expect(symbol[2] > symbol[0] && symbol[2] > symbol[1], "blue")
        }
    }

    /// Firefox Downloads' "blocked" bar, in the grey of macOS's own
    /// symbols: red, green and blue nearly alike.
    @Test func theBarOfOneThatCouldNotBeCheckedIsGrey() throws {
        let picture = try pixels(.unchecked)
        let middle = pixel(picture, 48, 48)
        #expect(middle[3] == 255)
        #expect(middle[0] > 120 && middle[0] < 165)
        #expect(abs(Int(middle[0]) - Int(middle[1])) < 4 && abs(Int(middle[2]) - Int(middle[0])) < 12)
        // A bar: wide, not tall.
        #expect(pixel(picture, 36, 48)[3] == 255 && pixel(picture, 60, 48)[3] == 255)
        #expect(pixel(picture, 48, 36)[3] < 255 && pixel(picture, 48, 60)[3] < 255)
    }

    /// A bright red ring inside the darker red circle: bright on the
    /// ring, the dark circle showing through its middle.
    @Test func theRingOfAnIncompleteOneIsBrightRedAroundADarkMiddle() throws {
        let picture = try pixels(.incomplete)
        // On the ring, left and right of the middle and above and below it.
        for (x, y) in [(27, 48), (69, 48), (48, 27), (48, 69)] {
            let onRing = pixel(picture, x, y)
            #expect(onRing[3] == 255, "bright at (\(x), \(y))")
            #expect(onRing[0] > 240 && onRing[1] < 90 && onRing[2] < 80)
        }
        // Its middle is the circle itself: dark, see-through.
        let middle = pixel(picture, 48, 48)
        #expect(middle[3] > 30 && middle[3] < 90)
        // …and so is the circle outside the ring.
        let outside = pixel(picture, 48, 10)
        #expect(outside[3] > 30 && outside[3] < 90)
    }

    @Test func theSymbolSitsInTheMiddle() throws {
        for kind in [PictureKind.box, .done, .unchecked, .incomplete, .type("zip"), .type("7z")] {
            let picture = try pixels(kind)
            var left = picture.width, right = 0, top = picture.height, bottom = 0
            for y in 0..<picture.height {
                for x in 0..<picture.width where pixel(picture, x, y)[3] > 200 {
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                }
            }
            let centre = Double(left + right) / 2
            #expect(abs(centre - 47.5) < 4, "\(kind): the symbol is centred across")
            #expect(left > 14 && right < 82 && top > 14 && bottom < 82, "\(kind): the symbol keeps clear of the circle's edge")
        }
    }

    /// Found on 12 Oct 2026: the number of extractions sat off-centre in
    /// its circle. A figure is as tall as a capital, and not as wide on one
    /// side as on the other: it is centred by what is drawn of it.
    @Test(arguments: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "12", "25"])
    func aNumberSitsInTheVeryMiddleOfItsCircle(number: String) throws {
        let picture = try pixels(.type(number))
        var left = picture.width, right = 0, top = picture.height, bottom = 0
        for y in 0..<picture.height {
            for x in 0..<picture.width where pixel(picture, x, y)[3] > 200 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        #expect(abs(Double(left + right) / 2 - 47.5) <= 1, "\(number): across, from \(left) to \(right)")
        #expect(abs(Double(top + bottom) / 2 - 47.5) <= 1, "\(number): up and down, from \(top) to \(bottom)")
        #expect(left > 14 && right < 82 && top > 14 && bottom < 82, "\(number): clear of the circle's edge")
    }

    @Test func aPictureIsDrawnOnceAndKept() throws {
        let pictures = Pictures()
        let first = try #require(pictures.base64(.type("zip")))
        #expect(pictures.base64(.type("zip")) == first)
        #expect(pictures.base64(.type("rar")) != first)
        #expect(pictures.base64(.box) != pictures.base64(.done))
    }
}
