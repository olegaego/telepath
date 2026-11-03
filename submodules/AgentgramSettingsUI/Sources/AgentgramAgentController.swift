import Foundation
import UIKit
import Network
import CryptoKit
import Security
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AppBundle

// One agent's screen: its counters, computer, engine, model, folder, access, «Отключить»

private final class ComputerArguments {
    let context: AccountContext
    let openChat: () -> Void
    let openEngine: () -> Void
    let disconnect: () -> Void
    var openModel: () -> Void = {}
    var openAccess: () -> Void = {}
    var openBotFather: () -> Void = {}

    init(context: AccountContext, openChat: @escaping () -> Void, openEngine: @escaping () -> Void, disconnect: @escaping () -> Void) {
        self.context = context
        self.openChat = openChat
        self.openEngine = openEngine
        self.disconnect = disconnect
    }
}

private let computerEngineIcon = renderSettingsIcon(name: "Item List/Icons/Chatbot", backgroundColors: [UIColor(rgb: 0xFF9500)])
let computerStatusesIcon = generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
    context.clear(CGRect(origin: CGPoint(), size: size))
    context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: 8.0).cgPath)
    context.setFillColor(UIColor(rgb: 0xF5B70A).cgColor)
    context.fillPath()
    context.setFillColor(UIColor.white.cgColor)
    context.fillEllipse(in: CGRect(x: 10.0, y: 10.0, width: 10.0, height: 10.0))
})
let computerVoiceIcon = renderSettingsIcon(name: "Item List/Icons/Microphone", backgroundColors: [UIColor(rgb: 0xFF2D55)])
private let computerProjectsIcon = renderSettingsIcon(name: "Item List/Icons/Folder", backgroundColors: [UIColor(rgb: 0x007AFF)])

private let computerModelIcon = agentgramSymbolTile("cpu", 0xAF52DE)
private let noTopicsIcon = agentgramSymbolTile("text.bubble.fill", 0xFF9500)
private let computerAccessIcon = agentgramSymbolTile("person.fill", 0x34C759)

private enum ComputerEntry: ItemListNodeEntry {
    case status(String, String, Bool, EnginePeer?)
    case counters([AgentgramCounter])
    case noTopics(String, String)
    case computer(String, String)
    case engine(String, String)
    case model(String, String)
    case projects(String, String)
    case access(String, String)
    case disconnect(String)

    var section: ItemListSectionId {
        switch self {
        case .status: return 0
        case .counters: return 1
        case .noTopics: return 7
        case .computer, .engine, .model, .projects: return 2
        case .access: return 3
        case .disconnect: return 5
        }
    }

    var stableId: Int32 {
        switch self {
        case .status: return 0
        case .counters: return 1
        case .noTopics: return 2
        case .computer: return 3
        case .engine: return 4
        case .model: return 5
        case .projects: return 6
        case .access: return 13
        case .disconnect: return 43
        }
    }

    static func <(lhs: ComputerEntry, rhs: ComputerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ComputerArguments
        switch self {
        case let .status(name, text, nearby, peer):
            // not nearby is orange, not red: the agent still answers through Telegram, the computer is just on
            // another network
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: UIColor(rgb: 0x5856D6), iconSize: 100.0, title: name, status: text, statusColor: nearby ? UIColor(rgb: 0x34C759) : UIColor(rgb: 0xFF9500), context: arguments.context, peer: peer, sectionId: self.section)
        case let .counters(counters):
            return AgentgramCountersItem(presentationData: presentationData, counters: counters, sectionId: self.section)
        case let .noTopics(title, text):
            let base = presentationData.fontSize.itemListBaseFontSize
            let attributed = NSMutableAttributedString(string: title + "\n", attributes: [.font: Font.semibold(base), .foregroundColor: presentationData.theme.list.itemPrimaryTextColor])
            attributed.append(NSAttributedString(string: text, attributes: [.font: Font.regular(base - 2.0), .foregroundColor: presentationData.theme.list.itemSecondaryTextColor]))
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: noTopicsIcon, title: "", attributedTitle: attributed, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openBotFather()
            })
        case let .access(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computerAccessIcon, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.openAccess()
            })
        case let .computer(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computersRowIcon, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .engine(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computerEngineIcon, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.openEngine()
            })
        case let .model(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computerModelIcon, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.openModel()
            })
        case let .projects(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computerProjectsIcon, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .disconnect(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.disconnect()
            })
        }
    }
}

func agentgramComputerController(context: AccountContext, computer: ConnectedComputer, browser: ComputersBrowser) -> ViewController {
    let infoPromise = Promise<[String: Any]?>(nil)
    var asked = false
    var presentImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?
    var openChatImpl: (() -> Void)?
    var openPeerImpl: ((EnginePeer) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    let infoValue = Atomic<[String: Any]?>(value: nil)
    let nearbyEndpoint: () -> NWEndpoint? = {
        var endpoint: NWEndpoint?
        let _ = (browser.computers.get() |> take(1)).start(next: { found in
            endpoint = found.first(where: { $0.publicKey == computer.publicKey })?.endpoint
        })
        return endpoint
    }

    // the bot's own avatar on its row, and the chat opens from the same peer
    let botPeer = Promise<EnginePeer?>(nil)
    botPeer.set(.single(nil) |> then(agentgramPeer(context, username: computer.bot)))

    let arguments = ComputerArguments(context: context, openChat: {
        openChatImpl?()
    }, openEngine: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let texts = ComputersTexts(presentationData.strings)
        guard let endpoint = nearbyEndpoint(), let info = infoValue.with({ $0 }) else {
            presentImpl?(agentgramAlert(context, texts.engineFar))
            return
        }
        pushImpl?(agentgramEngineController(context: context, computer: computer, endpoint: endpoint, info: info, changed: { engine in
            // asked again: the engine and its limits as the computer has them now
            askComputer(endpoint, computer, path: "/info", completion: { result in
                let _ = infoValue.swap(result)
                infoPromise.set(.single(result))
            })
            var updated = computer
            updated.engine = engine
            ConnectedComputers.add(context, updated)
        }))
    }, disconnect: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let texts = ComputersTexts(presentationData.strings)
        if let endpoint = nearbyEndpoint() {
            presentImpl?(textAlertController(context: context, title: texts.disconnect, text: texts.disconnectConfirm, actions: [
                TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: texts.disconnect, action: {
                    askComputer(endpoint, computer, path: "/unpair", completion: { _ in
                        ConnectedComputers.remove(context, publicKey: computer.publicKey, bot: computer.bot)
                        popImpl?()
                    })
                })
            ]))
        } else {
            presentImpl?(textAlertController(context: context, title: texts.disconnect, text: texts.disconnectFar, actions: [
                TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: texts.remove, action: {
                    ConnectedComputers.remove(context, publicKey: computer.publicKey, bot: computer.bot)
                    popImpl?()
                })
            ]))
        }
    })

    // the chat opens from a small button at the top right
    let chatButton = ASImageNode()
    chatButton.displaysAsynchronously = false
    chatButton.image = generateTintedImage(image: UIImage(bundleImageName: "Peer Info/ButtonMessage"), color: context.sharedContext.currentPresentationData.with { $0 }.theme.rootController.navigationBar.accentTextColor)
    chatButton.frame = CGRect(origin: CGPoint(), size: CGSize(width: 28.0, height: 28.0))
    chatButton.contentMode = .scaleAspectFit

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, browser.computers.get(), infoPromise.get(), botPeer.get(), AgentgramVoiceSettings.changed.get(), AgentgramStatusesMode.changed.get())
    |> map { presentationData, found, info, peer, _, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = ComputersTexts(presentationData.strings)
        let nearby = found.first(where: { $0.publicKey == computer.publicKey })
        if let nearby, !asked {
            asked = true
            askComputer(nearby.endpoint, computer, path: "/info", completion: { result in
                let _ = infoValue.swap(result)
                infoPromise.set(.single(result))
                // the engine may have been changed on the computer, in its menu
                if let engine = result?["engine"] as? String, engine != computer.engine {
                    var updated = computer
                    updated.engine = engine
                    ConnectedComputers.add(context, updated)
                }
            })
        }
        let engineID = (info?["engine"] as? String) ?? computer.engine
        let engine = agentgramEngineName(engineID)
        var entries: [ComputerEntry] = [.status("@" + computer.bot, nearby != nil ? texts.nearbyNow : texts.notNearby, nearby != nil, peer)]
        // one card of counters: the engine's limit windows and today's turns
        var counters: [AgentgramCounter] = []
        for w in engineLimits(info, engine: engineID).prefix(2) {
            let color: UInt32? = w.percent >= 100.0 ? 0xFF3B30 : (w.percent >= 80.0 ? 0xFF9500 : nil)
            let reset = limitUntilText(w.resetsAt, ru: texts.ru)
            counters.append(AgentgramCounter(value: "\(Int(w.percent.rounded()))%", caption: limitWindowTitle(w.name, ru: texts.ru).lowercased() + (reset.isEmpty ? "" : "\n" + reset), color: color))
        }
        if let turns = info?["today_turns"] as? Int {
            counters.append(AgentgramCounter(value: "\(turns)", caption: texts.turnsToday + "\n" + texts.sessionsCount((info?["topics"] as? Int) ?? 0), color: nil))
        }
        if !counters.isEmpty {
            entries.append(.counters(counters))
        }
        // a bot without topics: its whole chat is one session; where to turn them on
        if case let .user(user) = peer, let botInfo = user.botInfo, !botInfo.flags.contains(.hasForum) {
            entries.append(.noTopics(texts.noTopicsTitle, texts.noTopicsText))
        }
        let modelID = info?["model"] as? String ?? ""
        let modelName = ((info?["models"] as? [[String: Any]]) ?? []).first(where: { ($0["id"] as? String) == modelID })?["name"] as? String
        entries.append(.computer(texts.computerRow, computer.name))
        entries.append(.engine(texts.engineRow, engine))
        entries.append(.model(texts.modelRow, modelName ?? modelID))
        entries.append(.projects(texts.projectsRow, ((info?["projects"] as? String) ?? "—").replacingOccurrences(of: "^(/Users|/home)/[^/]+", with: "~", options: .regularExpression)))
        let allowed = (info?["allowed"] as? [[String: Any]])?.count ?? 0
        entries.append(.access(texts.accessRow, allowed == 0 ? texts.accessOnlyYou : texts.accessYouAnd(allowed)))
        entries.append(.disconnect(texts.disconnect))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(""), leftNavigationButton: nil, rightNavigationButton: ItemListNavigationButton(content: .node(chatButton), style: .regular, enabled: true, action: {
            arguments.openChat()
        }), backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    arguments.openBotFather = {
        let _ = (agentgramPeer(context, username: "BotFather")
        |> deliverOnMainQueue).start(next: { peer in
            if let peer {
                openPeerImpl?(peer)
            }
        })
    }
    arguments.openModel = {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        guard nearbyEndpoint() != nil, let info = infoValue.with({ $0 }) else {
            presentImpl?(agentgramAlert(context, ComputersTexts(presentationData.strings).engineFar))
            return
        }
        pushImpl?(agentgramModelController(context: context, computer: computer, info: info, changed: { model in
            var info = infoValue.with { $0 } ?? [:]
            info["model"] = model
            let _ = infoValue.swap(info)
            infoPromise.set(.single(info))
        }))
    }
    arguments.openAccess = {
        pushImpl?(agentgramAccessController(context: context, computer: computer, info: infoValue.with { $0 }, changed: { _, list in
            var info = infoValue.with { $0 } ?? [:]
            info["allowed"] = list
            let _ = infoValue.swap(info)
            infoPromise.set(.single(info))
        }))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    popImpl = { [weak controller] in
        let _ = controller?.navigationController?.popViewController(animated: true)
    }
    pushImpl = { [weak controller] next in
        controller?.push(next)
    }
    openPeerImpl = { [weak controller] peer in
        guard let navigationController = controller?.navigationController as? NavigationController else {
            return
        }
        context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
    }
    openChatImpl = { [weak controller] in
        let _ = (botPeer.get()
        |> filter { $0 != nil }
        |> take(1)
        |> deliverOnMainQueue).start(next: { peer in
            guard let peer, let navigationController = controller?.navigationController as? NavigationController else {
                return
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context, chatLocation: .peer(peer)))
        })
    }
    return controller
}

// Connecting a found computer: the owner pastes the bot's token here, picks the engine, and the token goes straight
// to the computer, sealed with its key
