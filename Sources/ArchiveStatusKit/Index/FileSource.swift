// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A file opened for reading, read a piece at a time. It is never written
/// to, and it is closed when this object goes.
///
/// Archives come from anywhere, so every read is checked against the file's
/// real size: a wrong number inside an archive ends in an `IndexError`,
/// never in a crash.
final class FileSource {
    let path: String
    let size: UInt64
    private let descriptor: Int32

    /// The most that is read in one piece.
    static let maxPiece = 8 * 1024 * 1024

    init(path: String) throws(IndexError) {
        // O_NONBLOCK: opening something that isn't a plain file never waits.
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw .unreadable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            close(descriptor)
            throw .unreadable
        }
        self.path = path
        self.size = UInt64(info.st_size)
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Exactly `count` bytes from `offset` on. Asking for more than the file
    /// holds there is `.damaged`: an archive that points outside itself.
    func bytes(at offset: UInt64, count: Int) throws(IndexError) -> [UInt8] {
        guard count >= 0, count <= Self.maxPiece else { throw .damaged }
        guard offset <= size, UInt64(count) <= size - offset else { throw .damaged }
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(descriptor, base + done, count - done, off_t(offset) + off_t(done))
            }
            if read < 0 {
                if errno == EINTR { continue }
                throw .unreadable
            }
            if read == 0 { throw .damaged }      // (the file shrank meanwhile)
            done += read
        }
        return buffer
    }

    /// Up to `count` bytes from `offset` on: fewer at the end of the file.
    func bytes(at offset: UInt64, upTo count: Int) throws(IndexError) -> [UInt8] {
        guard offset <= size else { throw .damaged }
        return try bytes(at: offset, count: Int(min(UInt64(max(0, count)), size - offset)))
    }
}

/// Reads numbers out of bytes, the lowest byte first, as zip and RAR write
/// them. Reading past the end is `.damaged`.
struct ByteCursor {
    private let bytes: ArraySlice<UInt8>
    private(set) var position: Int

    init(_ bytes: [UInt8]) {
        self.init(bytes[...])
    }

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.position = bytes.startIndex
    }

    var remaining: Int { bytes.endIndex - position }

    /// How far the cursor is from where it started.
    var offset: Int { position - bytes.startIndex }

    mutating func take(_ count: Int) throws(IndexError) -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw .damaged }
        defer { position += count }
        return bytes[position..<(position + count)]
    }

    mutating func skip(_ count: Int) throws(IndexError) {
        _ = try take(count)
    }

    mutating func u8() throws(IndexError) -> UInt8 {
        guard remaining >= 1 else { throw .damaged }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func u16() throws(IndexError) -> UInt16 {
        let low = try u8()
        let high = try u8()
        return UInt16(low) | UInt16(high) << 8
    }

    mutating func u32() throws(IndexError) -> UInt32 {
        let low = try u16()
        let high = try u16()
        return UInt32(low) | UInt32(high) << 16
    }

    mutating func u64() throws(IndexError) -> UInt64 {
        let low = try u32()
        let high = try u32()
        return UInt64(low) | UInt64(high) << 32
    }

    /// RAR5's numbers of any length: seven bits a byte, the lowest first,
    /// the top bit saying that another byte follows.
    mutating func vint() throws(IndexError) -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 70, by: 7) {
            let byte = try u8()
            if shift < 64 {
                value |= UInt64(byte & 0x7F) << UInt64(shift)
            }
            if byte & 0x80 == 0 { return value }
        }
        throw .damaged
    }
}

/// A name's bytes as text: UTF-8 when they are, else the old DOS characters
/// (code page 437), which is what archives made on old systems hold.
func decodedName(_ bytes: ArraySlice<UInt8>) -> String {
    if let text = utf8Text(bytes) {
        return text
    }
    return String(bytes.map { byte -> Character in
        byte < 0x80 ? Character(UnicodeScalar(byte)) : dosCharacters[Int(byte) - 0x80]
    })
}

/// The bytes as text when they are valid UTF-8, else nothing.
func utf8Text(_ bytes: some Sequence<UInt8>) -> String? {
    String(bytes: bytes, encoding: .utf8)
}

/// Code page 437, upper half.
private let dosCharacters: [Character] = Array(
    "ÇüéâäàåçêëèïîìÄÅ" +
    "ÉæÆôöòûùÿÖÜ¢£¥₧ƒ" +
    "áíóúñÑªº¿⌐¬½¼¡«»" +
    "░▒▓│┤╡╢╖╕╣║╗╝╜╛┐" +
    "└┴┬├─┼╞╟╚╔╩╦╠═╬╧" +
    "╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀" +
    "αßΓπΣσµτΦΘΩδ∞φε∩" +
    "≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
)
