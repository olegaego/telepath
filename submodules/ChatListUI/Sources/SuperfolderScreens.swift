import Foundation
import Display
import TelegramCore
import AccountContext
import Superfolders

// Agentgram: the superfolder's screens, built from Telegram's folder screens, kept out of their file

// The superfolder's own screen: its name, icon and chats.
public func superfolderController(context: AccountContext) -> ViewController {
    let settings = Superfolders.currentSettings(accountPeerId: context.account.peerId)
    return chatListFilterPresetController(context: context, currentPreset: Superfolders.filter(settings: settings), isSuperfolder: true, updated: { _ in })
}

// The chat picker of a folder, straight for the superfolder: the chats and types of chats go to it.
func superfolderAddChatsController(context: AccountContext) -> ViewController {
    let settings = Superfolders.currentSettings(accountPeerId: context.account.peerId)
    return internalChatListFilterAddChatsController(context: context, filter: Superfolders.filter(settings: settings), allFilters: [], applyAutomatically: false, limit: 1000, premiumLimit: 1000, isPremium: true, updated: { filter in
        guard case let .filter(_, _, _, data) = filter else {
            return
        }
        Superfolders.update(engine: context.engine, { settings in
            settings.includePeerIds = data.includePeers.peers.map { $0.toInt64() }
            settings.categories = data.categories.rawValue
        })
    }, presentUndo: { _ in })
}
