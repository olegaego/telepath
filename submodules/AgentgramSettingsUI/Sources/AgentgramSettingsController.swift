import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import AppBundle
import AgentgramCore
import ThreadedBotSessions
import Superfolders
import ChatListUI

// Agentgram: the «Agentgram» section of the settings. View (topics view, tabs, superfolder) works now; the agents
// part (computers, engines, agents) is listed as coming. Texts are here, in Russian and English, since the
// server's language packs do not have them.

private struct AgentgramTexts {
    let ru: Bool

    init(_ strings: PresentationStrings) {
        self.ru = strings.primaryComponent.languageCode.hasPrefix("ru")
    }

    var title: String { "Agentgram" }
    var viewHeader: String { ru ? "ВИД" : "VIEW" }
    var topicsView: String { ru ? "Вид тем" : "Topics View" }
    var tabs: String { ru ? "Вкладки" : "Tabs" }
    var superfolder: String { ru ? "Суперпапка" : "Superfolder" }
    var agentsHeader: String { ru ? "АГЕНТЫ" : "AGENTS" }
    var computers: String { ru ? "Компьютеры" : "Computers" }
    var engines: String { ru ? "Движки" : "Engines" }
    var agents: String { ru ? "Агенты" : "Agents" }
    var soon: String { ru ? "скоро" : "soon" }
    var create: String { ru ? "создать" : "create" }
    var agentsFooter: String { ru ? "Подключение Claude Code, Codex и своих компьютеров появится в следующих версиях." : "Connecting Claude Code, Codex and your computers is coming in the next versions." }
    var sessionsUnderBot: String { ru ? "Сессии под ботом" : "Sessions Under the Bot" }
    var stockTopics: String { ru ? "Обычные темы Telegram" : "Telegram's Own Topics" }
    var topicsHeader: String { ru ? "ТЕМЫ БОТОВ" : "BOT TOPICS" }
    var topicsFooter: String { ru ? "Сессии под ботом: темы бота видны прямо в списке чатов, под ботом, со статусами. Как показывать каждого бота, настраивается стрелкой на его аватарке.\n\nОбычные темы Telegram: у бота одна строка, темы открываются внутри его чата." : "Sessions under the bot: a bot's topics are right in the chat list, under the bot, with their status. How each bot is shown is set with the arrow on its avatar.\n\nTelegram's own topics: one row for the bot, its topics open inside its chat." }
    var tabsHeader: String { ru ? "ВКЛАДКИ ВНИЗУ" : "TABS AT THE BOTTOM" }
    var chats: String { ru ? "Чаты" : "Chats" }
    var contacts: String { ru ? "Контакты" : "Contacts" }
    var calls: String { ru ? "Звонки" : "Calls" }
    var settings: String { ru ? "Настройки" : "Settings" }
    var always: String { ru ? "всегда" : "always" }
    var orderHeader: String { ru ? "ПОРЯДОК" : "ORDER" }
    func superfolderFirst(_ name: String) -> String { ru ? "«\(name)» перед «Чатами»" : "\(name) Before Chats" }
    func orderFooter(_ name: String) -> String { ru ? "Если включить, вкладка «\(name)» будет слева от «Чатов»." : "When on, the \(name) tab is left of Chats." }
    var tabsFooter: String { ru ? "Выключенные вкладки пропадают снизу. Контакты остаются в поиске и в «Новом сообщении», звонки в профиле." : "Tabs that are off leave the bottom bar. Contacts stay in search and New Message, calls in the profile." }
}

private func icon(_ name: String, _ rgb: UInt32) -> UIImage? {
    return renderSettingsIcon(name: name, backgroundColors: [UIColor(rgb: rgb)])
}

private let topicsIcon = icon("Item List/Icons/Topics", 0x2AABEE)
private let tabsIcon = icon("Item List/Icons/Multiple", 0x5856D6)
private let superfolderIcon = icon("Item List/Icons/Folder", 0xFF9500)
private let computersIcon = icon("Item List/Icons/Devices", 0x8E8E93)
private let enginesIcon = icon("Item List/Icons/Chatbot", 0x8E8E93)
private let agentsIcon = icon("Item List/Icons/Bot", 0x8E8E93)
private let chatsIcon = icon("Item List/Icons/Chat", 0x2AABEE)
private let contactsIcon = icon("Item List/Icons/Profile", 0x8E8E93)
private let callsIcon = icon("Item List/Icons/Phone", 0x34C759)
private let settingsIcon = icon("Item List/Icons/Settings", 0x8E8E93)

// The app icon for the settings row, 30×30 like the other settings icons
public let agentgramSettingsIcon: UIImage? = {
    guard let image = UIImage(bundleImageName: "AgentgramIntroIcon") else {
        return nil
    }
    let size = CGSize(width: 30.0, height: 30.0)
    return UIGraphicsImageRenderer(size: size).image { _ in
        UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: 8.0).addClip()
        image.draw(in: CGRect(origin: CGPoint(), size: size))
    }
}()

// MARK: - Agentgram

private final class MainArguments {
    let openTopicsView: () -> Void
    let openTabs: () -> Void
    let openSuperfolder: () -> Void

    init(openTopicsView: @escaping () -> Void, openTabs: @escaping () -> Void, openSuperfolder: @escaping () -> Void) {
        self.openTopicsView = openTopicsView
        self.openTabs = openTabs
        self.openSuperfolder = openSuperfolder
    }
}

private enum MainEntry: ItemListNodeEntry {
    case viewHeader(String)
    case topicsView(String, String)
    case tabs(String)
    case superfolder(String, String)
    case agentsHeader(String)
    case computers(String, String)
    case engines(String, String)
    case agents(String, String)
    case agentsFooter(String)

    var section: ItemListSectionId {
        switch self {
        case .viewHeader, .topicsView, .tabs, .superfolder:
            return 0
        case .agentsHeader, .computers, .engines, .agents, .agentsFooter:
            return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .viewHeader: return 0
        case .topicsView: return 1
        case .tabs: return 2
        case .superfolder: return 3
        case .agentsHeader: return 4
        case .computers: return 5
        case .engines: return 6
        case .agents: return 7
        case .agentsFooter: return 8
        }
    }

    static func <(lhs: MainEntry, rhs: MainEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! MainArguments
        switch self {
        case let .viewHeader(text), let .agentsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .topicsView(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: topicsIcon, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.openTopicsView()
            })
        case let .tabs(title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: tabsIcon, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openTabs()
            })
        case let .superfolder(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: superfolderIcon, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.openSuperfolder()
            })
        case let .computers(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computersIcon, title: title, enabled: false, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .engines(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: enginesIcon, title: title, enabled: false, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .agents(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: agentsIcon, title: title, enabled: false, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .agentsFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

public func agentgramSettingsController(context: AccountContext) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    let arguments = MainArguments(openTopicsView: {
        pushImpl?(agentgramTopicsViewController(context: context))
    }, openTabs: {
        pushImpl?(agentgramTabsController(context: context))
    }, openSuperfolder: {
        pushImpl?(superfolderController(context: context))
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ThreadedBotSessions.settings(engine: context.engine), Superfolders.settings(engine: context.engine))
    |> map { presentationData, settings, superfolder -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = AgentgramTexts(presentationData.strings)
        var entries: [MainEntry] = []
        entries.append(.viewHeader(texts.viewHeader))
        entries.append(.topicsView(texts.topicsView, settings.threadedModeOff == true ? texts.stockTopics : texts.sessionsUnderBot))
        entries.append(.tabs(texts.tabs))
        entries.append(.superfolder(texts.superfolder, superfolder.isCreated ? superfolder.title : texts.create))
        entries.append(.agentsHeader(texts.agentsHeader))
        entries.append(.computers(texts.computers, texts.soon))
        entries.append(.engines(texts.engines, texts.soon))
        entries.append(.agents(texts.agents, texts.soon))
        entries.append(.agentsFooter(texts.agentsFooter))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(texts.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] next in
        controller?.push(next)
    }
    return controller
}

// MARK: - Topics view

private final class TopicsViewArguments {
    let select: (Bool) -> Void

    init(select: @escaping (Bool) -> Void) {
        self.select = select
    }
}

private enum TopicsViewEntry: ItemListNodeEntry {
    case header(String)
    case sessions(String, Bool)
    case stock(String, Bool)
    case footer(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case .sessions: return 1
        case .stock: return 2
        case .footer: return 3
        }
    }

    static func <(lhs: TopicsViewEntry, rhs: TopicsViewEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! TopicsViewArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .sessions(title, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(true)
            })
        case let .stock(title, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(false)
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func agentgramTopicsViewController(context: AccountContext) -> ViewController {
    let arguments = TopicsViewArguments(select: { enabled in
        ThreadedBotSessions.setEnabled(engine: context.engine, enabled)
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ThreadedBotSessions.settings(engine: context.engine))
    |> map { presentationData, settings -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = AgentgramTexts(presentationData.strings)
        let on = settings.threadedModeOff != true
        let entries: [TopicsViewEntry] = [
            .header(texts.topicsHeader),
            .sessions(texts.sessionsUnderBot, on),
            .stock(texts.stockTopics, !on),
            .footer(texts.topicsFooter)
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(texts.topicsView), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}

// MARK: - Tabs

private final class TabsArguments {
    let setContacts: (Bool) -> Void
    let setCalls: (Bool) -> Void
    let setSuperfolder: (Bool) -> Void
    let setSuperfolderFirst: (Bool) -> Void

    init(setContacts: @escaping (Bool) -> Void, setCalls: @escaping (Bool) -> Void, setSuperfolder: @escaping (Bool) -> Void, setSuperfolderFirst: @escaping (Bool) -> Void) {
        self.setContacts = setContacts
        self.setCalls = setCalls
        self.setSuperfolder = setSuperfolder
        self.setSuperfolderFirst = setSuperfolderFirst
    }
}

private enum TabsEntry: ItemListNodeEntry {
    case header(String)
    case chats(String, String)
    case superfolder(String, Bool, Bool)
    case contacts(String, Bool)
    case calls(String, Bool)
    case orderHeader(String)
    case superfolderFirst(String, Bool)
    case orderFooter(String)
    case settings(String, String)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .orderHeader, .superfolderFirst, .orderFooter:
            return 1
        default:
            return 0
        }
    }

    var stableId: Int32 {
        switch self {
        case .orderHeader: return 10
        case .superfolderFirst: return 11
        case .orderFooter: return 12
        case .header: return 0
        case .chats: return 1
        case .superfolder: return 2
        case .contacts: return 3
        case .calls: return 4
        case .settings: return 5
        case .footer: return 6
        }
    }

    static func <(lhs: TabsEntry, rhs: TabsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! TabsArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .chats(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: chatsIcon, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .superfolder(title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, icon: superfolderIcon, title: title, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setSuperfolder(value)
            })
        case let .contacts(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, icon: contactsIcon, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setContacts(value)
            })
        case let .calls(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, icon: callsIcon, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setCalls(value)
            })
        case let .orderHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .superfolderFirst(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setSuperfolderFirst(value)
            })
        case let .orderFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .settings(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: settingsIcon, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func agentgramTabsController(context: AccountContext) -> ViewController {
    let changed = ValuePromise<Int>(0, ignoreRepeated: false)
    let arguments = TabsArguments(setContacts: { value in
        AgentgramTabs.showsContacts = value
        changed.set(0)
    }, setCalls: { value in
        AgentgramTabs.showsCalls = value
        changed.set(0)
    }, setSuperfolder: { value in
        AgentgramTabs.showsSuperfolder = value
        changed.set(0)
    }, setSuperfolderFirst: { value in
        AgentgramTabs.superfolderFirst = value
        changed.set(0)
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, changed.get(), Superfolders.settings(engine: context.engine))
    |> map { presentationData, _, superfolder -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = AgentgramTexts(presentationData.strings)
        var entries: [TabsEntry] = [
            .header(texts.tabsHeader),
            .chats(texts.chats, texts.always),
            .superfolder(superfolder.isCreated ? superfolder.title : texts.superfolder, superfolder.isCreated && AgentgramTabs.showsSuperfolder, superfolder.isCreated),
            .contacts(texts.contacts, AgentgramTabs.showsContacts),
            .calls(texts.calls, AgentgramTabs.showsCalls),
            .settings(texts.settings, texts.always),
            .footer(texts.tabsFooter)
        ]
        if superfolder.isCreated {
            let name = superfolder.title.isEmpty ? texts.superfolder : superfolder.title
            entries.append(.orderHeader(texts.orderHeader))
            entries.append(.superfolderFirst(texts.superfolderFirst(name), AgentgramTabs.superfolderFirst))
            entries.append(.orderFooter(texts.orderFooter(name)))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(texts.tabs), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}
