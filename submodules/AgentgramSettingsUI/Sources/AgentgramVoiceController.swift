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

// «Способ» of «Распознавание» on an agent's screen: how the computer turns voice messages into text. On the computer:
// Whisper, the model downloaded onto it. Or Groq: the key goes to the computer, sealed, over the local network.
// Everything is set while the phone is on the computer's Wi-Fi (or in the helper's menu on the computer).

private struct VoiceTexts {
    let ru: Bool

    init(_ strings: PresentationStrings) {
        self.ru = strings.primaryComponent.languageCode.hasPrefix("ru")
    }

    var onComputer: String { ru ? "Компьютер" : "Computer" }
    var viaGroq: String { "Groq" }
    var whisperTitle: String { "Whisper" }
    func whisperLine(_ computer: String) -> String { ru ? "Распознаёт \(computer). Голос никуда не уходит." : "\(computer) recognizes it. Your voice goes nowhere." }
    var groqLine: String { ru ? "Распознаёт за секунду по твоему ключу. Голос уходит в Groq." : "Recognizes in a second with your key. Your voice goes to Groq." }
    var replaceKey: String { ru ? "Заменить ключ" : "Replace Key" }
    var downloadedHint: String { ru ? "Когда скачается, нажми, чтобы выбрать." : "When it is downloaded, tap to choose it." }
    var modelHeader: String { ru ? "МОДЕЛЬ" : "MODEL" }
    var accurate: String { ru ? "Точная" : "Accurate" }
    var light: String { ru ? "Лёгкая" : "Light" }
    func size(_ mb: Int) -> String { ru ? "\(mb) МБ" : "\(mb) MB" }
    var onTheComputer: String { ru ? "на компьютере" : "on the computer" }
    func downloading(_ percent: Int) -> String { ru ? "скачивается на компьютер, \(percent)%" : "downloading to the computer, \(percent)%" }
    var download: String { ru ? "Скачать" : "Download" }
    var modelsFooter: String { ru ? "Точная лучше понимает смесь русского и английского, названия файлов и команд. Лёгкая быстрее и занимает меньше места. Скачиваются на компьютер с Hugging Face, откуда их раздаёт автор whisper.cpp." : "Accurate understands mixed languages, file and command names better. Light is faster and smaller. They are downloaded onto the computer from Hugging Face, where the whisper.cpp author shares them." }
    var keyHeader: String { ru ? "КЛЮЧ GROQ" : "GROQ KEY" }
    var keyPlaceholder: String { ru ? "Вставь ключ gsk_…" : "Paste the key gsk_…" }
    var keySaved: String { ru ? "Ключ на компьютере" : "Key on the computer" }
    var keySavedValue: String { ru ? "сохранён" : "saved" }
    var keyFooter: String { ru ? "Ключ бесплатный: console.groq.com → API Keys → Create. Уходит только на компьютер, зашифрованным, и хранится там. На телефоне не остаётся." : "The key is free: console.groq.com → API Keys → Create. It goes only to the computer, encrypted, and stays there. Not kept on the phone." }
    var groqDefault: String { ru ? "быстрее и дешевле" : "faster and cheaper" }
    var groqPrecise: String { ru ? "чуть точнее" : "a bit more precise" }
    var away: String { ru ? "Компьютер сейчас не в этой сети. Распознавание настраивается, когда телефон в той же Wi-Fi, или в меню значка Telepath на компьютере." : "The computer is not on this network now. Recognition is set up when the phone is on the same Wi-Fi, or in the Telepath icon's menu on the computer." }
    var failed: String { ru ? "Не вышло. Компьютер рядом?" : "It did not work. Is the computer nearby?" }
}

// The value on the agent's screen: the model on the computer, or Groq
func agentgramVoiceRowValue(_ strings: PresentationStrings, info: [String: Any]?) -> String {
    let texts = VoiceTexts(strings)
    guard let voice = AgentgramComputerVoice(info) else {
        let settings = AgentgramVoiceSettings.current
        return settings.mode == "groq" ? "Groq" : (settings.model == "accurate" ? texts.accurate : texts.light)
    }
    if voice.mode == "groq" {
        return "Groq"
    }
    return voice.model == "accurate" ? texts.accurate : texts.light
}

// Recognition is one for all agents: a change goes to every connected computer nearby; the answer is the first one's,
// nil when none is nearby
func agentgramSendVoice(context: AccountContext, fields: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
    let targets = ConnectedComputers.computers(context).compactMap { computer -> (ConnectedComputer, NWEndpoint)? in
        agentgramNearbyEndpoint(computer.publicKey).map { (computer, $0) }
    }
    guard !targets.isEmpty else {
        completion(nil)
        return
    }
    var answered = false
    var left = targets.count
    for (computer, endpoint) in targets {
        askComputer(endpoint, computer, path: "/voice", extra: fields, completion: { result in
            left -= 1
            let ok = result?["ok"] as? Bool == true
            if ok && !answered {
                answered = true
                completion(result)
            } else if left == 0 && !answered {
                completion(nil)
            }
        })
    }
}

private final class VoiceArguments {
    let pickModel: (String) -> Void
    let updateKey: (String) -> Void
    let saveKey: () -> Void
    let replaceKey: () -> Void
    let pickGroqModel: (String) -> Void

    init(pickModel: @escaping (String) -> Void, updateKey: @escaping (String) -> Void, saveKey: @escaping () -> Void, replaceKey: @escaping () -> Void, pickGroqModel: @escaping (String) -> Void) {
        self.pickModel = pickModel
        self.updateKey = updateKey
        self.saveKey = saveKey
        self.replaceKey = replaceKey
        self.pickGroqModel = pickGroqModel
    }
}

private enum ModelState: Equatable {
    case chosen
    case downloaded
    case notDownloaded(String)
    case downloading(Double)
}

private let whisperTile = agentgramSymbolTile("waveform", 0xFF2D55, size: agentgramHeroTileSize)
private let groqTile = agentgramSymbolTile("bolt.fill", 0xF55036, size: agentgramHeroTileSize)
private let lightIcon = agentgramSymbolTile("hare.fill", 0x34C759)
private let accurateIcon = agentgramSymbolTile("scope", 0x5856D6)
private let turboIcon = agentgramSymbolTile("bolt.fill", 0xFF9500)
private let keyIcon = agentgramSymbolTile("key.fill", 0x8E8E93)
private let replaceKeyIcon = agentgramSymbolTile("pencil", 0x2AABEE)

private enum VoiceEntry: ItemListNodeEntry {
    case header(Bool, String, String)
    case modelHeader(String)
    case model(Int32, String, String, String, ModelState)
    case modelsFooter(String)
    case keyHeader(String)
    case keySaved(String, String)
    case replaceKey(String)
    case key(String, String)
    case keyFooter(String)
    case groqHeader(String)
    case groqModel(Int32, String, String, String, Bool)

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        case .modelHeader, .model, .modelsFooter, .keyHeader, .keySaved, .replaceKey, .key, .keyFooter: return 1
        case .groqHeader, .groqModel: return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case .keyHeader: return 2
        case .keySaved: return 3
        case .replaceKey: return 4
        case .key: return 5
        case .keyFooter: return 6
        case .modelHeader: return 8
        case let .model(index, _, _, _, _): return 10 + index
        case .modelsFooter: return 18
        case .groqHeader: return 19
        case let .groqModel(index, _, _, _, _): return 20 + index
        }
    }

    static func <(lhs: VoiceEntry, rhs: VoiceEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! VoiceArguments
        let accent = presentationData.theme.list.itemAccentColor
        switch self {
        case let .header(groq, title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: groq ? groqTile : whisperTile, sectionId: self.section)
        case let .modelsFooter(text), let .keyFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .modelHeader(text), let .keyHeader(text), let .groqHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .model(_, id, title, detail, state):
            let icon = id == AgentgramWhisperModel.light.id ? lightIcon : accurateIcon
            switch state {
            case .chosen, .downloaded:
                return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, subtitle: detail, style: .right, checked: state == .chosen, zeroSeparatorInsets: false, sectionId: self.section, action: {
                    arguments.pickModel(id)
                })
            case let .notDownloaded(button):
                let capsule = agentgramCapsule(button, color: accent)
                return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, label: "", labelStyle: capsule.flatMap { .image(image: $0.0, size: $0.1) } ?? .text, additionalDetailLabel: detail, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                    arguments.pickModel(id)
                })
            case let .downloading(progress):
                let ring = agentgramProgressRing(progress, color: accent, track: presentationData.theme.list.itemPlainSeparatorColor)
                return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, label: "", labelStyle: ring.flatMap { .image(image: $0.0, size: $0.1) } ?? .text, additionalDetailLabel: detail, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
            }
        case let .keySaved(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: keyIcon, title: title, label: label, labelStyle: .coloredText(UIColor(rgb: 0x34C759)), sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .replaceKey(title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: replaceKeyIcon, title: title, titleColor: .accent, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.replaceKey()
            })
        case let .key(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .username, returnKeyType: .done, clearType: .always, sectionId: self.section, textUpdated: { value in
                arguments.updateKey(value)
            }, action: {
                arguments.saveKey()
            })
        case let .groqModel(index, id, title, detail, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: index == 0 ? turboIcon : accurateIcon, title: title, subtitle: detail, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.pickGroqModel(id)
            })
        }
    }
}

private struct VoiceState {
    var tab: String = AgentgramVoiceSettings.current.mode
    var key: String = ""
    var editingKey = false
    var info: [String: Any]?
}

func agentgramVoiceController(context: AccountContext, computer: ConnectedComputer, info: [String: Any]?, changed: @escaping ([String: Any]) -> Void) -> ViewController {
    var initial = VoiceState()
    initial.info = info
    if let voice = AgentgramComputerVoice(info), voice.mode == "groq" || voice.mode == "whisper" {
        initial.tab = voice.mode
    }
    let stateValue = Atomic(value: initial)
    let tick = ValuePromise<Int>(0, ignoreRepeated: false)
    let updateState: ((inout VoiceState) -> Void) -> Void = { f in
        let _ = stateValue.modify { state in
            var state = state
            f(&state)
            return state
        }
        tick.set(0)
    }
    var presentImpl: ((ViewController) -> Void)?
    let send: ([String: Any]) -> Void = { fields in
        agentgramSendVoice(context: context, fields: fields, completion: { result in
            Queue.mainQueue().async {
                if let result, let voice = result["voice"] {
                    updateState { state in
                        var info = state.info ?? [:]
                        info["voice"] = voice
                        state.info = info
                    }
                    changed(stateValue.with { $0.info } ?? [:])
                } else {
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    let texts = VoiceTexts(presentationData.strings)
                    presentImpl?(agentgramAlert(context, agentgramNearbyEndpoint(computer.publicKey) == nil ? texts.away : texts.failed))
                }
            }
        })
    }
    let arguments = VoiceArguments(pickModel: { id in
        AgentgramVoiceSettings.update { $0.mode = "whisper"; $0.model = id }
        send(["mode": "whisper", "model": id])
    }, updateKey: { value in
        updateState { $0.key = value }
    }, saveKey: {
        let key = stateValue.with { $0.key }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return
        }
        AgentgramVoiceSettings.update { $0.mode = "groq" }
        updateState { $0.key = ""; $0.editingKey = false }
        send(["mode": "groq", "groq_key": key])
    }, replaceKey: {
        updateState { $0.editingKey = true }
    }, pickGroqModel: { model in
        AgentgramVoiceSettings.update { $0.mode = "groq" }
        send(["mode": "groq", "groq_model": model])
    })

    // the computer's state every two seconds while the screen is open: the model's download goes on there
    let poll = Signal<Never, NoError> { _ in
        let timer = SwiftSignalKit.Timer(timeout: 2.0, repeat: true, completion: {
            guard let endpoint = agentgramNearbyEndpoint(computer.publicKey) else {
                return
            }
            askComputer(endpoint, computer, path: "/info", completion: { result in
                guard let result else {
                    return
                }
                Queue.mainQueue().async {
                    updateState { $0.info = result }
                }
            })
        }, queue: Queue.mainQueue())
        timer.start()
        return ActionDisposable {
            timer.invalidate()
        }
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, tick.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = VoiceTexts(presentationData.strings)
        let state = stateValue.with { $0 }
        let voice = AgentgramComputerVoice(state.info)
        var entries: [VoiceEntry] = []
        if state.tab != "groq" {
            entries.append(.header(false, texts.whisperTitle, texts.whisperLine(computer.name)))
            entries.append(.modelHeader(texts.modelHeader))
            var downloading = false
            for (i, model) in AgentgramWhisperModel.all.enumerated() {
                let status = voice?.models[model.id]
                let title = model == .light ? texts.light : texts.accurate
                if let progress = status?.progress {
                    downloading = true
                    entries.append(.model(Int32(i), model.id, title, texts.downloading(Int(progress * 100.0)), .downloading(progress)))
                } else if status?.downloaded == true {
                    let chosen = voice?.mode == "whisper" && voice?.model == model.id
                    entries.append(.model(Int32(i), model.id, title, texts.size(model.megabytes) + " · " + texts.onTheComputer, chosen ? .chosen : .downloaded))
                } else {
                    entries.append(.model(Int32(i), model.id, title, texts.size(model.megabytes), .notDownloaded(texts.download)))
                }
            }
            entries.append(.modelsFooter(downloading ? texts.downloadedHint : texts.modelsFooter))
        } else {
            entries.append(.header(true, "Groq", texts.groqLine))
            entries.append(.keyHeader(texts.keyHeader))
            let saved = voice?.groqKey == true
            if saved {
                entries.append(.keySaved(texts.keySaved, texts.keySavedValue))
            }
            if saved && !state.editingKey {
                entries.append(.replaceKey(texts.replaceKey))
            } else {
                entries.append(.key(state.key, texts.keyPlaceholder))
            }
            entries.append(.keyFooter(texts.keyFooter))
            entries.append(.groqHeader(texts.modelHeader))
            let names = ["Turbo", "Large v3"]
            for (i, model) in AgentgramVoiceSettings.groqModels.enumerated() {
                entries.append(.groqModel(Int32(i), model, names[i], i == 0 ? texts.groqDefault : texts.groqPrecise, (voice?.groqModel ?? AgentgramVoiceSettings.groqModels[0]) == model))
            }
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .sectionControl([texts.onComputer, texts.viaGroq], state.tab == "groq" ? 1 : 0), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let pollDisposable = poll.start()
    let controller = ItemListController(context: context, state: signal |> afterDisposed {
        pollDisposable.dispose()
    })
    controller.titleControlValueChanged = { index in
        updateState { $0.tab = index == 0 ? "whisper" : "groq" }
    }
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    return controller
}
