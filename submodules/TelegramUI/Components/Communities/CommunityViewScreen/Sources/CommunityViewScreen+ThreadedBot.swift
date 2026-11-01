import Foundation
import Display
import AccountContext
import TelegramCore
import ListItemComponentAdaptor
import ChatListUI

// Agentgram: Threaded Mode on the community screen. The arrow on a Threaded Mode bot opens this screen for the bot,
// listing its sessions (topics) in place of a community's chats.

// the sessions (topics) of a Threaded Mode bot, shown by this same screen in place of a community's chats
struct ThreadedBotSession: Equatable {
    let threadId: Int64
    let info: EngineMessageHistoryThread.Info
    let index: EngineChatList.Item.Index
    let messages: [EngineMessage]
    let readCounters: EnginePeerReadCounters?
    let shown: Bool
    let activity: PeerInputActivity?
}

final class ThreadedBotSessionItemGenerator: ListItemComponentAdaptor.ItemGenerator {
    let context: AccountContext
    let presentationData: ChatListPresentationData
    let bot: EnginePeer
    let session: ThreadedBotSession
    let interaction: ChatListNodeInteraction

    init(context: AccountContext, presentationData: ChatListPresentationData, bot: EnginePeer, session: ThreadedBotSession, interaction: ChatListNodeInteraction) {
        self.context = context
        self.presentationData = presentationData
        self.bot = bot
        self.session = session
        self.interaction = interaction
    }

    static func ==(lhs: ThreadedBotSessionItemGenerator, rhs: ThreadedBotSessionItemGenerator) -> Bool {
        return lhs.context === rhs.context && lhs.bot == rhs.bot && lhs.session == rhs.session && lhs.presentationData.theme === rhs.presentationData.theme && lhs.presentationData.fontSize == rhs.presentationData.fontSize && lhs.presentationData.strings === rhs.presentationData.strings
    }

    func item() -> ListViewItem {
        return ChatListItem(
            presentationData: self.presentationData,
            context: self.context,
            chatListLocation: .forum(peerId: self.bot.id),
            filterData: nil,
            index: self.session.index,
            content: .peer(ChatListItemContent.PeerData(
                messages: self.session.messages,
                peer: EngineRenderedPeer(peer: self.bot),
                threadInfo: ChatListItemContent.ThreadInfo(id: self.session.threadId, info: self.session.info, isOwnedByMe: true, isClosed: false, isHidden: false, threadPeer: nil),
                combinedReadState: self.session.readCounters,
                isRemovedFromTotalUnreadCount: false,
                presence: nil,
                hasUnseenMentions: false,
                hasUnseenReactions: false,
                hasUnseenPollVotes: false,
                draftState: nil,
                mediaDraftContentType: nil,
                inputActivities: self.session.activity.flatMap { [(self.bot, $0)] } ?? [],
                promoInfo: nil,
                ignoreUnreadBadge: false,
                displayAsMessage: false,
                hasFailedMessages: false,
                forumTopicData: nil,
                topForumTopicItems: [],
                autoremoveTimeout: nil,
                storyState: nil,
                requiresPremiumForMessaging: false,
                displayAsTopicList: false,
                tags: []
            )),
            editing: false,
            hasActiveRevealControls: false,
            selected: false,
            header: nil,
            enabledContextActions: nil,
            hiddenOffset: false,
            interaction: self.interaction,
            useCommunityViewLayout: true
        )
    }
}
