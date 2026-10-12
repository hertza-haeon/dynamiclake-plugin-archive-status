// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// One thing DynamicLake draws in a slot of a card. These are the kinds
/// Firefox Downloads uses, all seen working on a real notch.
public enum Component: Equatable, Sendable, Encodable {
    /// One of macOS's own symbols, tinted.
    case symbol(String, tint: String)
    /// One of the plugin's pictures: a PNG written in base64.
    case picture(base64: String)
    /// The progress ring; without a value it spins.
    case ring(value: Double?, tint: String)
    /// One of DynamicLake's own status symbols (`success`…).
    case status(String, tint: String)
    /// A symbol on a tinted circle that can be pressed. `title` is only
    /// what VoiceOver reads.
    case button(title: String, symbol: String, actionID: String, tint: String)
    /// Text: `marquee` scrolls when it is too long, `numeric` has digits
    /// that change in place.
    case text(String, style: String)

    private enum Key: String, CodingKey {
        case type, source, systemImage, tint, mimeType, base64Data, value, status, title, actionID, shape, text, style
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .symbol(let name, let tint):
            try container.encode("image", forKey: .type)
            try container.encode("sfSymbol", forKey: .source)
            try container.encode(name, forKey: .systemImage)
            try container.encode(tint, forKey: .tint)
        case .picture(let base64):
            try container.encode("image", forKey: .type)
            try container.encode("inlineData", forKey: .source)
            try container.encode("image/png", forKey: .mimeType)
            try container.encode(base64, forKey: .base64Data)
        case .ring(let value, let tint):
            try container.encode("progress", forKey: .type)
            try container.encode(tint, forKey: .tint)
            try container.encodeIfPresent(value, forKey: .value)
        case .status(let status, let tint):
            try container.encode("status", forKey: .type)
            try container.encode(status, forKey: .status)
            try container.encode(tint, forKey: .tint)
        case .button(let title, let symbol, let actionID, let tint):
            try container.encode("button", forKey: .type)
            try container.encode(title, forKey: .title)
            try container.encode(symbol, forKey: .systemImage)
            try container.encode(actionID, forKey: .actionID)
            try container.encode("circle", forKey: .shape)
            try container.encode(tint, forKey: .tint)
        case .text(let text, let style):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(style, forKey: .style)
        }
    }
}

/// Everything a card shows: the pill, the sneak peek under it, and the
/// small capsule it becomes while another activity has the main place.
public struct Surfaces: Equatable, Sendable, Encodable {
    public var pillLeft: Component
    public var pillRight: Component
    public var peekLeft: Component?
    public var peekCenter: Component?
    public var peekRight: Component?
    /// DynamicLake draws the capsule once, when the card gets there, and
    /// not again while it stays: it only holds what stays true.
    public var capsule: Component?

    private enum Key: String, CodingKey {
        case compactLiveActivity, sneakPeek, extraLiveActivity
    }

    private enum Slot: String, CodingKey {
        case leftSlot, center, rightSlot
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        var pill = container.nestedContainer(keyedBy: Slot.self, forKey: .compactLiveActivity)
        try pill.encode(pillLeft, forKey: .leftSlot)
        try pill.encode(pillRight, forKey: .rightSlot)
        var peek = container.nestedContainer(keyedBy: Slot.self, forKey: .sneakPeek)
        try peek.encodeIfPresent(peekLeft, forKey: .leftSlot)
        try peek.encodeIfPresent(peekCenter, forKey: .center)
        try peek.encodeIfPresent(peekRight, forKey: .rightSlot)
        if let capsule {
            var extra = container.nestedContainer(keyedBy: Slot.self, forKey: .extraLiveActivity)
            try extra.encode(capsule, forKey: .leftSlot)
        }
    }
}

/// What the plugin tells DynamicLake about one card.
public struct LakeMessage: Equatable, Sendable, Encodable {
    public enum Kind: String, Sendable, Encodable {
        case create, update, dismiss
    }

    public var schemaVersion = 1
    public var type: Kind
    public var activityID: String
    public var title: String?
    public var priority: String?
    public var size: String?
    public var surfaces: Surfaces?
    /// Seconds for which the sneak peek opens with this message.
    public var presentSneakPeek: Int?

    /// A new card. (A sneak peek asked for with it is ignored by
    /// DynamicLake: it is asked for a moment later.)
    static func create(_ activityID: String, surfaces: Surfaces) -> LakeMessage {
        LakeMessage(type: .create, activityID: activityID, title: "Extraction", priority: "normal", size: "small",
                    surfaces: surfaces)
    }

    static func update(_ activityID: String, surfaces: Surfaces? = nil, presentSneakPeek: Int? = nil) -> LakeMessage {
        LakeMessage(type: .update, activityID: activityID, surfaces: surfaces, presentSneakPeek: presentSneakPeek)
    }

    /// Only the card's priority: `high` takes the main place, `low` lets
    /// another activity move up, `normal` is the usual one.
    static func priority(_ activityID: String, _ priority: String) -> LakeMessage {
        LakeMessage(type: .update, activityID: activityID, priority: priority)
    }

    static func dismiss(_ activityID: String) -> LakeMessage {
        LakeMessage(type: .dismiss, activityID: activityID)
    }
}

/// A button pressed on one of the plugin's cards.
public struct LakeAction: Equatable, Sendable {
    public var activityID: String
    public var actionID: String

    public init(activityID: String, actionID: String) {
        self.activityID = activityID
        self.actionID = actionID
    }
}
