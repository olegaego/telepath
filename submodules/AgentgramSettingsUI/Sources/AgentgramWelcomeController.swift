import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import AppBundle

// The first time the Agentgram section is opened: what agents can do on the computer, that the owner answers for it,
// that the code is open, and «as is». Until it is accepted, the section stays closed. «Не сейчас» goes back.

private let acceptedKey = "agentgram.disclaimer.accepted"

private struct WelcomeTexts {
    let ru: Bool

    init(_ strings: PresentationStrings) {
        self.ru = strings.primaryComponent.languageCode.hasPrefix("ru")
    }

    var subtitle: String { ru ? "Прежде чем начать" : "Before You Start" }
    var points: [(String, UInt32, String)] {
        return [
            ("desktopcomputer", 0x5856D6, ru ? "Агенты работают на твоём компьютере и могут делать там всё: читать и менять файлы, запускать программы, ходить в интернет." : "Agents work on your computer and can do anything there: read and change files, run programs, go online."),
            ("exclamationmark.triangle.fill", 0xFF9500, ru ? "Агенты ошибаются. Они могут удалить или испортить файлы и сделать то, чего ты не просил." : "Agents make mistakes. They can delete or damage files and do what you did not ask."),
            ("person.fill", 0x34C759, ru ? "Ты сам решаешь, что им поручать и кому давать доступ, и отвечаешь за это сам." : "You decide what to give them and whom to let in, and you answer for it yourself."),
            ("lock.open.fill", 0x2AABEE, ru ? "Код Telepath открыт. Мы не получаем и не читаем твои сообщения, у нас нет доступа к твоим паролям, и Telepath нигде их не просит. Это можно проверить в коде." : "Telepath's code is open. We do not get or read your messages, we have no access to your passwords, and Telepath never asks for them. You can check this in the code."),
            ("doc.text.fill", 0x8E8E93, ru ? "Telepath дан как есть, без гарантий. Авторы не отвечают за потерю данных и другой вред от его использования." : "Telepath is provided as is, without warranty. The authors are not liable for lost data or other harm from using it.")
        ]
    }
    var accept: String { ru ? "Принимаю" : "Accept" }
    var notNow: String { ru ? "Не сейчас" : "Not Now" }
}

private let logo: UIImage? = {
    guard let image = UIImage(bundleImageName: "AgentgramIntroIcon") else {
        return nil
    }
    let size = CGSize(width: 76.0, height: 76.0)
    return generateImage(size, rotatedContext: { canvas, context in
        context.clear(CGRect(origin: CGPoint(), size: canvas))
        context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: canvas), cornerRadius: canvas.width * 0.226).cgPath)
        context.clip()
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: CGPoint(), size: canvas))
        UIGraphicsPopContext()
    })
}()

private final class WelcomeArguments {
    let accept: () -> Void
    let notNow: () -> Void

    init(accept: @escaping () -> Void, notNow: @escaping () -> Void) {
        self.accept = accept
        self.notNow = notNow
    }
}

private enum WelcomeEntry: ItemListNodeEntry {
    case header(String)
    case point(Int32, String, UInt32, String)
    case buttons(String, String)

    var section: ItemListSectionId {
        switch self {
        case .header: return 0
        case .point: return 1
        case .buttons: return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case let .point(index, _, _, _): return 10 + index
        case .buttons: return 100
        }
    }

    static func <(lhs: WelcomeEntry, rhs: WelcomeEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WelcomeArguments
        switch self {
        case let .header(subtitle):
            return AgentgramComputerHeaderItem(theme: presentationData.theme, iconColor: .clear, iconSize: 76.0, title: "Telepath", status: subtitle, image: logo, sectionId: self.section)
        case let .point(_, symbol, color, text):
            let attributed = NSAttributedString(string: text, attributes: [.font: Font.regular(presentationData.fontSize.itemListBaseFontSize - 1.0), .foregroundColor: presentationData.theme.list.itemPrimaryTextColor])
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: agentgramSymbolTile(symbol, color), title: "", attributedTitle: attributed, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .buttons(title, secondaryTitle):
            return AgentgramWelcomeButtonsItem(theme: presentationData.theme, title: title, secondaryTitle: secondaryTitle, action: arguments.accept, secondaryAction: arguments.notNow, sectionId: self.section)
        }
    }
}

private func agentgramWelcomeController(context: AccountContext, accepted: @escaping (ViewController) -> Void) -> ViewController {
    var controllerRef: (() -> ViewController?)?
    let arguments = WelcomeArguments(accept: {
        UserDefaults.standard.set(true, forKey: acceptedKey)
        if let controller = controllerRef?() {
            accepted(controller)
        }
    }, notNow: {
        let _ = controllerRef?()?.navigationController?.popViewController(animated: true)
    })
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = WelcomeTexts(presentationData.strings)
        var entries: [WelcomeEntry] = [.header(texts.subtitle)]
        for (i, point) in texts.points.enumerated() {
            entries.append(.point(Int32(i), point.0, point.1, point.2))
        }
        entries.append(.buttons(texts.accept, texts.notNow))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(""), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    controllerRef = { [weak controller] in
        return controller
    }
    return controller
}

// The Agentgram section, behind the first-run screen until it is accepted
public func agentgramSettingsEntry(context: AccountContext) -> ViewController {
    if UserDefaults.standard.bool(forKey: acceptedKey) {
        return agentgramSettingsController(context: context)
    }
    return agentgramWelcomeController(context: context, accepted: { welcome in
        guard let navigationController = welcome.navigationController as? NavigationController else {
            return
        }
        navigationController.replaceController(welcome, with: agentgramSettingsController(context: context), animated: true)
    })
}
