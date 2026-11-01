import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import ChatFolderLinkPreviewScreen
import TelegramUIPreferences
import Superfolders
import ChatListFilterTabContainerNode

// Agentgram: the superfolder's side of the chat list, kept out of Telegram's ChatListController so its updates merge
// cleanly. The superfolder is a second tab with the same list: its own chats, its own folders as tabs, its title and icon.

extension ChatListControllerImpl {
    // The superfolder's tab: add a folder to it, or switch between it and its folders. True when it showed its menu.
    func superfolderTabMenu(sourceView: ContextExtractedContentContainingView, gesture: ContextGesture?) -> Bool {
        guard self.isSuperfolder else {
            return false
        }
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.ChatList_AddFolder, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Add"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] c, _ in
            c?.dismiss(completion: {
                // As a sheet over everything, like the folders of «Chats», so it opens from any tab.
                guard let self, let navigationController = self.context.sharedContext.mainWindow?.viewController as? NavigationController else {
                    return
                }
                navigationController.pushViewController(chatListFilterPresetListController(context: self.context, mode: .modal, showsSuperfolder: true))
            })
        })))
        let settings = self.superfolderSettings
        if !settings.folders.isEmpty {
            items.append(.separator)
            var entries: [(Int32, String, String)] = [(Superfolders.filterId, self.presentationData.strings.ChatList_FolderAllChats, "Chat/Context Menu/Chats")]
            entries.append(contentsOf: settings.folders.map { ($0.id, $0.title, "Chat/Context Menu/List") })
            for (id, title, iconName) in entries {
                items.append(.action(ContextMenuActionItem(text: title, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: iconName), color: theme.contextMenu.primaryColor)
                }, action: { [weak self] _, f in
                    f(.dismissWithoutContent)
                    self?.selectTab(id: .filter(id))
                })))
            }
        }
        let controller = makeContextController(context: self.context, presentationData: self.presentationData, source: .reference(ChatListTabBarContextReferenceContentSource(controller: self, sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: gesture)
        self.context.sharedContext.mainWindow?.presentInGlobalOverlay(controller)
        return true
    }

    func superfolderFolderMenu(id: Int32?) {
        guard let id, Superfolders.isFolderId(id), let folder = self.superfolderSettings.folders.first(where: { $0.id == id }) else {
            return
        }
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: folder.title),
                ActionSheetButtonItem(title: self.presentationData.strings.ChatList_EditFolder, color: .accent, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let self else {
                        return
                    }
                    self.push(chatListFilterPresetController(context: self.context, currentPreset: Superfolders.filter(folder: folder), superfolderFolderId: folder.id, updated: { _ in }))
                }),
                ActionSheetButtonItem(title: self.presentationData.strings.ChatList_RemoveFolder, color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    guard let self else {
                        return
                    }
                    if self.chatListDisplayNode.mainContainerNode.currentItemFilter == .filter(id) {
                        self.chatListDisplayNode.mainContainerNode.switchToFilter(id: .filter(Superfolders.filterId))
                    }
                    Superfolders.update(engine: self.context.engine, { settings in
                        settings.folders.removeAll(where: { $0.id == id })
                    })
                })
            ]),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        self.present(actionSheet, in: .window(.root))
    }

    var superfolderTitle: String {
        return self.superfolderSettings.title.isEmpty ? Superfolders.text(.defaultTitle, languageCode: self.presentationData.strings.primaryComponent.languageCode) : self.superfolderSettings.title
    }

    // Agentgram: the superfolder's tab title and icon, from its settings, as soon as the tab exists
    func followSuperfolderTabItem() {
        let context = self.context
        self.superfolderTitleDisposable.set((Superfolders.settings(engine: context.engine)
        |> deliverOnMainQueue).startStrict(next: { [weak self] settings in
            guard let self else {
                return
            }
            self.superfolderSettings = settings
            self.tabBarItem.title = self.superfolderTitle
        }))
        self.superfolderTabIconDisposable.set((Superfolders.settings(engine: context.engine)
        |> map { $0.icon }
        |> distinctUntilChanged
        |> mapToSignal { icon -> Signal<UIImage?, NoError> in
            return Superfolders.iconImage(context: context, icon: icon, size: CGSize(width: 28.0, height: 28.0))
        }
        |> deliverOnMainQueue).startStrict(next: { [weak self] image in
            guard let self else {
                return
            }
            self.superfolderTabIcon = image
            let icon = image ?? UIImage(bundleImageName: "Chat List/Tabs/IconChats")
            self.tabBarItem.image = icon
            self.tabBarItem.selectedImage = icon
        }))
    }

    // The superfolder's list is a folder kept on the device, with its own folders as tabs; it follows the settings.
    func reloadSuperfolder() {
        let context = self.context
        // Its settings, with the unread chats of it and of each of its folders for the folder tabs.
        let settingsAndUnread = Superfolders.settings(engine: context.engine)
        |> mapToSignal { settings -> Signal<(SuperfolderSettings, [Int32: (Int, Bool)]), NoError> in
            return chatListFilterItems(context: context, filters: .single(Superfolders.filters(settings: settings)))
            |> map { _, items -> (SuperfolderSettings, [Int32: (Int, Bool)]) in
                var unread: [Int32: (Int, Bool)] = [:]
                for (filter, count, hasUnmuted) in items {
                    unread[filter.id] = (count, hasUnmuted)
                }
                return (settings, unread)
            }
        }
        self.superfolderSettingsDisposable.set((settingsAndUnread
        |> deliverOnMainQueue).startStrict(next: { [weak self] settings, unread in
            guard let self else {
                return
            }
            self.superfolderSettings = settings
            self.tabBarItem.title = self.superfolderTitle
            let filters = Superfolders.filters(settings: settings)
            if filters.count > 1 {
                self.tabContainerData = (filters.map { filter -> ChatListFilterTabEntry in
                    var text = ChatFolderTitle(text: self.superfolderTitle, entities: [], enableAnimations: false)
                    if filter.id != Superfolders.filterId, case let .filter(_, folderTitle, _, _) = filter {
                        text = folderTitle
                    }
                    let count = unread[filter.id] ?? (0, false)
                    return .filter(id: filter.id, text: text, unread: ChatListFilterTabEntryUnreadCount(value: count.0, hasUnmuted: count.1))
                }, false, nil)
            } else {
                self.tabContainerData = ([], false, nil)
            }
            self.chatListDisplayNode.mainContainerNode.updateAvailableFilters(filters.map { .filter($0) }, limit: nil)
            if !self.initializedFilters {
                self.initializedFilters = true
                // The list starts on the superfolder already, there is no switch to wait for.
                self.mainReady.set(self.chatListDisplayNode.mainContainerNode.currentItemNode.ready)
            }
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout, transition: .immediate)
                (self.parent as? TabBarController)?.updateLayout(transition: .immediate)
            }
        }))
    }
}
