import Foundation
import UIKit
import Network
import CryptoKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// Agentgram: «Computers». The Agentgram helper on a computer of the same network announces itself (Bonjour,
// _agentgram._tcp) with its public key. Here it is found and connected: both show the same 6-digit code made from
// that key, the user picks one of their bots and an engine, and the bot's token goes straight to the computer,
// sealed with its key. No server takes part.

private struct ComputersTexts {
    let ru: Bool

    init(_ strings: PresentationStrings) {
        self.ru = strings.primaryComponent.languageCode.hasPrefix("ru")
    }

    var title: String { ru ? "Компьютеры" : "Computers" }
    var nearbyHeader: String { ru ? "РЯДОМ, В ЭТОЙ СЕТИ" : "NEARBY, ON THIS NETWORK" }
    var searching: String { ru ? "Ищу…" : "Searching…" }
    var connect: String { ru ? "Подключить" : "Connect" }
    var footer: String { ru ? "Запусти Agentgram для компьютера на Маке или Windows в той же Wi-Fi. Он появится здесь. Подключиться нужно один раз, дальше одна сеть не нужна." : "Run the Agentgram helper on a Mac or Windows computer on the same Wi-Fi. It shows up here. You connect once; after that the same network is not needed." }
    func codeTitle(_ name: String) -> String { ru ? "Подключить «\(name)»" : "Connect \(name)" }
    func codeText(_ code: String) -> String { ru ? "Код на экране компьютера должен быть таким:\n\n\(code)\n\nСовпадает?" : "The code on the computer should be:\n\n\(code)\n\nDoes it match?" }
    var matches: String { ru ? "Совпадает" : "It Matches" }
    var cancel: String { ru ? "Отмена" : "Cancel" }
    var whichBot: String { ru ? "Какой бот будет работать на этом компьютере?" : "Which bot will work on this computer?" }
    var noBots: String { ru ? "У тебя нет своих ботов. Создай бота в @BotFather и вернись сюда." : "You have no bots. Create one in @BotFather and come back." }
    var whichEngine: String { ru ? "На чём он будет работать?" : "What will it run on?" }
    var done: String { ru ? "Подключено" : "Connected" }
    func doneText(_ bot: String, _ computer: String) -> String { ru ? "@\(bot) теперь работает на «\(computer)». Напиши ему." : "@\(bot) now works on \(computer). Write to it." }
    var failed: String { ru ? "Не вышло подключить" : "Could not connect" }
    func pasteTitle(_ bot: String) -> String { ru ? "Токен \(bot)" : "\(bot) Token" }
    func pasteText(_ bot: String) -> String { ru ? "Открой @BotFather, отправь /token, выбери \(bot) и скопируй токен. Потом вернись сюда и нажми «Вставить». Токен уйдёт только на этот компьютер, зашифрованным." : "Open @BotFather, send /token, pick \(bot) and copy the token. Then come back and tap Paste. The token goes only to this computer, encrypted." }
    var paste: String { ru ? "Вставить" : "Paste" }
    func wrongToken(_ bot: String) -> String { ru ? "В буфере нет токена \(bot). Скопируй его у @BotFather и нажми «Вставить» ещё раз." : "The clipboard has no token of \(bot). Copy it in @BotFather and tap Paste again." }
}

struct NearbyComputer: Equatable {
    let name: String
    let publicKey: Data
    let endpoint: NWEndpoint

    var code: String {
        var data = Data("agentgram pairing code".utf8)
        data.append(self.publicKey)
        let digest = Array(SHA256.hash(data: data))
        let value = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let text = String(format: "%06d", value)
        return String(text.prefix(3)) + " " + String(text.suffix(3))
    }
}

// Looks for helpers on the network while the screen is open
final class ComputersBrowser {
    private var browser: NWBrowser?
    let computers = ValuePromise<[NearbyComputer]>([], ignoreRepeated: true)

    func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_agentgram._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [NearbyComputer] = []
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint, case let .bonjour(txt) = result.metadata else {
                    continue
                }
                guard let pk = txt["pk"], let key = base64UrlDecode(pk), key.count == 65 else {
                    continue
                }
                found.append(NearbyComputer(name: name, publicKey: key, endpoint: result.endpoint))
            }
            self?.computers.set(found.sorted(by: { $0.name < $1.name }))
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        self.browser?.cancel()
        self.browser = nil
    }
}

// ECIES on P-256, the same as the helper opens it: ephemeral key (65) + AES-256-GCM (nonce, ciphertext, tag),
// the key from HKDF-SHA256 of the shared secret
func sealForComputer(_ plain: Data, publicKey: Data) -> Data? {
    guard let key = try? P256.KeyAgreement.PublicKey(x963Representation: publicKey) else {
        return nil
    }
    let ephemeral = P256.KeyAgreement.PrivateKey()
    guard let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: key) else {
        return nil
    }
    let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("agentgram pairing".utf8), outputByteCount: 32)
    guard let box = try? AES.GCM.seal(plain, using: symmetric), let combined = box.combined else {
        return nil
    }
    var result = ephemeral.publicKey.x963Representation
    result.append(combined)
    return result
}

// One HTTP request to the helper on the local network, over the Bonjour endpoint itself
func postToComputer(_ endpoint: NWEndpoint, path: String, body: String, completion: @escaping (Int, Data) -> Void) {
    let connection = NWConnection(to: endpoint, using: .tcp)
    var response = Data()
    var finished = false
    let finish: (Int, Data) -> Void = { status, data in
        if finished {
            return
        }
        finished = true
        connection.cancel()
        completion(status, data)
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data {
                response.append(data)
            }
            if isComplete || error != nil {
                let text = String(decoding: response, as: UTF8.self)
                let status = text.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
                let bodyData = text.range(of: "\r\n\r\n").map { Data(text[$0.upperBound...].utf8) } ?? Data()
                finish(status, bodyData)
            } else {
                receive()
            }
        }
    }
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            let bodyBytes = Data(body.utf8)
            let head = "POST \(path) HTTP/1.1\r\nHost: agentgram\r\nContent-Type: text/plain\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
            var request = Data(head.utf8)
            request.append(bodyBytes)
            connection.send(content: request, completion: .contentProcessed { _ in
                receive()
            })
        case .failed, .cancelled:
            finish(0, Data())
        default:
            break
        }
    }
    connection.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) {
        finish(0, Data())
    }
}

func base64UrlDecode(_ string: String) -> Data? {
    var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while value.count % 4 != 0 {
        value.append("=")
    }
    return Data(base64Encoded: value)
}

private func base64UrlEncode(_ data: Data) -> String {
    return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private final class ComputersArguments {
    let connect: (NearbyComputer) -> Void

    init(connect: @escaping (NearbyComputer) -> Void) {
        self.connect = connect
    }
}

private enum ComputersEntry: ItemListNodeEntry {
    case header(String)
    case computer(Int32, String, String, NearbyComputer)
    case searching(String)
    case footer(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int32 {
        switch self {
        case .header: return 0
        case let .computer(index, _, _, _): return 10 + index
        case .searching: return 1000
        case .footer: return 1001
        }
    }

    static func ==(lhs: ComputersEntry, rhs: ComputersEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a), .header(b)), let (.searching(a), .searching(b)), let (.footer(a), .footer(b)):
            return a == b
        case let (.computer(i1, n1, l1, c1), .computer(i2, n2, l2, c2)):
            return i1 == i2 && n1 == n2 && l1 == l2 && c1 == c2
        default:
            return false
        }
    }

    static func <(lhs: ComputersEntry, rhs: ComputersEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ComputersArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .computer(_, name, label, computer):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computersRowIcon, title: name, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.connect(computer)
            })
        case let .searching(text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, enabled: false, label: "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private let computersRowIcon = renderSettingsIcon(name: "Item List/Icons/Devices", backgroundColors: [UIColor(rgb: 0x5856D6)])

func agentgramComputersController(context: AccountContext) -> ViewController {
    let browser = ComputersBrowser()
    browser.start()
    var presentImpl: ((ViewController) -> Void)?

    let connect: (NearbyComputer) -> Void = { computer in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let texts = ComputersTexts(presentationData.strings)
        let fail: (String) -> Void = { text in
            presentImpl?(textAlertController(context: context, title: texts.failed, text: text, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]))
        }
        let send: (String, String) -> Void = { token, engine in
            let payload: [String: Any] = ["bot_token": token, "owner_id": context.account.peerId.id._internalGetInt64Value(), "engine": engine]
            guard let plain = try? JSONSerialization.data(withJSONObject: payload), let sealed = sealForComputer(plain, publicKey: computer.publicKey) else {
                fail("")
                return
            }
            postToComputer(computer.endpoint, path: "/pair", body: base64UrlEncode(sealed), completion: { status, body in
                if status == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let botName = json["bot"] as? String {
                    presentImpl?(textAlertController(context: context, title: texts.done, text: texts.doneText(botName, computer.name), actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]))
                } else {
                    fail(String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            })
        }
        let pickEngine: (String) -> Void = { token in
            let sheet = ActionSheetController(presentationData: presentationData)
            sheet.setItemGroups([
                ActionSheetItemGroup(items: [
                    ActionSheetTextItem(title: texts.whichEngine),
                    ActionSheetButtonItem(title: "Claude Code", action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        send(token, "claude")
                    }),
                    ActionSheetButtonItem(title: "Codex", action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        send(token, "codex")
                    })
                ]),
                ActionSheetItemGroup(items: [ActionSheetButtonItem(title: texts.cancel, color: .accent, font: .bold, action: { [weak sheet] in
                    sheet?.dismissAnimated()
                })])
            ])
            presentImpl?(sheet)
        }
        // The token is pasted by the owner, from @BotFather; it starts with the bot's id, so a wrong one is caught here
        var askTokenImpl: ((EnginePeer, String) -> Void)?
        let askToken: (EnginePeer, String) -> Void = { bot, title in
            askTokenImpl?(bot, title)
        }
        askTokenImpl = { bot, title in
            presentImpl?(textAlertController(context: context, title: texts.pasteTitle(title), text: texts.pasteText(title), actions: [
                TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
                TextAlertAction(type: .defaultAction, title: texts.paste, action: {
                    let clip = UIPasteboard.general.string ?? ""
                    let botId = "\(bot.id.id._internalGetInt64Value())"
                    if let range = clip.range(of: "[0-9]{6,12}:[A-Za-z0-9_-]{30,}", options: .regularExpression), clip[range].hasPrefix(botId + ":") {
                        pickEngine(String(clip[range]))
                    } else {
                        presentImpl?(textAlertController(context: context, title: texts.pasteTitle(title), text: texts.wrongToken(title), actions: [
                            TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
                            TextAlertAction(type: .defaultAction, title: texts.paste, action: {
                                askTokenImpl?(bot, title)
                            })
                        ]))
                    }
                })
            ]))
        }
        let pickBot: () -> Void = {
            let _ = (context.engine.peers.agentgramOwnedBots()
            |> deliverOnMainQueue).start(next: { bots in
                guard !bots.isEmpty else {
                    fail(texts.noBots)
                    return
                }
                let sheet = ActionSheetController(presentationData: presentationData)
                var items: [ActionSheetItem] = [ActionSheetTextItem(title: texts.whichBot)]
                for bot in bots.prefix(20) {
                    let title = bot.addressName.flatMap { "@" + $0 } ?? bot.compactDisplayTitle
                    items.append(ActionSheetButtonItem(title: title, action: { [weak sheet] in
                        sheet?.dismissAnimated()
                        askToken(bot, title)
                    }))
                }
                sheet.setItemGroups([
                    ActionSheetItemGroup(items: items),
                    ActionSheetItemGroup(items: [ActionSheetButtonItem(title: texts.cancel, color: .accent, font: .bold, action: { [weak sheet] in
                        sheet?.dismissAnimated()
                    })])
                ])
                presentImpl?(sheet)
            })
        }
        presentImpl?(textAlertController(context: context, title: texts.codeTitle(computer.name), text: texts.codeText(computer.code), actions: [
            TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: texts.matches, action: {
                pickBot()
            })
        ]))
    }

    let arguments = ComputersArguments(connect: connect)
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, browser.computers.get())
    |> map { presentationData, computers -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = ComputersTexts(presentationData.strings)
        var entries: [ComputersEntry] = [.header(texts.nearbyHeader)]
        for (i, computer) in computers.enumerated() {
            entries.append(.computer(Int32(i), computer.name, texts.connect, computer))
        }
        if computers.isEmpty {
            entries.append(.searching(texts.searching))
        }
        entries.append(.footer(texts.footer))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(texts.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        browser.stop()
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] next in
        controller?.present(next, in: .window(.root))
    }
    return controller
}
