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

    // Agentgram: the master switch («Agentgram → Topics view»). Off, every bot is shown the stock Telegram way:
    // no sessions in the chat list, no arrow, the topic switcher inside the bot's chat. Kept in the account's
    // ThreadedBotSettings, so the chat list follows it at once; read synchronously by the rows from here.
    private static let enabledValue = Atomic<Bool>(value: true)

    public static var isEnabled: Bool {
        return enabledValue.with { $0 }
    }

    public static func setEnabled(engine: TelegramEngine, _ value: Bool) {
        let _ = updateThreadedBotSettings(engine: engine, { settings in
            var settings = settings
            settings.threadedModeOff = value ? nil : true
            return settings
        }).startStandalone()
    }

    // Agentgram: Threaded Mode's own texts. The server's language packs do not have them, so a language switched
    // from the server would show them in English; the Russian ones live here.
    public enum Text {
        case topicsInside, topicsInsideInfo, listInfo, inChatList, otherTopics, topics, removeFromChatList, showInChatList
    }

    public static func text(_ text: Text, languageCode: String) -> String {
        let ru = languageCode.hasPrefix("ru")
        switch text {
        case .topicsInside:
            return ru ? "Темы внутри бота" : "Topics Inside the Bot"
        case .topicsInsideInfo:
            return ru ? "Одна строка для бота, его темы открываются внутри чата." : "One row for the bot, its topics open inside the chat."
        case .listInfo:
            return ru ? "Темы показываются под ботом. «Отображать как один чат» оставляет одну строку, как у сообщества." : "Topics are listed under the bot. Show as One Chat keeps a single row, like a community."
        case .inChatList:
            return ru ? "В СПИСКЕ ЧАТОВ" : "IN CHAT LIST"
        case .otherTopics:
            return ru ? "ДРУГИЕ ТЕМЫ" : "OTHER TOPICS"
        case .topics:
            return ru ? "ТЕМЫ" : "TOPICS"
        case .removeFromChatList:
            return ru ? "Убрать из списка чатов" : "Remove from Chat List"
        case .showInChatList:
            return ru ? "Показать в списке чатов" : "Show in Chat List"
        }
    }

    public static func isThreadedBot(_ peer: EnginePeer?) -> Bool {
        guard isEnabled else {
            return false
        }
        if case let .user(user) = peer, let botInfo = user.botInfo, botInfo.flags.contains(.hasForum) {
            return true
        }
        return false
    }

    // The bot lets users start topics themselves (its «New Chat» button).
    public static func canStartSession(_ peer: EnginePeer?) -> Bool {
        guard isEnabled else {
            return false
        }
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
            let _ = enabledValue.swap(settings.threadedModeOff != true)
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
