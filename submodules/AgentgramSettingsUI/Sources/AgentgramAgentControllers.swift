import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// «Модель» and «Доступ» on an agent's screen. Both are changed on the computer, over the local network: the model of
// the engine (the list comes from the computer, so new models show up without an update), and the people besides the
// owner whom the agent obeys.

private struct AgentTexts {
    let ru: Bool

    init(_ strings: PresentationStrings) {
        self.ru = strings.primaryComponent.languageCode.hasPrefix("ru")
    }

    var modelTitle: String { ru ? "Модель" : "Model" }
    func modelLine(_ engine: String, _ computer: String) -> String { ru ? "\(engine) на \(computer)" : "\(engine) on \(computer)" }
    var modelFooter: String { ru ? "Новая модель начинает работать со следующего сообщения." : "The new model works from the next message." }
    var accessTitle: String { ru ? "Доступ" : "Access" }
    var accessLine: String { ru ? "Агентом пользуются только эти люди. Остальным бот не отвечает." : "Only these people can use the agent. The bot ignores everyone else." }
    var whoHeader: String { ru ? "КТО МОЖЕТ" : "WHO CAN" }
    var owner: String { ru ? "владелец" : "owner" }
    var you: String { ru ? "Ты" : "You" }
    var added: String { ru ? "добавлен" : "added" }
    var addPerson: String { ru ? "Добавить человека" : "Add Person" }
    var remove: String { ru ? "Убрать" : "Remove" }
    var accessFooter: String { ru ? "Кто в этом списке, может через агента делать на твоём компьютере всё то же, что и ты: читать и менять файлы, запускать программы." : "Anyone on this list can do through the agent everything you can on your computer: read and change files, run programs." }
    func grantTitle(_ name: String) -> String { ru ? "Дать доступ: \(name)?" : "Give access to \(name)?" }
    var grantText: String { ru ? "Этот человек сможет управлять агентом, а через него и всем твоим компьютером: файлы, пароли в них, программы. Давай доступ только тем, кому доверяешь как себе." : "They will control the agent, and through it your whole computer: files, the passwords in them, programs. Give access only to people you trust as yourself." }
    var grant: String { ru ? "Дать доступ" : "Give Access" }
    var cancel: String { ru ? "Отмена" : "Cancel" }
    var away: String { ru ? "Компьютер сейчас не в этой сети. Это меняется, когда телефон в той же Wi-Fi." : "The computer is not on this network now. This is changed when the phone is on the same Wi-Fi." }
}

// MARK: Model

private let modelTile = agentgramSymbolTile("cpu", 0xAF52DE, size: agentgramHeroTileSize)
private let modelIcons = [agentgramSymbolTile("sparkles", 0xAF52DE), agentgramSymbolTile("hare.fill", 0x2AABEE), agentgramSymbolTile("bolt.fill", 0x34C759), agentgramSymbolTile("circle.hexagongrid.fill", 0xFF9500)]

private final class ModelArguments {
    let select: (String) -> Void

    init(select: @escaping (String) -> Void) {
        self.select = select
    }
}

private enum ModelEntry: ItemListNodeEntry {
    case header(String, String)
    case model(Int32, String, String, String, Bool)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        default: return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case let .model(index, _, _, _, _): return 10 + index
        case .footer: return 1000
        }
    }

    static func <(lhs: ModelEntry, rhs: ModelEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ModelArguments
        switch self {
        case let .header(title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: modelTile, sectionId: self.section)
        case let .model(index, id, title, detail, selected):
            let icon = modelIcons[Int(index - 1) % modelIcons.count]
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, subtitle: detail.isEmpty ? nil : detail, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(id)
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

func agentgramModelController(context: AccountContext, computer: ConnectedComputer, info: [String: Any]?, changed: @escaping (String) -> Void) -> ViewController {
    let current = ValuePromise<String>(info?["model"] as? String ?? "", ignoreRepeated: true)
    let engineID = (info?["engine"] as? String) ?? "claude"
    let models = (info?["models"] as? [[String: Any]]) ?? []
    var presentImpl: ((ViewController) -> Void)?
    let arguments = ModelArguments(select: { model in
        let texts = AgentTexts(context.sharedContext.currentPresentationData.with { $0 }.strings)
        guard let endpoint = agentgramNearbyEndpoint(computer.publicKey) else {
            presentImpl?(agentgramAlert(context, texts.away))
            return
        }
        askComputer(endpoint, computer, path: "/model", extra: ["engine": engineID, "model": model], completion: { result in
            Queue.mainQueue().async {
                if result?["ok"] as? Bool == true {
                    current.set(model)
                    changed(model)
                } else {
                    presentImpl?(agentgramAlert(context, texts.away))
                }
            }
        })
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, current.get())
    |> map { presentationData, model -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = AgentTexts(presentationData.strings)
        var entries: [ModelEntry] = [.header(texts.modelTitle, texts.modelLine(agentgramEngineName(engineID), computer.name))]
        for (i, m) in models.enumerated() {
            let id = m["id"] as? String ?? ""
            // the details come from the computer in Russian for Claude Code and in English from Codex
            entries.append(.model(Int32(i + 1), id, m["name"] as? String ?? id, texts.ru || engineID == "codex" ? (m["detail"] as? String ?? "") : "", model == id))
        }
        entries.append(.footer(texts.modelFooter))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(""), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    return controller
}

// MARK: Access

private let accessTile = agentgramSymbolTile("lock.fill", 0x34C759, size: agentgramHeroTileSize)
private let addPersonIcon = agentgramSymbolTile("plus", 0x2AABEE)

struct AgentgramAllowedPerson: Equatable {
    let id: Int64
    let name: String
    let added: Int64
}

func agentgramAllowed(_ info: [String: Any]?) -> [AgentgramAllowedPerson] {
    return ((info?["allowed"] as? [[String: Any]]) ?? []).compactMap { p in
        guard let id = (p["id"] as? NSNumber)?.int64Value else {
            return nil
        }
        return AgentgramAllowedPerson(id: id, name: p["name"] as? String ?? "", added: (p["added"] as? NSNumber)?.int64Value ?? 0)
    }
}

private final class AccessArguments {
    let context: AccountContext
    let add: () -> Void
    let remove: (Int64) -> Void

    init(context: AccountContext, add: @escaping () -> Void, remove: @escaping (Int64) -> Void) {
        self.context = context
        self.add = add
        self.remove = remove
    }
}

private enum AccessEntry: ItemListNodeEntry {
    case header(String, String)
    case whoHeader(String)
    case owner(String, String, EnginePeer?)
    case person(Int32, Int64, String, String, String, EnginePeer?)
    case add(String)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        default: return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case .whoHeader: return 1
        case .owner: return 2
        case let .person(index, _, _, _, _, _): return 10 + index
        case .add: return 900
        case .footer: return 1000
        }
    }

    static func <(lhs: AccessEntry, rhs: AccessEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AccessArguments
        switch self {
        case let .header(title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: accessTile, sectionId: self.section)
        case let .whoHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .owner(title, detail, peer):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, context: arguments.context, iconPeer: peer, title: title, label: "", additionalDetailLabel: detail, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .person(_, id, title, detail, remove, peer):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, context: arguments.context, iconPeer: peer, title: title, label: remove, labelStyle: .coloredText(UIColor(rgb: 0xFF3B30)), additionalDetailLabel: detail, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.remove(id)
            })
        case let .add(title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: addPersonIcon, title: title, titleColor: .accent, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.add()
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

func agentgramAccessController(context: AccountContext, computer: ConnectedComputer, info: [String: Any]?, changed: @escaping ([AgentgramAllowedPerson], [[String: Any]]) -> Void) -> ViewController {
    let people = ValuePromise<[AgentgramAllowedPerson]>(agentgramAllowed(info), ignoreRepeated: true)
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    let send: ([String: Any]) -> Void = { fields in
        let texts = AgentTexts(context.sharedContext.currentPresentationData.with { $0 }.strings)
        guard let endpoint = agentgramNearbyEndpoint(computer.publicKey) else {
            presentImpl?(agentgramAlert(context, texts.away))
            return
        }
        askComputer(endpoint, computer, path: "/access", extra: fields, completion: { result in
            Queue.mainQueue().async {
                if result?["ok"] as? Bool == true, let list = result?["allowed"] as? [[String: Any]] {
                    let updated = agentgramAllowed(["allowed": list])
                    people.set(updated)
                    changed(updated, list)
                } else {
                    presentImpl?(agentgramAlert(context, texts.away))
                }
            }
        })
    }
    let arguments = AccessArguments(context: context, add: {
        let texts = AgentTexts(context.sharedContext.currentPresentationData.with { $0 }.strings)
        // the warning comes before anyone is let in
        let picker = context.sharedContext.makeContactSelectionController(ContactSelectionControllerParams(context: context, title: { _ in texts.addPerson }, confirmation: { peer in
            guard case let .peer(enginePeer, _, _) = peer else {
                return .single(false)
            }
            return Signal { subscriber in
                presentImpl?(textAlertController(context: context, title: texts.grantTitle(enginePeer.compactDisplayTitle), text: texts.grantText, actions: [
                    TextAlertAction(type: .genericAction, title: texts.cancel, action: {
                        subscriber.putNext(false)
                        subscriber.putCompletion()
                    }),
                    TextAlertAction(type: .destructiveAction, title: texts.grant, action: {
                        subscriber.putNext(true)
                        subscriber.putCompletion()
                    })
                ]))
                return EmptyDisposable
            }
        }, isPeerEnabled: { peer in
            if case let .peer(enginePeer, _, _) = peer, case let .user(user) = enginePeer {
                return user.botInfo == nil && enginePeer.id != context.account.peerId
            }
            return false
        }))
        picker.navigationPresentation = .modal
        pushImpl?(picker)
        let _ = (picker.result
        |> take(1)
        |> deliverOnMainQueue).start(next: { result in
            guard let (peers, _, _, _, _, _) = result, let first = peers.first, case let .peer(peer, _, _) = first else {
                return
            }
            send(["add": ["id": peer.id.id._internalGetInt64Value(), "name": peer.compactDisplayTitle]])
        })
    }, remove: { id in
        send(["remove": id])
    })

    let ownerPeer = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
    let peersSignal = people.get()
    |> mapToSignal { list -> Signal<[Int64: EnginePeer], NoError> in
        let ids = list.map { EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value($0.id)) }
        return context.engine.data.subscribe(EngineDataMap(ids.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
        |> map { found -> [Int64: EnginePeer] in
            var out: [Int64: EnginePeer] = [:]
            for (id, peer) in found {
                if let peer {
                    out[id.id._internalGetInt64Value()] = peer
                }
            }
            return out
        }
    }
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, people.get(), ownerPeer, peersSignal)
    |> map { presentationData, list, owner, peers -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = AgentTexts(presentationData.strings)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: texts.ru ? "ru_RU" : "en_US")
        formatter.dateFormat = texts.ru ? "d MMMM" : "MMMM d"
        var entries: [AccessEntry] = [.header(texts.accessTitle, texts.accessLine), .whoHeader(texts.whoHeader)]
        entries.append(.owner(owner?.compactDisplayTitle ?? texts.you, texts.owner, owner))
        for (i, p) in list.enumerated() {
            let peer = peers[p.id]
            let detail = p.added > 0 ? texts.added + " " + formatter.string(from: Date(timeIntervalSince1970: TimeInterval(p.added))) : ""
            entries.append(.person(Int32(i), p.id, peer?.compactDisplayTitle ?? p.name, detail, texts.remove, peer))
        }
        entries.append(.add(texts.addPerson))
        entries.append(.footer(texts.accessFooter))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(""), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    pushImpl = { [weak controller] next in
        (controller?.navigationController as? NavigationController)?.pushViewController(next)
    }
    return controller
}
