import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import TelegramUIPreferences
import AccountContext
import AnimationCache
import MultiAnimationRenderer
import EmojiTextAttachmentView

// The superfolder of an account and its folders, as chat list folders that are kept on the device: the list of
// the superfolder's tab uses them like any folder, and «Chats» leaves the superfolder's chats out.
public enum Superfolders {
    // The superfolder's own list.
    public static let filterId: Int32 = -201
    // Its folders take ids below this one.
    private static let firstFolderId: Int32 = -300

    public static func isFolderId(_ id: Int32?) -> Bool {
        guard let id else {
            return false
        }
        return id <= firstFolderId && id > -1000
    }

    // The superfolder itself or one of its folders.
    public static func isOwnFilterId(_ id: Int32?) -> Bool {
        return id == filterId || isFolderId(id)
    }

    // The latest settings of each account, for the places that read them synchronously (context menus, the tab
    // bar). They are filled by `settings(engine:)`.
    private static let cachedSettings = Atomic<[EnginePeer.Id: SuperfolderSettings]>(value: [:])

    public static func settings(engine: TelegramEngine) -> Signal<SuperfolderSettings, NoError> {
        let accountPeerId = engine.account.peerId
        return engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: ApplicationSpecificPreferencesKeys.superfolderSettings))
        |> map { entry -> SuperfolderSettings in
            return entry?.get(SuperfolderSettings.self) ?? .default
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

    public static func currentSettings(accountPeerId: EnginePeer.Id) -> SuperfolderSettings {
        return cachedSettings.with { $0[accountPeerId] } ?? .default
    }

    public static func update(engine: TelegramEngine, _ f: @escaping (inout SuperfolderSettings) -> Void) {
        let _ = updateSuperfolderSettings(engine: engine, { settings in
            var settings = settings
            f(&settings)
            return settings
        }).startStandalone()
    }

    // Takes a chat into the superfolder or out of it. A chat that would stay in by its type is excluded instead.
    public static func setChat(engine: TelegramEngine, peerId: EnginePeer.Id, isInside: Bool, staysInByType: Bool) {
        let id = peerId.toInt64()
        self.update(engine: engine, { settings in
            settings.includePeerIds.removeAll(where: { $0 == id })
            settings.excludePeerIds.removeAll(where: { $0 == id })
            if isInside {
                settings.includePeerIds.insert(id, at: 0)
            } else {
                settings.pinnedPeerIds.removeAll(where: { $0 == id })
                settings.alsoInChatListPeerIds.removeAll(where: { $0 == id })
                if staysInByType {
                    settings.excludePeerIds.append(id)
                }
            }
        })
    }

    public static func filter(settings: SuperfolderSettings) -> ChatListFilter {
        return self.makeFilter(id: filterId, title: settings.title, includePeerIds: settings.includePeerIds, pinnedPeerIds: settings.pinnedPeerIds, excludePeerIds: settings.excludePeerIds, categories: settings.categories, excludeMuted: false, excludeRead: false, excludeArchived: false, color: nil)
    }

    public static func filter(folder: SuperfolderSettings.Folder) -> ChatListFilter {
        return self.makeFilter(id: folder.id, title: folder.title, includePeerIds: folder.includePeerIds, pinnedPeerIds: folder.pinnedPeerIds, excludePeerIds: folder.excludePeerIds, categories: folder.categories, excludeMuted: folder.excludeMuted, excludeRead: folder.excludeRead, excludeArchived: folder.excludeArchived, color: folder.color)
    }

    // The superfolder's list first, then its folders.
    public static func filters(settings: SuperfolderSettings) -> [ChatListFilter] {
        return [self.filter(settings: settings)] + settings.folders.map { self.filter(folder: $0) }
    }

    public static func nextFolderId(settings: SuperfolderSettings) -> Int32 {
        return (settings.folders.map(\.id).min() ?? (firstFolderId + 1)) - 1
    }

    private static func makeFilter(id: Int32, title: String, includePeerIds: [Int64], pinnedPeerIds: [Int64], excludePeerIds: [Int64], categories: Int32, excludeMuted: Bool, excludeRead: Bool, excludeArchived: Bool, color: Int32?) -> ChatListFilter {
        var include = ChatListFilterIncludePeers()
        include.setPeers(includePeerIds.map { EnginePeer.Id($0) })
        for peerId in pinnedPeerIds.reversed() {
            let _ = include.addPinnedPeer(EnginePeer.Id(peerId))
        }
        let data = ChatListFilterData(
            isShared: false,
            hasSharedLinks: false,
            categories: ChatListFilterPeerCategories(rawValue: categories),
            excludeMuted: excludeMuted,
            excludeRead: excludeRead,
            excludeArchived: excludeArchived,
            includePeers: include,
            excludePeers: excludePeerIds.map { EnginePeer.Id($0) },
            color: color.map { PeerNameColor(rawValue: $0) }
        )
        return .filter(id: id, title: ChatFolderTitle(text: title, entities: [], enableAnimations: false), emoticon: nil, data: data)
    }

    // The icon as a picture for the tab: the first frame of a custom emoji, or a plain emoji drawn as text.
    public static func iconImage(context: AccountContext, icon: SuperfolderSettings.Icon?, size: CGSize) -> Signal<UIImage?, NoError> {
        if let fileId = icon?.customEmojiFileId {
            return context.engine.stickers.resolveInlineStickers(fileIds: [fileId])
            |> mapToSignal { files -> Signal<UIImage?, NoError> in
                guard let file = files[fileId] else {
                    return .single(nil)
                }
                return Signal { subscriber in
                    return context.animationRenderer.loadFirstFrameAsImage(cache: context.animationCache, itemId: file.resource.id.stringRepresentation, size: CGSize(width: 96.0, height: 96.0), fetch: animationCacheFetchFile(context: context, userLocation: .other, userContentType: .sticker, resource: .media(media: .standalone(media: file), resource: file.resource), type: AnimationCacheAnimationType(file: file), keyframeOnly: true, customColor: nil), completion: { cgImage in
                        guard let cgImage else {
                            return
                        }
                        let image = generateImage(size, contextGenerator: { size, c in
                            c.clear(CGRect(origin: CGPoint(), size: size))
                            c.draw(cgImage, in: CGRect(origin: CGPoint(), size: size))
                        })
                        subscriber.putNext(image?.withRenderingMode(.alwaysOriginal))
                        subscriber.putCompletion()
                    })
                }
            }
        } else if let emoji = icon?.emoji {
            let image = generateImage(size, rotatedContext: { size, c in
                c.clear(CGRect(origin: CGPoint(), size: size))
                UIGraphicsPushContext(c)
                let string = NSAttributedString(string: emoji, attributes: [.font: UIFont.systemFont(ofSize: floor(size.height * 0.8))])
                let bounds = string.boundingRect(with: size, options: .usesLineFragmentOrigin, context: nil)
                string.draw(at: CGPoint(x: (size.width - bounds.width) / 2.0, y: (size.height - bounds.height) / 2.0))
                UIGraphicsPopContext()
            })
            return .single(image?.withRenderingMode(.alwaysOriginal))
        } else {
            return .single(nil)
        }
    }
}
