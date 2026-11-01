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
    var addComputer: String { ru ? "Подключить компьютер" : "Connect a Computer" }
    var nearbyNow: String { ru ? "рядом" : "nearby" }
    var notConnected: String { ru ? "рядом, ещё не подключён" : "nearby, not connected" }
    var connectedElsewhere: String { ru ? "рядом, уже подключён" : "nearby, connected" }
    var connect: String { ru ? "Подключить" : "Connect" }
    var create: String { ru ? "создать" : "create" }
    var agentsFooter: String { ru ? "Агент это твой бот, который работает на твоём компьютере. Пишешь боту, отвечает Claude Code или Codex." : "An agent is your bot working on your computer. You write to the bot, Claude Code or Codex answers." }
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
private let nearbyComputerIcon = icon("Item List/Icons/Devices", 0x8E8E93)
private let addComputerIcon = icon("Item List/Icons/Add", 0x2AABEE)
private let nearbyDot = generateFilledCircleImage(diameter: 10.0, color: UIColor(rgb: 0x34C759))
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
    let openComputers: () -> Void
    let openAgent: (ConnectedComputer) -> Void
    let connectNearby: (NearbyComputer) -> Void
    let context: AccountContext

    init(context: AccountContext, openTopicsView: @escaping () -> Void, openTabs: @escaping () -> Void, openSuperfolder: @escaping () -> Void, openComputers: @escaping () -> Void, openAgent: @escaping (ConnectedComputer) -> Void, connectNearby: @escaping (NearbyComputer) -> Void) {
        self.context = context
        self.openTopicsView = openTopicsView
        self.openTabs = openTabs
        self.openSuperfolder = openSuperfolder
        self.openComputers = openComputers
        self.openAgent = openAgent
        self.connectNearby = connectNearby
    }
}

private enum MainEntry: ItemListNodeEntry {
    case viewHeader(String)
    case topicsView(String, String)
    case tabs(String)
    case superfolder(String, String)
    case agentsHeader(String)
    case agent(Int32, ConnectedComputer, EnginePeer?, String, String)
    case nearby(Int32, NearbyComputer, String, String)
    case addComputer(String)
    case agentsFooter(String)

    var section: ItemListSectionId {
        switch self {
        case .viewHeader, .topicsView, .tabs, .superfolder:
            return 0
        case .agentsHeader, .agent, .nearby, .addComputer, .agentsFooter:
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
        case let .agent(index, _, _, _, _): return 100 + index
        case let .nearby(index, _, _, _): return 500 + index
        case .addComputer: return 900
        case .agentsFooter: return 901
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
        case let .agent(_, computer, peer, detail, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: peer == nil ? nearbyComputerIcon : nil, context: arguments.context, iconPeer: peer, title: "@" + computer.bot, label: "", labelStyle: label.isEmpty ? .text : .image(image: nearbyDot ?? UIImage(), size: CGSize(width: 10.0, height: 10.0)), additionalDetailLabel: detail, sectionId: self.section, style: .blocks, action: {
                arguments.openAgent(computer)
            })
        case let .nearby(_, computer, detail, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: nearbyComputerIcon, title: computer.name, label: label, labelStyle: .coloredText(presentationData.theme.list.itemAccentColor), additionalDetailLabel: detail, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.connectNearby(computer)
            })
        case let .addComputer(title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: addComputerIcon, title: title, titleColor: .accent, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openComputers()
            })
        case let .agentsFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

public func agentgramSettingsController(context: AccountContext) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    // agents are listed right here; computers nearby are looked for while the screen is open
    let browser = ComputersBrowser()
    browser.start()
    let agentPeers: Signal<[String: EnginePeer], NoError> = ConnectedComputers.changed.get()
    |> mapToSignal { _ -> Signal<[String: EnginePeer], NoError> in
        let bots = ConnectedComputers.all(context).map { $0.bot }
        if bots.isEmpty {
            return .single([:])
        }
        return combineLatest(bots.map { bot in
            context.engine.peers.resolvePeerByName(name: bot, referrer: nil)
            |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
                if case let .result(peer) = result {
                    return .single(peer)
                }
                return .complete()
            }
            |> take(1)
            |> map { peer -> (String, EnginePeer?) in (bot, peer) }
        })
        |> map { pairs -> [String: EnginePeer] in
            var result: [String: EnginePeer] = [:]
            for (bot, peer) in pairs {
                result[bot] = peer
            }
            return result
        }
    }
    let arguments = MainArguments(context: context, openTopicsView: {
        pushImpl?(agentgramTopicsViewController(context: context))
    }, openTabs: {
        pushImpl?(agentgramTabsController(context: context))
    }, openSuperfolder: {
        pushImpl?(superfolderController(context: context))
    }, openComputers: {
        pushImpl?(agentgramComputersController(context: context))
    }, openAgent: { computer in
        pushImpl?(agentgramComputerController(context: context, computer: computer, browser: browser))
    }, connectNearby: { computer in
        agentgramConnectNearby(context: context, computer: computer, present: { presentImpl?($0) }, push: { pushImpl?($0) })
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ThreadedBotSessions.settings(engine: context.engine), Superfolders.settings(engine: context.engine), browser.computers.get(), ConnectedComputers.changed.get(), .single([:]) |> then(agentPeers))
    |> map { presentationData, settings, superfolder, found, _, peers -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = AgentgramTexts(presentationData.strings)
        var entries: [MainEntry] = []
        entries.append(.viewHeader(texts.viewHeader))
        entries.append(.topicsView(texts.topicsView, settings.threadedModeOff == true ? texts.stockTopics : texts.sessionsUnderBot))
        entries.append(.tabs(texts.tabs))
        entries.append(.superfolder(texts.superfolder, superfolder.isCreated ? superfolder.title : texts.create))
        entries.append(.agentsHeader(texts.agentsHeader))
        let connected = ConnectedComputers.all(context)
        for (i, computer) in connected.enumerated() {
            let engine = computer.engine == "codex" ? "Codex" : "Claude Code"
            let near = found.contains(where: { $0.publicKey == computer.publicKey })
            entries.append(.agent(Int32(i), computer, peers[computer.bot], "\(computer.name) · \(engine)", near ? texts.nearbyNow : ""))
        }
        let connectedKeys = Set(connected.map { $0.publicKey })
        for (i, computer) in found.filter({ !connectedKeys.contains($0.publicKey) }).enumerated() {
            entries.append(.nearby(Int32(i), computer, computer.paired ? texts.connectedElsewhere : texts.notConnected, computer.paired ? "" : texts.connect))
        }
        entries.append(.addComputer(texts.addComputer))
        entries.append(.agentsFooter(texts.agentsFooter))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(texts.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal |> afterDisposed {
        browser.stop()
    })
    pushImpl = { [weak controller] next in
        controller?.push(next)
    }
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
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
