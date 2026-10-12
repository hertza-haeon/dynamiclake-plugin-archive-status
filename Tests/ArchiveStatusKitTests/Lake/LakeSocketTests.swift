// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

/// The plugin's end of a socket, and the test playing DynamicLake at the
/// other end.
struct LakeSocketTests {
    let socket: LakeSocket
    /// DynamicLake's end.
    let far: Int32

    init() throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        socket = LakeSocket(descriptor: pair[0])
        far = pair[1]
    }

    /// What DynamicLake would send: a message behind its length.
    private func framed(_ json: String) -> [UInt8] {
        withUnsafeBytes(of: UInt32(json.utf8.count).bigEndian) { Array($0) } + Array(json.utf8)
    }

    private func sendFromFar(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { write(far, $0.baseAddress, $0.count) }
    }

    private func readAtFar(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let read = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(far, base + got, count - got)
            }
            guard read > 0 else { break }
            got += read
        }
        return Array(bytes.prefix(got))
    }

    @Test func aMessageGoesOutBehindItsLength() throws {
        try socket.send(.dismiss("extraction-3"))
        let length = readAtFar(4).reduce(0) { $0 << 8 | Int($1) }
        let body = readAtFar(length)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body)) as? NSDictionary)
        #expect(json == ["schemaVersion": 1, "type": "dismiss", "activityID": "extraction-3"])
        close(far)
    }

    @Test func aMessageWithPicturesGoesOutWhole() throws {
        // Larger than a socket takes in one piece: it must still arrive whole.
        let big = String(repeating: "QUJD", count: 120_000)
        let reader = Thread { [far] in
            var total = 0
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while total < 4 + 480_000 {
                let read = chunk.withUnsafeMutableBytes { Darwin.read(far, $0.baseAddress, $0.count) }
                guard read > 0 else { break }
                total += read
            }
        }
        reader.start()
        try socket.send(frame: Array(big.utf8))
        while reader.isFinished == false { usleep(1_000) }
        close(far)
    }

    @Test func aButtonPressIsReceived() throws {
        sendFromFar(framed(#"{"schemaVersion":1,"type":"action","activityID":"extraction-1","actionID":"show:extraction-1","surface":"sneakPeek"}"#))
        #expect(try socket.receive(wait: 1) == [.action(LakeAction(activityID: "extraction-1", actionID: "show:extraction-1"))])
        close(far)
    }

    @Test func nothingComingMeansAnEmptyAnswerAfterTheWait() throws {
        let began = Date.now
        #expect(try socket.receive(wait: 0.05).isEmpty)
        #expect(Date.now.timeIntervalSince(began) < 1)
        close(far)
    }

    @Test func messagesArrivingTogetherOrInPiecesAreToldApart() throws {
        let first = framed(#"{"type":"action","activityID":"a","actionID":"open:a"}"#)
        let second = framed(#"{"type":"action","activityID":"b","actionID":"show:b"}"#)
        // Two in one go, with the start of a third.
        sendFromFar(first + second + first.prefix(10))
        #expect(try socket.receive(wait: 1) == [
            .action(LakeAction(activityID: "a", actionID: "open:a")), .action(LakeAction(activityID: "b", actionID: "show:b")),
        ])
        // The rest of the third.
        sendFromFar(Array(first.dropFirst(10)))
        #expect(try socket.receive(wait: 1) == [.action(LakeAction(activityID: "a", actionID: "open:a"))])
        close(far)
    }

    @Test func dynamicLakesPlainAnswersAreNothingToReport() throws {
        sendFromFar(framed(#"{"ok":true}"#) + framed("not json at all") + framed(#"{"type":"action"}"#))
        #expect(try socket.receive(wait: 1).isEmpty)
        close(far)
    }

    @Test func aRefusalIsPassedOnForTheLog() throws {
        sendFromFar(framed(#"{"ok":false,"error":"Invalid field 'text'"}"#))
        let incoming = try socket.receive(wait: 1)
        guard case .refusal(let answer)? = incoming.first else {
            Issue.record("expected a refusal, got \(incoming)")
            return
        }
        #expect(answer.contains("Invalid field 'text'"))
        close(far)
    }

    @Test func dynamicLakeGoingAwayIsNoticedWhenReceiving() {
        close(far)
        #expect(throws: LakeError.closed) {
            try socket.receive(wait: 1)
        }
    }

    @Test func dynamicLakeGoingAwayIsAnErrorWhenSendingNotACrash() {
        close(far)
        #expect(throws: LakeError.closed) {
            // (The first write may still be taken; the next can't be.)
            for _ in 0..<50 {
                try socket.send(.dismiss("extraction-1"))
            }
        }
    }

    @Test func aLengthThatMakesNoSenseEndsTheLink() {
        sendFromFar([0xFF, 0xFF, 0xFF, 0xFF, 0x7B])
        #expect(throws: LakeError.closed) {
            try socket.receive(wait: 1)
        }
        close(far)
    }

    @Test func aSocketThatIsNotThereCannotBeConnectedTo() {
        #expect(throws: LakeError.cannotConnect) {
            _ = try LakeSocket(path: NSTemporaryDirectory() + "no-such-socket-\(UUID().uuidString)")
        }
        #expect(throws: LakeError.cannotConnect) {
            _ = try LakeSocket(path: String(repeating: "x", count: 500))
        }
    }
}
