import Foundation
import TelegramCore
import SwiftSignalKit
import AccountContext
import ThreadedBotSessions

// Agentgram: Threaded Mode in the chat list. Each topic of a Threaded Mode bot is listed right under the bot.
// The list itself is Telegram's (chatListViewForLocationPlain); this only adds the sessions to it.
public func chatListViewForLocation(chatListLocation: ChatListControllerLocation, location: ChatListNodeLocation, account: Account, shouldLoadCanMessagePeer: Bool) -> Signal<ChatListNodeViewUpdate, NoError> {
    let plain = chatListViewForLocationPlain(chatListLocation: chatListLocation, location: location, account: account, shouldLoadCanMessagePeer: shouldLoadCanMessagePeer)
    guard case .chatList = chatListLocation else {
        return plain
    }
    // every update of the list gets a number, so an update caused only by the sessions is not taken for a new one
    let counter = Atomic<Int>(value: 0)
    let main = Promise<(Int, ChatListNodeViewUpdate)>()
    main.set(plain |> map { update -> (Int, ChatListNodeViewUpdate) in
        return (counter.modify { $0 + 1 }, update)
    })
    // the settings come first: they also carry the master switch, which isThreadedBot reads
    let settings = ThreadedBotSessions.settings(engine: TelegramEngine(account: account))
    let bots: Signal<[EnginePeer.Id], NoError> = combineLatest(main.get(), settings)
    |> map { main, settings -> [EnginePeer.Id] in
        if settings.threadedModeOff == true {
            return []
        }
        return main.1.list.items.compactMap { item -> EnginePeer.Id? in
            guard case .chatList = item.index, ThreadedBotSessions.isThreadedBot(item.renderedPeer.peer) else {
                return nil
            }
            return item.renderedPeer.peerId
        }
    }
    |> distinctUntilChanged
    let sessions: Signal<[EnginePeer.Id: [EngineChatList.Item]], NoError> = bots
    |> mapToSignal { botIds -> Signal<[EnginePeer.Id: [EngineChatList.Item]], NoError> in
        if botIds.isEmpty {
            return .single([:])
        }
        return combineLatest(botIds.map { botId in
            let topics = chatListViewForLocationPlain(chatListLocation: .forum(peerId: botId), location: .initial(count: 50, filter: nil), account: account, shouldLoadCanMessagePeer: false)
            |> map { update -> (EnginePeer.Id, [EngineChatList.Item]) in
                return (botId, update.list.items)
            }
            let refresh = ThreadedBotSessions.keepTopicsFresh(engine: TelegramEngine(account: account), botId: botId)
            return Signal { subscriber in
                let topicsDisposable = topics.start(next: subscriber.putNext, completed: subscriber.putCompletion)
                let refreshDisposable = refresh.start()
                return ActionDisposable {
                    topicsDisposable.dispose()
                    refreshDisposable.dispose()
                }
            }
        })
        |> map { pairs -> [EnginePeer.Id: [EngineChatList.Item]] in
            return Dictionary(pairs, uniquingKeysWith: { lhs, _ in lhs })
        }
    }
    let lastNumber = Atomic<Int>(value: -1)
    return combineLatest(main.get(), sessions, settings)
    |> map { main, sessions, threadedBotSettings -> ChatListNodeViewUpdate in
        let (number, update) = main
        let onlySessionsChanged = lastNumber.swap(number) == number
        var items = update.list.items
        for item in update.list.items {
            guard case let .chatList(index) = item.index, let topics = sessions[item.renderedPeer.peerId], !topics.isEmpty else {
                continue
            }
            // a bot shown as one row has no sessions under it; the sessions taken off the list are not there
            let settings = threadedBotSettings.bot(item.renderedPeer.peerId)
            if settings.showAsOneChat || settings.topicsInside {
                continue
            }
            let visible = topics.filter { topic in
                if case let .forum(threadId) = topic.id {
                    return !settings.hiddenTopicIds.contains(threadId)
                }
                return true
            }
            // The chat list is ordered by ChatListIndex alone, so a session gets the bot's index with a slightly smaller
            // message id: it sorts right below the bot, newest session first, and moves with the bot.
            let newestFirst = visible.sorted(by: { $0.index > $1.index }).prefix(ThreadedBotSessions.sessionsPerBot)
            for (j, topic) in newestFirst.enumerated() {
                guard case let .forum(_, _, threadId, _, _) = topic.index else {
                    continue
                }
                let messageIndex = index.messageIndex
                let sessionIndex = EngineChatListIndex(pinningIndex: index.pinningIndex, messageIndex: EngineMessage.Index(id: EngineMessage.Id(peerId: messageIndex.id.peerId, namespace: messageIndex.id.namespace, id: messageIndex.id.id - 1 - Int32(j)), timestamp: messageIndex.timestamp))
                items.append(EngineChatList.Item(id: .forum(threadId), index: .chatList(sessionIndex), messages: topic.messages, readCounters: topic.readCounters, isMuted: topic.isMuted, draft: topic.draft, threadData: topic.threadData, renderedPeer: item.renderedPeer, presence: topic.presence, hasUnseenMentions: topic.hasUnseenMentions, hasUnseenReactions: topic.hasUnseenReactions, hasUnseenPollVotes: topic.hasUnseenPollVotes, forumTopicData: nil, topForumTopicItems: [], hasFailed: topic.hasFailed, isContact: false, autoremoveTimeout: topic.autoremoveTimeout, storyStats: nil, displayAsTopicList: false, isPremiumRequiredToMessage: false, mediaDraftContentType: topic.mediaDraftContentType))
            }
        }
        items.sort(by: { $0.index < $1.index })
        let list = EngineChatList(items: items, groupItems: update.list.groupItems, additionalItems: update.list.additionalItems, hasEarlier: update.list.hasEarlier, hasLater: update.list.hasLater, isLoading: update.list.isLoading)
        return ChatListNodeViewUpdate(list: list, type: onlySessionsChanged ? .Generic : update.type, scrollPosition: onlySessionsChanged ? nil : update.scrollPosition)
    }
}
