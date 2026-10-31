import Foundation
import SwiftSignalKit
import TelegramCore

// How the topics of each Threaded Mode bot are shown in the chat list. Kept per account; a bot that was never
// set up is shown the default way, with all its topics under it.
public struct ThreadedBotSettings: Equatable, Codable {
    public struct Bot: Equatable, Codable {
        public var peerId: Int64
        // One row for the bot, like a community: its topics open from that row.
        public var showAsOneChat: Bool
        // The stock way: no topics under the bot, the topic switcher inside its chat.
        public var topicsInside: Bool
        // Topics taken off the chat list. New topics are shown, so only the hidden ones are kept.
        public var hiddenTopicIds: [Int64]

        public init(peerId: Int64, showAsOneChat: Bool = false, topicsInside: Bool = false, hiddenTopicIds: [Int64] = []) {
            self.peerId = peerId
            self.showAsOneChat = showAsOneChat
            self.topicsInside = topicsInside
            self.hiddenTopicIds = hiddenTopicIds
        }
    }

    public var bots: [Bot]

    public static var `default`: ThreadedBotSettings {
        return ThreadedBotSettings(bots: [])
    }

    public init(bots: [Bot]) {
        self.bots = bots
    }

    public func bot(_ peerId: EnginePeer.Id) -> Bot {
        let id = peerId.toInt64()
        return self.bots.first(where: { $0.peerId == id }) ?? Bot(peerId: id)
    }

    public mutating func updateBot(_ peerId: EnginePeer.Id, _ f: (inout Bot) -> Void) {
        var bot = self.bot(peerId)
        f(&bot)
        self.bots.removeAll(where: { $0.peerId == bot.peerId })
        if bot != Bot(peerId: bot.peerId) {
            self.bots.append(bot)
        }
    }
}

public func updateThreadedBotSettings(engine: TelegramEngine, _ f: @escaping (ThreadedBotSettings) -> ThreadedBotSettings) -> Signal<Never, NoError> {
    return engine.preferences.update(id: ApplicationSpecificPreferencesKeys.threadedBotSettings, { entry in
        let currentSettings = entry?.get(ThreadedBotSettings.self) ?? .default
        return SharedPreferencesEntry(f(currentSettings))
    })
}
