import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences

// Bots with Threaded Mode: each topic of such a bot is a session, listed right under the bot in the chat list.
public enum ThreadedBotSessions {
    // At most this many sessions are listed under a bot, newest first.
    public static let sessionsPerBot = 20
    // When a bot's topic is read on one device, the server knows it (messages.getForumTopics returns it as read),
    // but the other devices are not told and do not fetch the topics again, even on launch. So the list re-reads
    // them this often while it shows them.
    public static let refreshInterval: Double = 30.0

    public static func isThreadedBot(_ peer: EnginePeer?) -> Bool {
        if case let .user(user) = peer, let botInfo = user.botInfo, botInfo.flags.contains(.hasForum) {
            return true
        }
        return false
    }

    // The bot lets users start topics themselves (its «New Chat» button).
    public static func canStartSession(_ peer: EnginePeer?) -> Bool {
        if case let .user(user) = peer, let botInfo = user.botInfo, botInfo.flags.contains(.hasForum), botInfo.flags.contains(.forumManagedByUser) {
            return true
        }
        return false
    }

    // The bot's topics re-read from the server while a chat list shows them. Every open list (All Chats, each folder)
    // asks for it, so a bot is fetched at most once per `refreshInterval` whatever the number of lists.
    private static let lastRefresh = Atomic<[EnginePeer.Id: Double]>(value: [:])

    public static func keepTopicsFresh(engine: TelegramEngine, botId: EnginePeer.Id) -> Signal<Never, NoError> {
        let refreshIfDue: Signal<Never, NoError> = Signal<Void, NoError>.single(Void())
        |> mapToSignal { _ -> Signal<Never, NoError> in
            let now = CFAbsoluteTimeGetCurrent()
            let isDue = lastRefresh.modify { current in
                var current = current
                if let last = current[botId], now - last < refreshInterval - 1.0 {
                    return current
                }
                current[botId] = now
                return current
            }[botId] == now
            return isDue ? engine.peers.refreshForumTopics(peerId: botId) : .complete()
        }
        return (refreshIfDue |> then(.complete() |> delay(refreshInterval, queue: Queue.concurrentDefaultQueue())))
        |> restart
    }

    // The latest settings of each account, for the places that lay out synchronously (a chat list row, a chat's
    // title panel). They are filled by `settings(engine:)`, which the chat list keeps subscribed.
    private static let cachedSettings = Atomic<[EnginePeer.Id: ThreadedBotSettings]>(value: [:])

    public static func settings(engine: TelegramEngine) -> Signal<ThreadedBotSettings, NoError> {
        let accountPeerId = engine.account.peerId
        return engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: ApplicationSpecificPreferencesKeys.threadedBotSettings))
        |> map { entry -> ThreadedBotSettings in
            return entry?.get(ThreadedBotSettings.self) ?? .default
        }
        |> distinctUntilChanged
        |> afterNext { settings in
            let _ = cachedSettings.modify { current in
                var current = current
                current[accountPeerId] = settings
                return current
            }
        }
    }

    public static func currentSettings(accountPeerId: EnginePeer.Id) -> ThreadedBotSettings {
        return cachedSettings.with { $0[accountPeerId] } ?? .default
    }

    public static func updateBot(engine: TelegramEngine, botId: EnginePeer.Id, _ f: @escaping (inout ThreadedBotSettings.Bot) -> Void) {
        let _ = updateThreadedBotSettings(engine: engine, { settings in
            var settings = settings
            settings.updateBot(botId, f)
            return settings
        }).startStandalone()
    }
}
