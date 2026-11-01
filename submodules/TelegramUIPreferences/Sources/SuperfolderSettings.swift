import Foundation
import SwiftSignalKit
import TelegramCore

// The superfolder: a second chat list, on a tab of its own, with its own chats and folders. Kept per account;
// an account has none until it is created in Settings.
public struct SuperfolderSettings: Equatable, Codable {
    // A folder inside the superfolder. It shows only the superfolder's chats that it selects.
    public struct Folder: Equatable, Codable {
        public var id: Int32
        public var title: String
        public var includePeerIds: [Int64]
        public var pinnedPeerIds: [Int64]
        public var excludePeerIds: [Int64]
        public var categories: Int32
        public var excludeMuted: Bool
        public var excludeRead: Bool
        public var excludeArchived: Bool
        public var color: Int32?

        public init(id: Int32, title: String, includePeerIds: [Int64], pinnedPeerIds: [Int64], excludePeerIds: [Int64], categories: Int32, excludeMuted: Bool, excludeRead: Bool, excludeArchived: Bool, color: Int32?) {
            self.id = id
            self.title = title
            self.includePeerIds = includePeerIds
            self.pinnedPeerIds = pinnedPeerIds
            self.excludePeerIds = excludePeerIds
            self.categories = categories
            self.excludeMuted = excludeMuted
            self.excludeRead = excludeRead
            self.excludeArchived = excludeArchived
            self.color = color
        }
    }

    // The tab's icon: an emoji, plain or custom.
    public struct Icon: Equatable, Codable {
        public var customEmojiFileId: Int64?
        public var emoji: String?

        public init(customEmojiFileId: Int64?, emoji: String?) {
            self.customEmojiFileId = customEmojiFileId
            self.emoji = emoji
        }
    }

    public var isCreated: Bool
    public var title: String
    public var icon: Icon?
    // The chats in it by themselves, the pinned ones, the ones kept out although their type is in it, and the
    // types of chats in it as a whole.
    public var includePeerIds: [Int64]
    public var pinnedPeerIds: [Int64]
    public var excludePeerIds: [Int64]
    public var categories: Int32
    // By default its chats leave «Chats»; when this is on they stay there too.
    public var keepsChatsInChatList: Bool
    // With `keepsChatsInChatList` off, these chats are still shown in «Chats» too.
    public var alsoInChatListPeerIds: [Int64]
    public var folders: [Folder]

    public static var `default`: SuperfolderSettings {
        return SuperfolderSettings(isCreated: false, title: "", icon: nil, includePeerIds: [], pinnedPeerIds: [], excludePeerIds: [], categories: 0, keepsChatsInChatList: false, alsoInChatListPeerIds: [], folders: [])
    }

    public init(isCreated: Bool, title: String, icon: Icon?, includePeerIds: [Int64], pinnedPeerIds: [Int64], excludePeerIds: [Int64], categories: Int32, keepsChatsInChatList: Bool, alsoInChatListPeerIds: [Int64], folders: [Folder]) {
        self.isCreated = isCreated
        self.title = title
        self.icon = icon
        self.includePeerIds = includePeerIds
        self.pinnedPeerIds = pinnedPeerIds
        self.excludePeerIds = excludePeerIds
        self.categories = categories
        self.keepsChatsInChatList = keepsChatsInChatList
        self.alsoInChatListPeerIds = alsoInChatListPeerIds
        self.folders = folders
    }
}

public func updateSuperfolderSettings(engine: TelegramEngine, _ f: @escaping (SuperfolderSettings) -> SuperfolderSettings) -> Signal<Never, NoError> {
    return engine.preferences.update(id: ApplicationSpecificPreferencesKeys.superfolderSettings, { entry in
        let currentSettings = entry?.get(SuperfolderSettings.self) ?? .default
        return SharedPreferencesEntry(f(currentSettings))
    })
}
