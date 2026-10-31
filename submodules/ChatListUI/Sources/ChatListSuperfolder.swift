import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import Superfolders

// Whether a chat is in the superfolder: by itself, pinned there or by its type, and not kept out of it.
func superfolderIncludes(settings: SuperfolderSettings, peer: EnginePeer, isContact: Bool, isMuted: Bool, isUnread: Bool, accountPeerId: EnginePeer.Id) -> Bool {
    guard settings.isCreated, case let .filter(_, _, _, data) = Superfolders.filter(settings: settings) else {
        return false
    }
    let predicate = chatListFilterPredicate(filter: data, accountPeerId: accountPeerId)
    if predicate.excludePeerIds.contains(peer.id) {
        return false
    }
    if predicate.includePeerIds.contains(peer.id) || predicate.pinnedPeerIds.contains(peer.id) {
        return true
    }
    if data.categories.isEmpty {
        return false
    }
    return predicate.include(peer._asPeer(), isMuted, isUnread, isContact, nil)
}

// Pinning in the superfolder and its folders goes to its settings, not to a folder of the account.
private func superfolderPinnedPeerIds(settings: SuperfolderSettings, filterId: Int32) -> [Int64] {
    if filterId == Superfolders.filterId {
        return settings.pinnedPeerIds
    }
    return settings.folders.first(where: { $0.id == filterId })?.pinnedPeerIds ?? []
}

private func setSuperfolderPinnedPeerIds(settings: inout SuperfolderSettings, filterId: Int32, _ peerIds: [Int64]) {
    if filterId == Superfolders.filterId {
        settings.pinnedPeerIds = peerIds
    } else if let index = settings.folders.firstIndex(where: { $0.id == filterId }) {
        settings.folders[index].pinnedPeerIds = peerIds
    }
}

func chatListPinnedItemIds(engine: TelegramEngine, location: TogglePeerChatPinnedLocation) -> Signal<[EngineChatList.PinnedItem.Id], NoError> {
    if case let .filter(id) = location, Superfolders.isOwnFilterId(id) {
        let settings = Superfolders.currentSettings(accountPeerId: engine.account.peerId)
        return .single(superfolderPinnedPeerIds(settings: settings, filterId: id).map { .peer(EnginePeer.Id($0)) })
    }
    return engine.peers.getPinnedItemIds(location: location)
}

func chatListToggleItemPinned(engine: TelegramEngine, location: TogglePeerChatPinnedLocation, itemId: EngineChatList.PinnedItem.Id) -> Signal<TogglePeerChatPinnedResult, NoError> {
    if case let .filter(id) = location, Superfolders.isOwnFilterId(id), case let .peer(peerId) = itemId {
        let value = peerId.toInt64()
        Superfolders.update(engine: engine, { settings in
            var peerIds = superfolderPinnedPeerIds(settings: settings, filterId: id)
            if peerIds.contains(value) {
                peerIds.removeAll(where: { $0 == value })
            } else {
                peerIds.insert(value, at: 0)
            }
            setSuperfolderPinnedPeerIds(settings: &settings, filterId: id, peerIds)
        })
        return .single(.done)
    }
    return engine.peers.toggleItemPinned(location: location, itemId: itemId)
}

func chatListReorderPinnedItemIds(engine: TelegramEngine, location: TogglePeerChatPinnedLocation, itemIds: [EngineChatList.PinnedItem.Id]) -> Signal<Bool, NoError> {
    if case let .filter(id) = location, Superfolders.isOwnFilterId(id) {
        let peerIds = itemIds.compactMap { itemId -> Int64? in
            if case let .peer(peerId) = itemId {
                return peerId.toInt64()
            }
            return nil
        }
        Superfolders.update(engine: engine, { settings in
            setSuperfolderPinnedPeerIds(settings: &settings, filterId: id, peerIds)
        })
        return .single(true)
    }
    return engine.peers.reorderPinnedItemIds(location: location, itemIds: itemIds)
}

// The superfolder's members the chat list found among the chats it shows, including the ones in it by their type,
// for the stories of the superfolder's people.
private let resolvedMembers = Atomic<[EnginePeer.Id: ValuePromise<Set<EnginePeer.Id>>]>(value: [:])

private func resolvedMembersPromise(accountPeerId: EnginePeer.Id) -> ValuePromise<Set<EnginePeer.Id>> {
    return resolvedMembers.modify { current in
        if current[accountPeerId] != nil {
            return current
        }
        var current = current
        current[accountPeerId] = ValuePromise(Set(), ignoreRepeated: true)
        return current
    }[accountPeerId]!
}

func superfolderResolvedMembers(accountPeerId: EnginePeer.Id) -> Signal<Set<EnginePeer.Id>, NoError> {
    return resolvedMembersPromise(accountPeerId: accountPeerId).get()
}

func setSuperfolderResolvedMembers(accountPeerId: EnginePeer.Id, _ members: Set<EnginePeer.Id>) {
    resolvedMembersPromise(accountPeerId: accountPeerId).set(members)
}
