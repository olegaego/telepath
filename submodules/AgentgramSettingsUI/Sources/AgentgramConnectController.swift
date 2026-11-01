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

// Connecting a computer found nearby (the bot's token and the engine) and switching an agent's engine

private final class ConnectArguments {
    let updateToken: (String) -> Void
    let selectEngine: (String) -> Void
    let connect: () -> Void

    init(updateToken: @escaping (String) -> Void, selectEngine: @escaping (String) -> Void, connect: @escaping () -> Void) {
        self.updateToken = updateToken
        self.selectEngine = selectEngine
        self.connect = connect
    }
}

private enum ConnectEntry: ItemListNodeEntry {
    case tokenHeader(String)
    case token(String, String)
    case tokenFooter(String)
    case engineHeader(String)
    case engine(Int32, String, String, Bool)
    case connect(String, Bool)

    var section: ItemListSectionId {
        switch self {
        case .tokenHeader, .token, .tokenFooter:
            return 0
        case .engineHeader, .engine:
            return 1
        case .connect:
            return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .tokenHeader: return 0
        case .token: return 1
        case .tokenFooter: return 2
        case .engineHeader: return 3
        case let .engine(index, _, _, _): return 10 + index
        case .connect: return 100
        }
    }

    static func <(lhs: ConnectEntry, rhs: ConnectEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ConnectArguments
        switch self {
        case let .tokenHeader(text), let .engineHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .token(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { value in
                arguments.updateToken(value)
            }, action: {})
        case let .tokenFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .engine(_, id, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectEngine(id)
            })
        case let .connect(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.connect()
            })
        }
    }
}

private struct ConnectState: Equatable {
    var token: String = ""
    var engine: String = "claude"
    var busy: Bool = false
}

func agentgramConnectComputerController(context: AccountContext, computer: NearbyComputer) -> ViewController {
    let statePromise = ValuePromise(ConnectState(), ignoreRepeated: true)
    let stateValue = Atomic(value: ConnectState())
    let updateState: ((inout ConnectState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }
    var presentImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?

    let arguments = ConnectArguments(updateToken: { value in
        updateState { $0.token = value }
    }, selectEngine: { engine in
        updateState { $0.engine = engine }
    }, connect: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let texts = ComputersTexts(presentationData.strings)
        let state = stateValue.with { $0 }
        let alert: (String, String) -> Void = { title, text in
            presentImpl?(textAlertController(context: context, title: title, text: text, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]))
        }
        guard let range = state.token.range(of: "[0-9]{6,12}:[A-Za-z0-9_-]{30,}", options: .regularExpression) else {
            alert(texts.failed, texts.badToken)
            return
        }
        let token = String(state.token[range])
        var secretBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, secretBytes.count, &secretBytes)
        let secret = base64UrlEncode(Data(secretBytes))
        let payload: [String: Any] = ["bot_token": token, "owner_id": context.account.peerId.id._internalGetInt64Value(), "engine": state.engine, "secret": secret]
        guard let plain = try? JSONSerialization.data(withJSONObject: payload), let sealed = sealForComputer(plain, publicKey: computer.publicKey) else {
            return
        }
        updateState { $0.busy = true }
        postToComputer(computer.endpoint, path: "/pair", body: base64UrlEncode(sealed), completion: { status, body in
            updateState { $0.busy = false; $0.token = "" }
            if status == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let botName = json["bot"] as? String {
                ConnectedComputers.add(context, ConnectedComputer(name: computer.name, publicKey: computer.publicKey, bot: botName, engine: state.engine, secret: secret))
                presentImpl?(textAlertController(context: context, title: texts.done, text: texts.doneText(botName, computer.name), actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {
                    dismissImpl?()
                })]))
            } else {
                alert(texts.failed, String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        })
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = ComputersTexts(presentationData.strings)
        let entries: [ConnectEntry] = [
            .tokenHeader(texts.tokenHeader),
            .token(state.token, texts.tokenPlaceholder),
            .tokenFooter(texts.tokenFooter),
            .engineHeader(texts.engineHeader),
            .engine(0, "claude", "Claude Code", state.engine == "claude"),
            .engine(1, "codex", "Codex", state.engine == "codex"),
            .connect(state.busy ? texts.connecting : texts.connectButton, !state.busy && !state.token.isEmpty)
        ]
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(computer.name), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    dismissImpl = { [weak controller] in
        let _ = controller?.navigationController?.popViewController(animated: true)
    }
    return controller
}

// «Runs On»: both engines with their limits; a tap switches the computer
private final class EngineArguments {
    let select: (String) -> Void

    init(select: @escaping (String) -> Void) {
        self.select = select
    }
}

private let engineTile = agentgramSymbolTile("cpu", 0xFF9500, size: agentgramHeroTileSize)

private enum EngineEntry: ItemListNodeEntry {
    case header(String, String)
    case engine(Int32, String, String, String, Bool, Bool)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        default: return 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return -1
        case let .engine(index, _, _, _, _, _): return index
        case .footer: return 100
        }
    }

    static func <(lhs: EngineEntry, rhs: EngineEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! EngineArguments
        switch self {
        case let .header(title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: engineTile, sectionId: self.section)
        case let .engine(_, id, title, detail, selected, enabled):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: agentgramEngineIcon(id), title: title, subtitle: detail, style: .right, checked: selected, enabled: enabled, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(id)
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

func agentgramEngineController(context: AccountContext, computer: ConnectedComputer, endpoint: NWEndpoint, info: [String: Any], changed: @escaping (String) -> Void) -> ViewController {
    let current = ValuePromise<String>((info["engine"] as? String) ?? "claude", ignoreRepeated: true)
    let installed = info["installed"] as? [String: Bool] ?? [:]
    var presentImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?
    let arguments = EngineArguments(select: { engine in
        askComputer(endpoint, computer, path: "/engine", extra: ["engine": engine], completion: { result in
            if result?["ok"] as? Bool == true {
                current.set(engine)
                changed(engine)
                popImpl?()
            } else {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                presentImpl?(agentgramAlert(context, ComputersTexts(presentationData.strings).engineFailed))
            }
        })
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, current.get())
    |> map { presentationData, engine -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = ComputersTexts(presentationData.strings)
        let engines = agentgramEngines.filter { $0.id != "chat" || (installed["chat"] ?? false) }.map { ($0.id, $0.name) }
        var entries: [EngineEntry] = [.header(engines.first(where: { $0.0 == engine })?.1 ?? "Claude Code", texts.engineRunsOn(computer.name))]
        for (i, (id, title)) in engines.enumerated() {
            let isInstalled = installed[id] ?? true
            var detail = isInstalled ? limitsSummary(engineLimits(info, engine: id), ru: texts.ru) : texts.notInstalled
            if id == "codex", isInstalled, let plan = ((info["limits"] as? [String: Any])?["codex"] as? [String: Any])?["plan"] as? String, plan == "free" {
                detail += texts.ru ? " · бесплатный тариф" : " · free plan"
            }
            entries.append(.engine(Int32(i), id, title, detail, engine == id, isInstalled))
        }
        entries.append(.footer(texts.engineFooter))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(texts.engineTitle), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    popImpl = { [weak controller] in
        let _ = controller?.navigationController?.popViewController(animated: true)
    }
    return controller
}
