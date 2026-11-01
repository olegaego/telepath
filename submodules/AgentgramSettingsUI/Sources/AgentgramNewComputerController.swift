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

// A new Mac or Windows for an agent: the steps to install the helper, and the computers found on this network

private final class ComputersArguments {
    let connect: (NearbyComputer) -> Void
    let taken: (NearbyComputer) -> Void
    let install: () -> Void

    init(connect: @escaping (NearbyComputer) -> Void, taken: @escaping (NearbyComputer) -> Void, install: @escaping () -> Void) {
        self.connect = connect
        self.taken = taken
        self.install = install
    }
}

private enum ComputersEntry: ItemListNodeEntry {
    case platformInfo(Bool, String, String)
    case step(Int32, String, String, Bool)
    case nearbyHeader(String)
    case nearby(Int32, NearbyComputer, String)
    case searching(String)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .platformInfo:
            return 0
        case .step:
            return 1
        case .nearbyHeader, .nearby, .searching, .footer:
            return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .platformInfo: return 0
        case let .step(index, _, _, _): return 300 + index
        case .nearbyHeader: return 500
        case let .nearby(index, _, _): return 510 + index
        case .searching: return 1000
        case .footer: return 1001
        }
    }

    static func <(lhs: ComputersEntry, rhs: ComputersEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ComputersArguments
        switch self {
        case let .platformInfo(windows, title, text):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: agentgramHeroTileSize, title: title, text: text, image: windows ? windowsTile : macTile, sectionId: self.section)
        case let .step(index, title, text, download):
            let base = presentationData.fontSize.itemListBaseFontSize
            let attributed = NSMutableAttributedString(string: title + "\n", attributes: [.font: Font.semibold(base), .foregroundColor: presentationData.theme.list.itemPrimaryTextColor])
            attributed.append(NSAttributedString(string: text, attributes: [.font: Font.regular(base - 2.0), .foregroundColor: presentationData.theme.list.itemSecondaryTextColor]))
            // the first step has its button: a light «Скачать» capsule on the right
            let capsule = download ? agentgramCapsule(ComputersTexts(presentationData.strings).downloadButton, color: presentationData.theme.list.itemAccentColor) : nil
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: agentgramSymbolTile("\(index + 1).circle", 0x2AABEE), title: "", attributedTitle: attributed, label: "", labelStyle: capsule.flatMap { .image(image: $0.0, size: $0.1) } ?? .text, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: download ? {
                arguments.install()
            } : nil)
        case let .nearbyHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .nearby(_, computer, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computersNearbyIcon, title: computer.name, label: label, sectionId: self.section, style: .blocks, action: {
                if computer.paired {
                    arguments.taken(computer)
                } else {
                    arguments.connect(computer)
                }
            })
        case let .searching(text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, enabled: false, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

let computersRowIcon = renderSettingsIcon(name: "Item List/Icons/Devices", backgroundColors: [UIColor(rgb: 0x5856D6)])
private let computersNearbyIcon = renderSettingsIcon(name: "Item List/Icons/Devices", backgroundColors: [UIColor(rgb: 0x8E8E93)])

// Where Agentgram Helper is downloaded from, for each system
let agentgramHelperDownloads = [
    "mac": "https://github.com/olegaego/telepath/releases/latest/download/Telepath-Helper.dmg",
    "windows": "https://github.com/olegaego/telepath/releases/latest/download/Telepath-Helper-Windows.zip"
]

private let macTile = agentgramSymbolTile("apple.logo", 0x1C1C1E, size: agentgramHeroTileSize)
private let windowsTile = agentgramSymbolTile("pc", 0x0078D4, size: agentgramHeroTileSize)

// A new computer for an agent, Mac or Windows: where to download the helper, and the computers found on this network
func agentgramComputersController(context: AccountContext, platform: String) -> ViewController {
    let browser = agentgramBrowser
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?

    let connect: (NearbyComputer) -> Void = { computer in
        agentgramConnectNearby(context: context, computer: computer, present: { presentImpl?($0) }, push: { pushImpl?($0) })
    }
    let arguments = ComputersArguments(connect: connect, taken: connect, install: {
        if let link = agentgramHelperDownloads[platform] {
            context.sharedContext.applicationBindings.openUrl(link)
        }
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, browser.computers.get(), ConnectedComputers.changed.get())
    |> map { presentationData, found, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = ComputersTexts(presentationData.strings)
        let connected = ConnectedComputers.all(context)
        let connectedKeys = Set(connected.map { $0.publicKey })
        let nearby = found.filter { !connectedKeys.contains($0.publicKey) }
        var entries: [ComputersEntry] = []
        entries.append(.platformInfo(platform == "windows", texts.platformTitle(platform), texts.platformText))
        for (i, step) in texts.steps(platform).enumerated() {
            entries.append(.step(Int32(i), step.0, step.1, i == 0))
        }
        entries.append(.nearbyHeader(texts.nearbyHeader))
        for (i, computer) in nearby.enumerated() {
            entries.append(.nearby(Int32(i), computer, computer.paired ? texts.taken : texts.connect))
        }
        if nearby.isEmpty {
            entries.append(.searching(texts.searching))
        }
        entries.append(.footer(texts.onceFooter))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(""), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    pushImpl = { [weak controller] next in
        controller?.push(next)
    }
    return controller
}

// One connected computer: whether it is nearby, its bot, engine, folder, sessions, and «Disconnect»
