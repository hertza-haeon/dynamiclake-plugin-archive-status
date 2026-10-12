// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Why the link to DynamicLake is over.
public enum LakeError: Error, Equatable, Sendable {
    /// The socket DynamicLake named can't be connected to.
    case cannotConnect
    /// DynamicLake closed the connection (it quit, or stopped the plugin).
    case closed
}

/// What comes from DynamicLake.
public enum LakeIncoming: Equatable, Sendable {
    /// A button of one of the plugin's cards was pressed.
    case action(LakeAction)
    /// DynamicLake refused a message; its answer, for the log.
    case refusal(String)
}

/// The plugin's link to DynamicLake. The real one is a socket; tests put a
/// stand-in in its place.
public protocol LakeLink {
    mutating func send(_ message: LakeMessage) throws(LakeError)
    /// Waits up to `seconds` for something from DynamicLake and returns
    /// what came. This is where the plugin sleeps between two looks: a
    /// button press ends the wait at once.
    mutating func receive(wait seconds: Double) throws(LakeError) -> [LakeIncoming]
}

/// DynamicLake's socket: messages are JSON, each behind its length written
/// on four bytes, the highest first, in both directions.
public final class LakeSocket: LakeLink {
    /// No message from DynamicLake is taken to be longer than this.
    static let maxFrame = 1024 * 1024

    private let descriptor: Int32
    private var buffer: [UInt8] = []

    /// Connects to the socket DynamicLake names in the plugin's environment.
    public init(path: String) throws(LakeError) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw .cannotConnect }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw .cannotConnect
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw .cannotConnect
        }
        self.descriptor = descriptor
        Self.prepare(descriptor)
    }

    /// Takes over a socket that is already connected (the tests' pairs).
    init(descriptor: Int32) {
        self.descriptor = descriptor
        Self.prepare(descriptor)
    }

    deinit {
        close(descriptor)
    }

    /// Writing to a connection DynamicLake has closed must come back as an
    /// error, not end the plugin with a signal.
    private static func prepare(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public func send(_ message: LakeMessage) throws(LakeError) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let json = try? encoder.encode(message) else { return }
        try send(frame: Array(json))
    }

    /// Sends bytes as one message. Each piece goes out once, in order: a
    /// message begun is always finished, or every one after it would be
    /// unreadable.
    func send(frame json: [UInt8]) throws(LakeError) {
        var bytes = withUnsafeBytes(of: UInt32(json.count).bigEndian) { Array($0) }
        bytes += json
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(descriptor, base + sent, bytes.count - sent, 0)
            }
            if wrote < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw .closed
            }
            sent += wrote
        }
    }

    public func receive(wait seconds: Double) throws(LakeError) -> [LakeIncoming] {
        var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(0, min(seconds, 3_600)) * 1_000)
        let ready = poll(&watched, 1, milliseconds)
        guard ready > 0 else { return [] }               // nothing came (or the wait was interrupted)

        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let got = chunk.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if got > 0 {
                buffer += chunk.prefix(got)
            } else if got == 0 {
                throw .closed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                throw .closed
            }
        }
        return try takeMessages()
    }

    /// The whole messages the buffer holds, taken out of it.
    private func takeMessages() throws(LakeError) -> [LakeIncoming] {
        var incoming: [LakeIncoming] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxFrame else { throw .closed }
            guard buffer.count >= 4 + length else { break }
            let frame = Array(buffer[4..<(4 + length)])
            buffer.removeFirst(4 + length)
            if let message = Self.read(frame) {
                incoming.append(message)
            }
        }
        return incoming
    }

    /// One message from DynamicLake: a button press, or a refusal. Its
    /// plain "ok" to each message sent is nothing to report.
    static func read(_ frame: [UInt8]) -> LakeIncoming? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(frame)) as? [String: Any] else { return nil }
        if json["type"] as? String == "action" {
            guard let activityID = json["activityID"] as? String, let actionID = json["actionID"] as? String else {
                return nil
            }
            return .action(LakeAction(activityID: activityID, actionID: actionID))
        }
        if json["ok"] as? Bool == false || json["error"] != nil {
            return .refusal(String(decoding: frame.prefix(400), as: UTF8.self))
        }
        return nil
    }
}
