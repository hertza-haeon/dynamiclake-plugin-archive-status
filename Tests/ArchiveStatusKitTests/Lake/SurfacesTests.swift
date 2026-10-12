// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArchiveStatusKit

/// What goes to DynamicLake, as the JSON it expects (the forms Firefox
/// Downloads sends, all seen working there).
struct SurfacesTests {
    private func json(_ value: some Encodable) throws -> NSDictionary {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func eachComponentIsWrittenAsDynamicLakeExpectsIt() throws {
        #expect(try json(Component.symbol("archivebox", tint: "blue"))
            == ["type": "image", "source": "sfSymbol", "systemImage": "archivebox", "tint": "blue"])
        #expect(try json(Component.picture(base64: "QUJD"))
            == ["type": "image", "source": "inlineData", "mimeType": "image/png", "base64Data": "QUJD"])
        #expect(try json(Component.ring(value: 0.25, tint: "blue")) == ["type": "progress", "tint": "blue", "value": 0.25])
        // Without a value the ring spins: the key isn't there at all.
        #expect(try json(Component.ring(value: nil, tint: "blue")) == ["type": "progress", "tint": "blue"])
        #expect(try json(Component.status("success", tint: "green")) == ["type": "status", "status": "success", "tint": "green"])
        #expect(try json(Component.button(title: "Show in Finder", symbol: "folder.fill", actionID: "show:extraction-1", tint: "blue"))
            == ["type": "button", "title": "Show in Finder", "systemImage": "folder.fill", "actionID": "show:extraction-1",
                "shape": "circle", "tint": "blue"])
        #expect(try json(Component.text("33%", style: "numeric")) == ["type": "text", "text": "33%", "style": "numeric"])
    }

    @Test func aCardsSurfacesAreThePillTheSneakPeekAndTheCapsule() throws {
        let surfaces = Surfaces(pillLeft: .symbol("a", tint: "blue"), pillRight: .ring(value: nil, tint: "blue"),
                                peekLeft: .text("L", style: "marquee"), peekCenter: .text("C", style: "marquee"),
                                peekRight: nil, capsule: .symbol("x", tint: "blue"))
        let written = try json(surfaces)
        #expect(written == [
            "compactLiveActivity": ["leftSlot": ["type": "image", "source": "sfSymbol", "systemImage": "a", "tint": "blue"],
                                    "rightSlot": ["type": "progress", "tint": "blue"]],
            "sneakPeek": ["leftSlot": ["type": "text", "text": "L", "style": "marquee"],
                          "center": ["type": "text", "text": "C", "style": "marquee"]],
            "extraLiveActivity": ["leftSlot": ["type": "image", "source": "sfSymbol", "systemImage": "x", "tint": "blue"]],
        ])
    }

    @Test func theThreeMessages() throws {
        let surfaces = Surfaces(pillLeft: .symbol("a", tint: "blue"), pillRight: .ring(value: 1, tint: "blue"))
        let create = try json(LakeMessage.create("extraction-7", surfaces: surfaces))
        #expect(create["schemaVersion"] as? Int == 1)
        #expect(create["type"] as? String == "create")
        #expect(create["activityID"] as? String == "extraction-7")
        #expect(create["title"] as? String == "Extraction")
        #expect(create["priority"] as? String == "normal")
        #expect(create["size"] as? String == "small")
        #expect(create["surfaces"] != nil)
        #expect(create["presentSneakPeek"] == nil)

        let update = try json(LakeMessage.update("extraction-7", surfaces: surfaces, presentSneakPeek: 7))
        #expect(update["type"] as? String == "update")
        #expect(update["presentSneakPeek"] as? Int == 7)
        #expect(update["title"] == nil)
        #expect(update["priority"] == nil)

        #expect(try json(LakeMessage.dismiss("extraction-7")) == ["schemaVersion": 1, "type": "dismiss", "activityID": "extraction-7"])
    }
}
