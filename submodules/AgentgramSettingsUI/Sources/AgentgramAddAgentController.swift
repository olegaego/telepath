import Foundation
import UIKit
import Network
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// «Добавить агента»: where it will work. On a computer already connected the agent is added at once (the computer
// knows this phone, no code to check); a new computer is a Mac or Windows with the helper on it, Linux later.
// A computer may run several agents, each its own bot and engine.

private struct AddAgentTexts {
    let ru: Bool

    init(_ strings: PresentationStrings) {
        self.ru = strings.primaryComponent.languageCode.hasPrefix("ru")
    }

    var whereTitle: String { ru ? "Где он будет работать?" : "Where Will It Work?" }
    var whereText: String { ru ? "На одном компьютере может работать несколько агентов." : "One computer can run several agents." }
    var connectedHeader: String { ru ? "ПОДКЛЮЧЁННЫЕ" : "CONNECTED" }
    var newHeader: String { ru ? "НОВЫЙ КОМПЬЮТЕР" : "NEW COMPUTER" }
    func agentsCount(_ n: Int) -> String {
        if !ru {
            return n == 1 ? "1 agent" : "\(n) agents"
        }
        let tail = n % 10 == 1 && n % 100 != 11 ? "агент" : ((2 ... 4).contains(n % 10) && !(12 ... 14).contains(n % 100) ? "агента" : "агентов")
        return "\(n) \(tail)"
    }
    var nearby: String { ru ? "рядом" : "nearby" }
    var away: String { ru ? "не в этой сети" : "not on this network" }
    var soon: String { ru ? "скоро" : "soon" }
    var awayAlert: String { ru ? "Компьютер сейчас не в этой сети. Агент добавляется, когда телефон в той же Wi-Fi." : "The computer is not on this network now. An agent is added when the phone is on the same Wi-Fi." }
    func already(_ bots: String) -> String { ru ? "Уже работают: \(bots)" : "Already working: \(bots)" }
    var botHeader: String { ru ? "БОТ" : "BOT" }
    var tokenPlaceholder: String { ru ? "Вставь токен из @BotFather" : "Paste the token from @BotFather" }
    var tokenFooter: String { ru ? "Создай нового бота в @BotFather (/newbot) и вставь его токен. Токен уходит прямо на компьютер, зашифрованным." : "Create a new bot in @BotFather (/newbot) and paste its token. The token goes straight to the computer, sealed." }
    var engineHeader: String { ru ? "НА ЧЁМ БУДЕТ РАБОТАТЬ" : "WHAT IT WILL RUN ON" }
    var add: String { ru ? "Добавить" : "Add" }
    var failedTitle: String { ru ? "Не вышло добавить" : "Could Not Add It" }
    var unreachable: String { ru ? "Компьютер не ответил. Он в этой Wi-Fi и помощник на нём запущен?" : "The computer did not answer. Is it on this Wi-Fi with the helper running?" }
    func done(_ bot: String, _ computer: String) -> String { ru ? "@\(bot) теперь работает на «\(computer)». Напиши ему." : "@\(bot) now works on \(computer). Write to it." }
}

private let addTile = agentgramSymbolTile("plus", 0x2AABEE, size: agentgramHeroTileSize)
private let computerTile = agentgramSymbolTile("laptopcomputer", 0x5856D6, size: agentgramHeroTileSize)
private let computerRowIcon = agentgramSymbolTile("laptopcomputer", 0x5856D6)
private let macIcon = agentgramSymbolTile("apple.logo", 0x1C1C1E)
private let windowsIcon = agentgramSymbolTile("pc", 0x0078D4)
private let linuxIcon = agentgramSymbolTile("server.rack", 0xC7C7CC)

private final class AddAgentArguments {
    let pickComputer: (ConnectedComputer) -> Void
    let pickPlatform: (String) -> Void
    let pickChatBot: () -> Void

    init(pickComputer: @escaping (ConnectedComputer) -> Void, pickPlatform: @escaping (String) -> Void, pickChatBot: @escaping () -> Void) {
        self.pickComputer = pickComputer
        self.pickPlatform = pickPlatform
        self.pickChatBot = pickChatBot
    }
}

private enum AddAgentEntry: ItemListNodeEntry {
    case header(String, String)
    case connectedHeader(String)
    case computer(Int32, ConnectedComputer, String)
    case newHeader(String)
    case platform(Int32, String, String, String)
    case noComputerHeader(String)
    case chatBot(String, String)

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        case .connectedHeader, .computer: return 1
        case .newHeader, .platform: return 2
        case .noComputerHeader, .chatBot: return 3
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case .connectedHeader: return 1
        case let .computer(index, _, _): return 10 + index
        case .newHeader: return 500
        case let .platform(index, _, _, _): return 510 + index
        case .noComputerHeader: return 600
        case .chatBot: return 601
        }
    }

    static func <(lhs: AddAgentEntry, rhs: AddAgentEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AddAgentArguments
        switch self {
        case let .header(title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: addTile, sectionId: self.section)
        case let .connectedHeader(text), let .newHeader(text), let .noComputerHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .computer(_, computer, detail):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computerRowIcon, title: computer.name, label: "", additionalDetailLabel: detail, sectionId: self.section, style: .blocks, action: {
                arguments.pickComputer(computer)
            })
        case let .platform(_, id, title, soon):
            let icon = id == "mac" ? macIcon : (id == "windows" ? windowsIcon : linuxIcon)
            if !soon.isEmpty {
                return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, enabled: false, label: soon, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
            }
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pickPlatform(id)
            })
        case let .chatBot(title, detail):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: agentgramChatBotRowIcon, title: title, label: "", additionalDetailLabel: detail, sectionId: self.section, style: .blocks, action: {
                arguments.pickChatBot()
            })
        }
    }
}

func agentgramAddAgentController(context: AccountContext, browser: ComputersBrowser) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    let arguments = AddAgentArguments(pickComputer: { computer in
        let texts = AddAgentTexts(context.sharedContext.currentPresentationData.with { $0 }.strings)
        var endpoint: NWEndpoint?
        let _ = (browser.computers.get() |> take(1)).start(next: { found in
            endpoint = found.first(where: { $0.publicKey == computer.publicKey })?.endpoint
        })
        guard let endpoint else {
            presentImpl?(agentgramAlert(context, texts.awayAlert))
            return
        }
        pushImpl?(agentgramNewAgentController(context: context, computer: computer, endpoint: endpoint))
    }, pickPlatform: { platform in
        pushImpl?(agentgramComputersController(context: context, platform: platform))
    }, pickChatBot: {
        pushImpl?(agentgramNewChatBotController(context: context))
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, browser.computers.get(), ConnectedComputers.changed.get())
    |> map { presentationData, found, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = AddAgentTexts(presentationData.strings)
        var entries: [AddAgentEntry] = [.header(texts.whereTitle, texts.whereText)]
        let computers = ConnectedComputers.computers(context)
        if !computers.isEmpty {
            entries.append(.connectedHeader(texts.connectedHeader))
            let all = ConnectedComputers.all(context)
            for (i, computer) in computers.enumerated() {
                let count = all.filter { $0.publicKey == computer.publicKey }.count
                let near = found.contains(where: { $0.publicKey == computer.publicKey })
                entries.append(.computer(Int32(i), computer, texts.agentsCount(count) + " · " + (near ? texts.nearby : texts.away)))
            }
        }
        entries.append(.newHeader(texts.newHeader))
        entries.append(.platform(0, "mac", "Mac", ""))
        entries.append(.platform(1, "windows", "Windows", ""))
        entries.append(.platform(2, "linux", "Linux", texts.soon))
        let chatTexts = ChatBotTexts(presentationData.strings)
        entries.append(.noComputerHeader(chatTexts.noComputerHeader))
        entries.append(.chatBot(chatTexts.chatBot, chatTexts.onPhone))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(""), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] next in
        controller?.push(next)
    }
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    return controller
}

// MARK: One more agent on a connected computer

private final class NewAgentArguments {
    let updateToken: (String) -> Void
    let selectEngine: (String) -> Void
    let add: () -> Void

    init(updateToken: @escaping (String) -> Void, selectEngine: @escaping (String) -> Void, add: @escaping () -> Void) {
        self.updateToken = updateToken
        self.selectEngine = selectEngine
        self.add = add
    }
}

private enum NewAgentEntry: ItemListNodeEntry {
    case header(String, String)
    case botHeader(String)
    case token(String, String)
    case tokenFooter(String)
    case engineHeader(String)
    case engine(Int32, String, String, Bool)
    case add(String, Bool)

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        case .botHeader, .token, .tokenFooter: return 1
        case .engineHeader, .engine: return 2
        case .add: return 3
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case .botHeader: return 1
        case .token: return 2
        case .tokenFooter: return 3
        case .engineHeader: return 4
        case let .engine(index, _, _, _): return 10 + index
        case .add: return 100
        }
    }

    static func <(lhs: NewAgentEntry, rhs: NewAgentEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! NewAgentArguments
        switch self {
        case let .header(title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: computerTile, sectionId: self.section)
        case let .botHeader(text), let .engineHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .token(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { value in
                arguments.updateToken(value)
            }, action: {})
        case let .tokenFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .engine(_, id, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: agentgramEngineIcon(id), title: title, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectEngine(id)
            })
        case let .add(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.add()
            })
        }
    }
}

private struct NewAgentState: Equatable {
    var token = ""
    var engine = "claude"
    var busy = false
}

func agentgramNewAgentController(context: AccountContext, computer: ConnectedComputer, endpoint: NWEndpoint) -> ViewController {
    let statePromise = ValuePromise(NewAgentState(), ignoreRepeated: true)
    let stateValue = Atomic(value: NewAgentState())
    let updateState: ((inout NewAgentState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }
    var presentImpl: ((ViewController) -> Void)?
    var finishImpl: (() -> Void)?
    let arguments = NewAgentArguments(updateToken: { value in
        updateState { $0.token = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }, selectEngine: { engine in
        updateState { $0.engine = engine }
    }, add: {
        let state = stateValue.with { $0 }
        guard !state.token.isEmpty, !state.busy else {
            return
        }
        updateState { $0.busy = true }
        askComputer(endpoint, computer, path: "/agent/add", extra: ["token": state.token, "engine": state.engine], completion: { result in
            Queue.mainQueue().async {
                updateState { $0.busy = false }
                let texts = AddAgentTexts(context.sharedContext.currentPresentationData.with { $0 }.strings)
                guard result?["ok"] as? Bool == true, let bot = result?["bot"] as? String else {
                    // the computer says what went wrong; no answer at all: it is not reachable
                    let reason = (result?["error"] as? String) ?? texts.unreachable
                    presentImpl?(textAlertController(context: context, title: texts.failedTitle, text: reason, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]))
                    return
                }
                ConnectedComputers.add(context, ConnectedComputer(name: computer.name, publicKey: computer.publicKey, bot: bot, engine: state.engine, secret: computer.secret))
                presentImpl?(textAlertController(context: context, title: nil, text: texts.done(bot, computer.name), actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {
                    finishImpl?()
                })]))
            }
        })
    })
    let installed = Promise<[String: Bool]>([:])
    askComputer(endpoint, computer, path: "/info", completion: { info in
        installed.set(.single(info?["installed"] as? [String: Bool] ?? [:]))
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get(), installed.get())
    |> map { presentationData, state, installed -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = AddAgentTexts(presentationData.strings)
        let bots = ConnectedComputers.all(context).filter { $0.publicKey == computer.publicKey }.map { "@" + $0.bot }.joined(separator: ", ")
        var entries: [NewAgentEntry] = [.header(computer.name, texts.already(bots)), .botHeader(texts.botHeader), .token(state.token, texts.tokenPlaceholder), .tokenFooter(texts.tokenFooter), .engineHeader(texts.engineHeader)]
        for (i, (id, title)) in agentgramEngines.enumerated() where installed[id] ?? (id != "chat") {
            entries.append(.engine(Int32(i), id, title, state.engine == id))
        }
        entries.append(.add(texts.add, !state.token.isEmpty && !state.busy))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(""), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    // back to Agentgram's section, where the new agent is listed
    finishImpl = { [weak controller] in
        guard let controller, let navigationController = controller.navigationController as? NavigationController else {
            return
        }
        let stack = navigationController.viewControllers
        if let index = stack.firstIndex(where: { $0 === controller }), index >= 2 {
            navigationController.setViewControllers(Array(stack.prefix(index - 1)), animated: true)
        }
    }
    return controller
}
