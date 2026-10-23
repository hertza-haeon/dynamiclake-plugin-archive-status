// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One of the plugin's own pictures.
enum PictureKind: Hashable {
    /// An archive's type (`zip`, `rar`, `7z`) in the blue circle.
    case type(String)
    /// An archive box in the blue circle: a card's first seconds.
    case box
    /// A check mark in a green circle: complete.
    case done
    /// A cross in a red circle: stopped short.
    case stopped
    /// Three dots in a red circle: stalled.
    case stalled
    /// A bar in a grey circle: done, with a result that couldn't be
    /// checked (Firefox Downloads' "blocked" picture, in grey).
    case unchecked
    /// A ring in a red circle: incomplete, extracted to the archive's end
    /// with files missing.
    case incomplete
}

/// Draws the plugin's pictures, in the look of Firefox Downloads': a full
/// circle in the picture's colour, dark, and the symbol in the same colour,
/// bright, inside it. Drawn off screen with what macOS carries, kept as
/// small PNG pictures, each drawn once.
///
/// It keeps what it drew, so it is a class, and it is used from the
/// plugin's one thread only.
final class Pictures {
    /// The pictures' size in pixels; DynamicLake scales them to the slot.
    static let pixels = 96
    /// The system's rounded bold, for a type's letters.
    static let fontName = ".AppleSystemUIFontRounded-Bold"
    /// The most a picture may weigh once written as text (DynamicLake's
    /// limit for a picture inside a message is 48 KB).
    static let maxBase64 = 48 * 1024

    private var drawn: [PictureKind: String?] = [:]
    private let draw: (PictureKind) -> Data?

    /// Tests may give their own way of drawing (one that fails, say).
    init(draw: @escaping (PictureKind) -> Data? = Pictures.png) {
        self.draw = draw
    }

    /// The picture as a PNG written in base64, or nothing where it can't be
    /// drawn.
    func base64(_ kind: PictureKind) -> String? {
        if let known = drawn[kind] { return known }
        let text = draw(kind).map { $0.base64EncodedString() }
        let fitting = text.flatMap { $0.count <= Self.maxBase64 ? $0 : nil }
        drawn[kind] = fitting
        return fitting
    }

    // MARK: Drawing

    /// The blue, the green, the red and the grey of DynamicLake's own
    /// symbols, and how dark the circle is.
    private static func look(_ kind: PictureKind) -> (red: Double, green: Double, blue: Double, dim: Double) {
        switch kind {
        case .type, .box: (10.0 / 255, 132.0 / 255, 1.0, 0.24)
        case .done: (48.0 / 255, 209.0 / 255, 88.0 / 255, 0.22)
        case .stopped, .stalled, .incomplete: (1.0, 69.0 / 255, 58.0 / 255, 0.22)
        case .unchecked: (142.0 / 255, 142.0 / 255, 147.0 / 255, 0.22)
        }
    }

    static func png(_ kind: PictureKind) -> Data? {
        png(kind, pixels: pixels)
    }

    /// The same picture at any size.
    static func png(_ kind: PictureKind, pixels size: Int) -> Data? {
        let side = Double(size)
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colour = look(kind)
        context.setFillColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: colour.dim)
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
        context.setStrokeColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        /// A line between two points, all in fractions of the picture's side.
        func stroke(_ width: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            context.setLineWidth(side * width)
            context.move(to: CGPoint(x: side * x0, y: side * y0))
            context.addLine(to: CGPoint(x: side * x1, y: side * y1))
            context.strokePath()
        }

        switch kind {
        case .type(let text):
            // As large as fits: 80 % of the circle's width at most.
            let biggest = side * (text.count <= 2 ? 0.50 : 0.44)
            var (line, width, xHeight) = textLine(text, size: biggest)
            if width > side * 0.80 {
                (line, width, xHeight) = textLine(text, size: biggest * side * 0.80 / width)
            }
            if text.allSatisfy(\.isNumber) {
                // A number (how many extractions): centred by what is
                // drawn of it. Figures are as tall as capitals, and by the
                // height of small letters they would sit too high; and a
                // figure's own width isn't even on both sides.
                context.textPosition = .zero
                let ink = CTLineGetImageBounds(line, context)
                context.textPosition = CGPoint(x: (side - ink.width) / 2 - ink.minX, y: (side - ink.height) / 2 - ink.minY)
            } else {
                // Centred by the height of its small letters.
                context.textPosition = CGPoint(x: (side - width) / 2, y: (side - xHeight) / 2)
            }
            CTLineDraw(line, context)
        case .box:
            // An archive box: a lid, the box under it, and its handle.
            stroke(0.115, 0.315, 0.655, 0.685, 0.655)
            context.setLineWidth(side * 0.075)
            context.move(to: CGPoint(x: side * 0.355, y: side * 0.555))
            context.addLine(to: CGPoint(x: side * 0.355, y: side * 0.385))
            context.addQuadCurve(to: CGPoint(x: side * 0.415, y: side * 0.325),
                                 control: CGPoint(x: side * 0.355, y: side * 0.325))
            context.addLine(to: CGPoint(x: side * 0.585, y: side * 0.325))
            context.addQuadCurve(to: CGPoint(x: side * 0.645, y: side * 0.385),
                                 control: CGPoint(x: side * 0.645, y: side * 0.325))
            context.addLine(to: CGPoint(x: side * 0.645, y: side * 0.555))
            context.strokePath()
            stroke(0.065, 0.455, 0.475, 0.545, 0.475)
        case .done:
            // A check mark: the short arm, then the long one.
            stroke(0.085, 0.347, 0.467, 0.458, 0.32)
            stroke(0.085, 0.458, 0.32, 0.68, 0.667)
        case .stopped:
            // A cross.
            stroke(0.085, 0.345, 0.345, 0.655, 0.655)
            stroke(0.085, 0.345, 0.655, 0.655, 0.345)
        case .stalled:
            // Three dots.
            for x in [0.33, 0.5, 0.67] {
                stroke(0.098, x, 0.5, x, 0.5)
            }
        case .unchecked:
            // A horizontal bar.
            stroke(0.085, 0.33, 0.5, 0.67, 0.5)
        case .incomplete:
            // A ring, between the cross's width and the progress ring's.
            let radius = side * 0.215
            context.setLineWidth(side * 0.078)
            context.strokeEllipse(in: CGRect(x: side / 2 - radius, y: side / 2 - radius, width: radius * 2, height: radius * 2))
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A line of `text` in the pictures' font at `size`, its width, and the
    /// height of the font's small letters.
    private static func textLine(_ text: String, size: Double) -> (line: CTLine, width: Double, xHeight: Double) {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return (line, CTLineGetTypographicBounds(line, nil, nil, nil), CTFontGetXHeight(font))
    }
}
