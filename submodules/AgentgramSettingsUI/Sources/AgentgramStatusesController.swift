import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// «Статусы» on an agent's screen: how the session statuses reach the phone. Off: only Telegram's own «typing…» in the
// topic. Only on the local network: at home everything straight from the computer, away «typing…». Everywhere: away
// the basic states through the bot's messages too. The computer learns the choice when the phone is on its Wi-Fi.

public enum AgentgramStatusesMode: String, CaseIterable {
    case off
    case lan
    case everywhere

    private static let key = "agentgram.statuses"
    private static let pendingKey = "agentgram.statuses.pending"

    public static var current: AgentgramStatusesMode {
        return UserDefaults.standard.string(forKey: key).flatMap { AgentgramStatusesMode(rawValue: $0) } ?? .off
    }

    static func set(_ mode: AgentgramStatusesMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
        changed.set(0)
    }

    // the choice still to tell the computer, when it was made away from it
    static var pending: Bool {
        get { UserDefaults.standard.bool(forKey: pendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: pendingKey) }
    }

    static let changed = ValuePromise<Int>(0, ignoreRepeated: false)
}

private struct StatusesTexts {
    let ru: Bool

    init(_ strings: PresentationStrings) {
        self.ru = strings.primaryComponent.languageCode.hasPrefix("ru")
    }

    var title: String { ru ? "Статусы" : "Statuses" }
    var headerLine: String { ru ? "Что агент делает, пока ты ждёшь" : "What the agent does while you wait" }
    // two choices: «lan», the old middle one, reads as «Подробные»
    func name(_ mode: AgentgramStatusesMode) -> String {
        return mode == .off ? (ru ? "Стандартные" : "Standard") : (ru ? "Подробные" : "Detailed")
    }
    func detail(_ mode: AgentgramStatusesMode) -> String {
        return mode == .off ? (ru ? "«печатает…», как в Telegram" : "«typing…», as in Telegram") : (ru ? "что делает агент, шаги и время" : "what the agent does, its steps and time")
    }
    func footer(_ mode: AgentgramStatusesMode) -> String {
        return mode == .off ? (ru ? "Пока агент работает, в теме горит «печатает…», как у человека." : "While the agent works, the topic shows «typing…», like a person.") : (ru ? "В теме видно, что делает агент: читает, правит, запускает команды, и сколько это идёт." : "The topic shows what the agent does: reads, edits, runs commands, and for how long.")
    }
    var later: String { ru ? "Компьютер сейчас не в этой сети. Выбор дойдёт до него, когда телефон будет в той же Wi-Fi. Можно сменить и в меню значка Telepath на компьютере." : "The computer is not on this network now. It gets the choice when the phone is on the same Wi-Fi. It can also be changed in the Telepath icon's menu on the computer." }
}

func agentgramStatusesRowValue(_ strings: PresentationStrings) -> String {
    return StatusesTexts(strings).name(AgentgramStatusesMode.current)
}

// a row of the example: a topic, what it shows, the yellow dot of a working session
struct StatusesPreviewRow: Equatable {
    let title: String
    let text: String
    let color: UInt32
    let dot: Bool
}

private final class StatusesArguments {
    let select: (AgentgramStatusesMode) -> Void

    init(select: @escaping (AgentgramStatusesMode) -> Void) {
        self.select = select
    }
}

private let statusesTile = agentgramSymbolTile("circle.dotted.circle", 0xF5B70A, size: agentgramHeroTileSize)
private let modeIcons: [AgentgramStatusesMode: UIImage?] = [
    .off: agentgramSymbolTile("ellipsis", 0x8E8E93),
    .lan: agentgramSymbolTile("wifi", 0x34C759),
    .everywhere: agentgramSymbolTile("antenna.radiowaves.left.and.right", 0x2AABEE)
]

private enum StatusesEntry: ItemListNodeEntry {
    case header(String, String)
    case mode(Int32, AgentgramStatusesMode, String, String, Bool)
    case footer(String)
    case previewHeader(Int32, String)
    case preview(Int32, [StatusesPreviewRow])

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        case .mode, .footer: return 1
        case let .previewHeader(index, _), let .preview(index, _): return 2 + index
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return -1
        case let .mode(index, _, _, _, _): return index
        case .footer: return 100
        case let .previewHeader(index, _): return 200 + index * 10
        case let .preview(index, _): return 201 + index * 10
        }
    }

    static func <(lhs: StatusesEntry, rhs: StatusesEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! StatusesArguments
        switch self {
        case let .header(title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: statusesTile, sectionId: self.section)
        case let .mode(_, mode, title, detail, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: modeIcons[mode] ?? nil, title: title, subtitle: detail, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(mode)
            })
        case let .previewHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .preview(_, rows):
            return AgentgramTopicsPreviewItem(presentationData: presentationData, rows: rows.map { PreviewRow(title: $0.title, text: $0.text, color: UIColor(rgb: $0.color), letter: "#", topic: false, status: $0.dot) }, sectionId: self.section)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

// tells a nearby computer the choice; false when no computer of this phone is nearby
func agentgramSendStatusesMode(context: AccountContext) -> Bool {
    var sent = false
    for computer in ConnectedComputers.all(context) {
        if let endpoint = agentgramNearbyEndpoint(computer.publicKey) {
            sent = true
            askComputer(endpoint, computer, path: "/statuses", extra: ["mode": AgentgramStatusesMode.current.rawValue], completion: { result in
                if result?["ok"] as? Bool == true {
                    AgentgramStatusesMode.pending = false
                }
            })
        }
    }
    return sent
}

func agentgramStatusesController(context: AccountContext) -> ViewController {
    var presentImpl: ((ViewController) -> Void)?
    let arguments = StatusesArguments(select: { mode in
        AgentgramStatusesMode.set(mode)
        AgentgramStatusesMode.pending = true
        if !agentgramSendStatusesMode(context: context) {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            presentImpl?(agentgramAlert(context, StatusesTexts(presentationData.strings).later))
        }
    })
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, AgentgramStatusesMode.changed.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = StatusesTexts(presentationData.strings)
        let current = AgentgramStatusesMode.current
        var entries: [StatusesEntry] = [.header(texts.title, texts.headerLine)]
        let detailed = current != .off
        for (i, mode) in [AgentgramStatusesMode.off, .everywhere].enumerated() {
            entries.append(.mode(Int32(i), mode, texts.name(mode), texts.detail(mode), (mode != .off) == detailed))
        }
        entries.append(.footer(texts.footer(current)))
        // how the list looks, as chosen
        let typing = texts.ru ? "печатает…" : "typing…"
        let home: [StatusesPreviewRow] = current == .off ? [
            StatusesPreviewRow(title: "olegaego", text: typing, color: 0xFF9500, dot: false),
            StatusesPreviewRow(title: "osform", text: texts.ru ? "Готово, поправил шапку" : "Done, fixed the header", color: 0xAF52DE, dot: false)
        ] : [
            StatusesPreviewRow(title: "olegaego", text: texts.ru ? "запускает: go build · 2 мин" : "running: go build · 2 min", color: 0xFF9500, dot: true),
            StatusesPreviewRow(title: "osform", text: texts.ru ? "ждёт тебя" : "waiting for you", color: 0xAF52DE, dot: false)
        ]
        entries.append(.previewHeader(0, texts.ru ? "КАК ЭТО ВЫГЛЯДИТ" : "HOW IT LOOKS"))
        entries.append(.preview(0, home))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(texts.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    return controller
}
