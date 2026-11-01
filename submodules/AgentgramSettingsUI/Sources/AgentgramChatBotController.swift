import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// «Чат-бот» screens: adding one (the bot's token, an OpenRouter key, a model) and one bot's own screen (its model,
// turning it off). The bot runs on the phone, see AgentgramChatBots.swift.

struct ChatBotTexts {
    let ru: Bool

    init(_ strings: PresentationStrings) {
        self.ru = strings.primaryComponent.languageCode.hasPrefix("ru")
    }

    var noComputerHeader: String { ru ? "БЕЗ КОМПЬЮТЕРА" : "NO COMPUTER" }
    var chatBot: String { ru ? "Чат-бот" : "Chat Bot" }
    var onPhone: String { ru ? "работает в телефоне" : "runs on this phone" }
    var addText: String { ru ? "Бот отвечает моделью из OpenRouter. Работает прямо в телефоне, пока Telepath открыт." : "The bot answers with a model from OpenRouter. It runs right on this phone while Telepath is open." }
    var botHeader: String { ru ? "БОТ" : "BOT" }
    var tokenPlaceholder: String { ru ? "Вставь токен из @BotFather" : "Paste the token from @BotFather" }
    var tokenFooter: String { ru ? "Создай нового бота в @BotFather (/newbot) и вставь его токен." : "Create a new bot in @BotFather (/newbot) and paste its token." }
    var keyHeader: String { ru ? "КЛЮЧ OPENROUTER" : "OPENROUTER KEY" }
    var keyPlaceholder: String { ru ? "Вставь ключ" : "Paste the key" }
    var keyFooter: String { ru ? "Ключ создаётся на openrouter.ai/keys. Токен и ключ хранятся только в этом телефоне и уходят только в Telegram и OpenRouter." : "Create a key at openrouter.ai/keys. The token and the key stay on this phone and go only to Telegram and OpenRouter." }
    var modelHeader: String { ru ? "МОДЕЛЬ" : "MODEL" }
    var add: String { ru ? "Добавить" : "Add" }
    var failedTitle: String { ru ? "Не вышло добавить" : "Could Not Add It" }
    var badToken: String { ru ? "Telegram не принял токен. Проверь, что он скопирован целиком." : "Telegram did not accept the token. Check that it is copied in full." }
    var badKey: String { ru ? "OpenRouter не принял ключ." : "OpenRouter did not accept the key." }
    func done(_ bot: String) -> String { ru ? "@\(bot) отвечает, пока Telepath открыт. Напиши ему." : "@\(bot) answers while Telepath is open. Write to it." }
    var keyRow: String { ru ? "Ключ OpenRouter" : "OpenRouter Key" }
    var off: String { ru ? "Отключить" : "Turn Off" }
    func offConfirm(_ bot: String) -> String { ru ? "Отключить @\(bot)? Бот перестанет отвечать, его токен и ключ удалятся из телефона." : "Turn off @\(bot)? The bot stops answering, its token and key are removed from this phone." }
    var cancel: String { ru ? "Отмена" : "Cancel" }
    var botFooter: String { ru ? "Бот отвечает только тебе и только пока Telepath открыт." : "The bot answers only you and only while Telepath is open." }
}

let agentgramChatBotRowIcon = agentgramEngineIcon("chat")
private let chatBotTile = agentgramSymbolTile("bubble.left.fill", 0x34C759, size: agentgramHeroTileSize)

// MARK: - Adding a chat bot

private final class NewChatBotArguments {
    let updateToken: (String) -> Void
    let updateKey: (String) -> Void
    let selectModel: (String) -> Void
    let add: () -> Void

    init(updateToken: @escaping (String) -> Void, updateKey: @escaping (String) -> Void, selectModel: @escaping (String) -> Void, add: @escaping () -> Void) {
        self.updateToken = updateToken
        self.updateKey = updateKey
        self.selectModel = selectModel
        self.add = add
    }
}

private enum NewChatBotEntry: ItemListNodeEntry {
    case header(String, String)
    case botHeader(String)
    case token(String, String)
    case tokenFooter(String)
    case keyHeader(String)
    case key(String, String)
    case keyFooter(String)
    case modelHeader(String)
    case model(Int32, String, String, Bool)
    case add(String, Bool)

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        case .botHeader, .token, .tokenFooter: return 1
        case .keyHeader, .key, .keyFooter: return 2
        case .modelHeader, .model: return 3
        case .add: return 4
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case .botHeader: return 1
        case .token: return 2
        case .tokenFooter: return 3
        case .keyHeader: return 4
        case .key: return 5
        case .keyFooter: return 6
        case .modelHeader: return 7
        case let .model(index, _, _, _): return 10 + index
        case .add: return 100
        }
    }

    static func <(lhs: NewChatBotEntry, rhs: NewChatBotEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! NewChatBotArguments
        switch self {
        case let .header(title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: chatBotTile, sectionId: self.section)
        case let .botHeader(text), let .keyHeader(text), let .modelHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .token(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { value in
                arguments.updateToken(value)
            }, action: {})
        case let .key(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), clearType: .always, sectionId: self.section, textUpdated: { value in
                arguments.updateKey(value)
            }, action: {})
        case let .tokenFooter(text), let .keyFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .model(_, id, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectModel(id)
            })
        case let .add(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.add()
            })
        }
    }
}

private struct NewChatBotState: Equatable {
    var token = ""
    var key = ""
    var model = agentgramChatModels[0].id
    var busy = false
}

func agentgramNewChatBotController(context: AccountContext) -> ViewController {
    let statePromise = ValuePromise(NewChatBotState(), ignoreRepeated: true)
    let stateValue = Atomic(value: NewChatBotState())
    let updateState: ((inout NewChatBotState) -> Void) -> Void = { f in
        statePromise.set(stateValue.modify { state in
            var state = state
            f(&state)
            return state
        })
    }
    var presentImpl: ((ViewController) -> Void)?
    var finishImpl: (() -> Void)?
    let fail = { (text: String) in
        Queue.mainQueue().async {
            updateState { $0.busy = false }
            let texts = ChatBotTexts(context.sharedContext.currentPresentationData.with { $0 }.strings)
            presentImpl?(textAlertController(context: context, title: texts.failedTitle, text: text, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]))
        }
    }
    let arguments = NewChatBotArguments(updateToken: { value in
        updateState { $0.token = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }, updateKey: { value in
        updateState { $0.key = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }, selectModel: { model in
        updateState { $0.model = model }
    }, add: {
        let state = stateValue.with { $0 }
        guard !state.token.isEmpty, !state.key.isEmpty, !state.busy else {
            return
        }
        updateState { $0.busy = true }
        let texts = ChatBotTexts(context.sharedContext.currentPresentationData.with { $0 }.strings)
        // the token gives the bot's name; the key is checked before anything is kept
        agentgramBotCall(state.token, "getMe", [:], completion: { result in
            guard result?["ok"] as? Bool == true, let bot = (result?["result"] as? [String: Any])?["username"] as? String else {
                fail(texts.badToken)
                return
            }
            agentgramCheckOpenRouterKey(state.key, completion: { valid in
                guard valid else {
                    fail(texts.badKey)
                    return
                }
                // a webhook would keep the updates from the phone
                agentgramBotCall(state.token, "deleteWebhook", [:], completion: { _ in
                    Queue.mainQueue().async {
                        updateState { $0.busy = false }
                        AgentgramChatBots.put(context, AgentgramChatBot(bot: bot, token: state.token, key: state.key, model: state.model))
                        presentImpl?(textAlertController(context: context, title: nil, text: texts.done(bot), actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {
                            finishImpl?()
                        })]))
                    }
                })
            })
        })
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = ChatBotTexts(presentationData.strings)
        var entries: [NewChatBotEntry] = [
            .header(texts.chatBot, texts.addText),
            .botHeader(texts.botHeader), .token(state.token, texts.tokenPlaceholder), .tokenFooter(texts.tokenFooter),
            .keyHeader(texts.keyHeader), .key(state.key, texts.keyPlaceholder), .keyFooter(texts.keyFooter),
            .modelHeader(texts.modelHeader)
        ]
        for (i, model) in agentgramChatModels.enumerated() {
            entries.append(.model(Int32(i), model.id, model.name, state.model == model.id))
        }
        entries.append(.add(texts.add, !state.token.isEmpty && !state.key.isEmpty && !state.busy))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(""), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    // back to Telepath's section, where the new bot is listed
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

// MARK: - One chat bot

private final class ChatBotArguments {
    let selectModel: (String) -> Void
    let turnOff: () -> Void

    init(selectModel: @escaping (String) -> Void, turnOff: @escaping () -> Void) {
        self.selectModel = selectModel
        self.turnOff = turnOff
    }
}

private enum ChatBotEntry: ItemListNodeEntry {
    case header(String, String)
    case modelHeader(String)
    case model(Int32, String, String, Bool)
    case key(String, String)
    case footer(String)
    case off(String)

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        case .modelHeader, .model: return 1
        case .key, .footer: return 2
        case .off: return 3
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case .modelHeader: return 1
        case let .model(index, _, _, _): return 10 + index
        case .key: return 100
        case .footer: return 101
        case .off: return 200
        }
    }

    static func <(lhs: ChatBotEntry, rhs: ChatBotEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ChatBotArguments
        switch self {
        case let .header(title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: chatBotTile, sectionId: self.section)
        case let .modelHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .model(_, id, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectModel(id)
            })
        case let .key(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .off(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.turnOff()
            })
        }
    }
}

func agentgramChatBotController(context: AccountContext, bot name: String) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?
    let arguments = ChatBotArguments(selectModel: { model in
        guard var bot = AgentgramChatBots.all(context).first(where: { $0.bot == name }) else {
            return
        }
        bot.model = model
        AgentgramChatBots.put(context, bot)
    }, turnOff: {
        let texts = ChatBotTexts(context.sharedContext.currentPresentationData.with { $0 }.strings)
        presentImpl?(textAlertController(context: context, title: nil, text: texts.offConfirm(name), actions: [TextAlertAction(type: .genericAction, title: texts.cancel, action: {}), TextAlertAction(type: .destructiveAction, title: texts.off, action: {
            AgentgramChatBots.remove(context, bot: name)
            popImpl?()
        })]))
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, AgentgramChatBots.changed.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = ChatBotTexts(presentationData.strings)
        var entries: [ChatBotEntry] = []
        if let bot = AgentgramChatBots.all(context).first(where: { $0.bot == name }) {
            entries.append(.header("@" + bot.bot, texts.chatBot + " · " + texts.onPhone))
            entries.append(.modelHeader(texts.modelHeader))
            var models = agentgramChatModels
            if !models.contains(where: { $0.id == bot.model }) {
                models.append((bot.model, bot.model))
            }
            for (i, model) in models.enumerated() {
                entries.append(.model(Int32(i), model.id, model.name, bot.model == model.id))
            }
            entries.append(.key(texts.keyRow, "••••" + String(bot.key.suffix(4))))
            entries.append(.footer(texts.botFooter))
            entries.append(.off(texts.off))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(""), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    popImpl = { [weak controller] in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}
