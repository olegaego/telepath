import Foundation
import UIKit
import Network
import CryptoKit
import Security
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
    var connectedHeader: String { ru ? "ПОДКЛЮЧЁННЫЕ" : "CONNECTED" }
    var notConnected: String { ru ? "ещё не подключён" : "not connected yet" }
    var emptyTitle: String { ru ? "Подключи компьютер" : "Connect a Computer" }
    var emptyText: String { ru ? "Агенты работают на твоём компьютере. Поставь на него Agentgram для компьютера и открой этот экран в той же Wi-Fi." : "Agents run on your computer. Install the Agentgram helper on it and open this screen on the same Wi-Fi." }
    var installMac: String { ru ? "Как поставить на Мак" : "How to Install on a Mac" }
    var installWindows: String { ru ? "Как поставить на Windows" : "How to Install on Windows" }
    var installSoon: String { ru ? "Готовая установка появится с выходом Agentgram. Пока помощник ставится вручную." : "A ready installer comes with the Agentgram release. For now the helper is installed by hand." }
    var nearbyNow: String { ru ? "в сети, рядом" : "online, nearby" }
    var notNearby: String { ru ? "не в этой сети" : "not on this network" }
    var agentHeader: String { ru ? "АГЕНТ" : "AGENT" }
    var openChat: String { ru ? "открыть чат" : "open chat" }
    var engineRow: String { ru ? "На чём работает" : "Runs On" }
    var projectsRow: String { ru ? "Папка проектов" : "Projects Folder" }
    var sessionsHeader: String { ru ? "СЕССИИ" : "SESSIONS" }
    var runningRow: String { ru ? "Сейчас работают" : "Working Now" }
    var topicsRow: String { ru ? "Всего тем" : "All Topics" }
    var disconnect: String { ru ? "Отключить компьютер" : "Disconnect Computer" }
    var disconnectFooter: String { ru ? "Помощник на компьютере забудет бота и токен. Сам бот и его чаты останутся." : "The helper on the computer forgets the bot and its token. The bot and its chats stay." }
    var disconnectFar: String { ru ? "Компьютер не в этой сети, поэтому он сам не узнает об отключении. Убрать его из списка? Чтобы помощник забыл токен, подключись к той же Wi-Fi или запусти на нём «agentgram-helper pair»." : "The computer is not on this network, so it will not learn about this. Remove it from the list? For the helper to forget the token, join the same Wi-Fi or run «agentgram-helper pair» on it." }
    var remove: String { ru ? "Убрать" : "Remove" }
    var tokenHeader: String { ru ? "ТОКЕН БОТА" : "BOT TOKEN" }
    var tokenPlaceholder: String { ru ? "123456789:AA…" : "123456789:AA…" }
    var tokenFooter: String { ru ? "Этот бот будет работать на компьютере: ты пишешь ему, отвечает агент. Токен возьми у @BotFather: /token → выбери бота → скопируй.\n\nТокен уходит только на этот компьютер, напрямую по твоей сети, зашифрованным ключом компьютера. На телефоне он не сохраняется. Код Agentgram открыт, это всегда можно проверить." : "This bot will work on the computer: you write to it, the agent answers. Get the token from @BotFather: /token → pick the bot → copy.\n\nThe token goes only to this computer, straight over your network, encrypted with the computer's key. It is not kept on the phone. Agentgram's code is open, you can always check this." }
    var engineHeader: String { ru ? "НА ЧЁМ РАБОТАЕТ" : "RUNS ON" }
    var connectButton: String { ru ? "Подключить" : "Connect" }
    var badToken: String { ru ? "Это не похоже на токен бота. Скопируй его у @BotFather целиком." : "This does not look like a bot token. Copy it whole from @BotFather." }
    var connecting: String { ru ? "Подключаю…" : "Connecting…" }
    func wrongToken(_ bot: String) -> String { ru ? "В буфере нет токена \(bot). Скопируй его у @BotFather и нажми «Вставить» ещё раз." : "The clipboard has no token of \(bot). Copy it in @BotFather and tap Paste again." }
}

struct NearbyComputer: Equatable {
    let name: String
    let publicKey: Data
    let endpoint: NWEndpoint
    var paired: Bool = false
    var bot: String? = nil

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
                found.append(NearbyComputer(name: name, publicKey: key, endpoint: result.endpoint, paired: txt["paired"] == "1", bot: txt["bot"]))
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

// The computers this phone connected, per account: name, key, bot, engine and the phone's secret for asking them later.
// The bot's token is not kept here.
struct ConnectedComputer: Codable, Equatable {
    var name: String
    var publicKey: Data
    var bot: String
    var engine: String
    var projects: String
    var secret: String
}

enum ConnectedComputers {
    private static func key(_ context: AccountContext) -> String {
        return "agentgram.computers.\(context.account.peerId.id._internalGetInt64Value())"
    }

    static let changed = ValuePromise<Int>(0, ignoreRepeated: false)

    static func all(_ context: AccountContext) -> [ConnectedComputer] {
        guard let data = UserDefaults.standard.data(forKey: key(context)) else {
            return []
        }
        return (try? JSONDecoder().decode([ConnectedComputer].self, from: data)) ?? []
    }

    static func save(_ context: AccountContext, _ computers: [ConnectedComputer]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(computers), forKey: key(context))
        changed.set(0)
    }

    static func add(_ context: AccountContext, _ computer: ConnectedComputer) {
        save(context, all(context).filter { $0.publicKey != computer.publicKey } + [computer])
    }

    static func remove(_ context: AccountContext, publicKey: Data) {
        save(context, all(context).filter { $0.publicKey != publicKey })
    }
}

// A request to a connected computer: the phone's secret and the time, sealed with the computer's key
func askComputer(_ endpoint: NWEndpoint, _ computer: ConnectedComputer, path: String, completion: @escaping ([String: Any]?) -> Void) {
    let request: [String: Any] = ["secret": computer.secret, "time": Int64(Date().timeIntervalSince1970)]
    guard let plain = try? JSONSerialization.data(withJSONObject: request), let sealed = sealForComputer(plain, publicKey: computer.publicKey) else {
        completion(nil)
        return
    }
    postToComputer(endpoint, path: path, body: base64UrlEncode(sealed), completion: { status, body in
        completion(status == 200 ? (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) : nil)
    })
}

private final class ComputersArguments {
    let connect: (NearbyComputer) -> Void
    let open: (ConnectedComputer) -> Void
    let install: () -> Void

    init(connect: @escaping (NearbyComputer) -> Void, open: @escaping (ConnectedComputer) -> Void, install: @escaping () -> Void) {
        self.connect = connect
        self.open = open
        self.install = install
    }
}

private enum ComputersEntry: ItemListNodeEntry {
    case emptyInfo(String, String)
    case installMac(String)
    case installWindows(String)
    case connectedHeader(String)
    case connected(Int32, ConnectedComputer, String)
    case nearbyHeader(String)
    case nearby(Int32, NearbyComputer, String)
    case searching(String)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .emptyInfo, .installMac, .installWindows:
            return 0
        case .connectedHeader, .connected:
            return 1
        case .nearbyHeader, .nearby, .searching, .footer:
            return 2
        }
    }

    var stableId: Int32 {
        switch self {
        case .emptyInfo: return 0
        case .installMac: return 1
        case .installWindows: return 2
        case .connectedHeader: return 3
        case let .connected(index, _, _): return 10 + index
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
        case let .emptyInfo(title, text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown("**\(title)**\n\n\(text)"), sectionId: self.section)
        case let .installMac(title), let .installWindows(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.install()
            })
        case let .connectedHeader(text), let .nearbyHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .connected(_, computer, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computersRowIcon, title: computer.name, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.open(computer)
            })
        case let .nearby(_, computer, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computersNearbyIcon, title: computer.name, label: label, sectionId: self.section, style: .blocks, action: {
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
private let computersNearbyIcon = renderSettingsIcon(name: "Item List/Icons/Devices", backgroundColors: [UIColor(rgb: 0x8E8E93)])

func agentgramComputersController(context: AccountContext) -> ViewController {
    let browser = ComputersBrowser()
    browser.start()
    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?

    let connect: (NearbyComputer) -> Void = { computer in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let texts = ComputersTexts(presentationData.strings)
        presentImpl?(textAlertController(context: context, title: texts.codeTitle(computer.name), text: texts.codeText(computer.code), actions: [
            TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: texts.matches, action: {
                pushImpl?(agentgramConnectComputerController(context: context, computer: computer))
            })
        ]))
    }
    let arguments = ComputersArguments(connect: connect, open: { computer in
        pushImpl?(agentgramComputerController(context: context, computer: computer, browser: browser))
    }, install: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let texts = ComputersTexts(presentationData.strings)
        presentImpl?(textAlertController(context: context, title: nil, text: texts.installSoon, actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]))
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, browser.computers.get(), ConnectedComputers.changed.get())
    |> map { presentationData, found, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = ComputersTexts(presentationData.strings)
        let connected = ConnectedComputers.all(context)
        let connectedKeys = Set(connected.map { $0.publicKey })
        let nearby = found.filter { !$0.paired && !connectedKeys.contains($0.publicKey) }
        var entries: [ComputersEntry] = []
        if connected.isEmpty {
            entries.append(.emptyInfo(texts.emptyTitle, texts.emptyText))
            entries.append(.installMac(texts.installMac))
            entries.append(.installWindows(texts.installWindows))
        } else {
            entries.append(.connectedHeader(texts.connectedHeader))
            for (i, computer) in connected.enumerated() {
                let engine = computer.engine == "codex" ? "Codex" : "Claude Code"
                entries.append(.connected(Int32(i), computer, "@\(computer.bot) · \(engine)"))
            }
        }
        entries.append(.nearbyHeader(texts.nearbyHeader))
        for (i, computer) in nearby.enumerated() {
            entries.append(.nearby(Int32(i), computer, texts.connect))
        }
        if nearby.isEmpty {
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
    pushImpl = { [weak controller] next in
        controller?.push(next)
    }
    return controller
}

// One connected computer: whether it is nearby, its bot, engine, folder, sessions, and «Disconnect»

private final class ComputerArguments {
    let openChat: () -> Void
    let disconnect: () -> Void

    init(openChat: @escaping () -> Void, disconnect: @escaping () -> Void) {
        self.openChat = openChat
        self.disconnect = disconnect
    }
}

private enum ComputerEntry: ItemListNodeEntry {
    case status(String)
    case agentHeader(String)
    case bot(String, String)
    case engine(String, String)
    case projects(String, String)
    case sessionsHeader(String)
    case running(String, String)
    case topics(String, String)
    case disconnect(String)
    case disconnectFooter(String)

    var section: ItemListSectionId {
        switch self {
        case .status: return 0
        case .agentHeader, .bot, .engine, .projects: return 1
        case .sessionsHeader, .running, .topics: return 2
        case .disconnect, .disconnectFooter: return 3
        }
    }

    var stableId: Int32 {
        switch self {
        case .status: return 0
        case .agentHeader: return 1
        case .bot: return 2
        case .engine: return 3
        case .projects: return 4
        case .sessionsHeader: return 5
        case .running: return 6
        case .topics: return 7
        case .disconnect: return 8
        case .disconnectFooter: return 9
        }
    }

    static func <(lhs: ComputerEntry, rhs: ComputerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ComputerArguments
        switch self {
        case let .status(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .agentHeader(text), let .sessionsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .bot(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: computersRowIcon, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.openChat()
            })
        case let .engine(title, label), let .projects(title, label), let .running(title, label), let .topics(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .disconnect(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.disconnect()
            })
        case let .disconnectFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

func agentgramComputerController(context: AccountContext, computer: ConnectedComputer, browser: ComputersBrowser) -> ViewController {
    let info = ValuePromise<[String: Any]?>(nil, ignoreRepeated: false)
    var asked = false
    var presentImpl: ((ViewController) -> Void)?
    var popImpl: (() -> Void)?
    var openChatImpl: (() -> Void)?
    let nearbyEndpoint: () -> NWEndpoint? = {
        var endpoint: NWEndpoint?
        let _ = (browser.computers.get() |> take(1)).start(next: { found in
            endpoint = found.first(where: { $0.publicKey == computer.publicKey })?.endpoint
        })
        return endpoint
    }

    let arguments = ComputerArguments(openChat: {
        openChatImpl?()
    }, disconnect: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let texts = ComputersTexts(presentationData.strings)
        if let endpoint = nearbyEndpoint() {
            askComputer(endpoint, computer, path: "/unpair", completion: { _ in
                ConnectedComputers.remove(context, publicKey: computer.publicKey)
                popImpl?()
            })
        } else {
            presentImpl?(textAlertController(context: context, title: texts.disconnect, text: texts.disconnectFar, actions: [
                TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: texts.remove, action: {
                    ConnectedComputers.remove(context, publicKey: computer.publicKey)
                    popImpl?()
                })
            ]))
        }
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, browser.computers.get(), info.get())
    |> map { presentationData, found, info -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let texts = ComputersTexts(presentationData.strings)
        let nearby = found.first(where: { $0.publicKey == computer.publicKey })
        if let nearby, !asked {
            asked = true
            askComputer(nearby.endpoint, computer, path: "/info", completion: { result in
                info.set(result)
            })
        }
        let engine = computer.engine == "codex" ? "Codex" : "Claude Code"
        var entries: [ComputerEntry] = [
            .status("● " + (nearby != nil ? texts.nearbyNow : texts.notNearby)),
            .agentHeader(texts.agentHeader),
            .bot("@" + computer.bot, texts.openChat),
            .engine(texts.engineRow, engine),
            .projects(texts.projectsRow, ((info?["projects"] as? String) ?? computer.projects).replacingOccurrences(of: "^(/Users|/home)/[^/]+", with: "~", options: .regularExpression))
        ]
        if let info {
            entries.append(.sessionsHeader(texts.sessionsHeader))
            entries.append(.running(texts.runningRow, "\((info["running"] as? Int) ?? 0)"))
            entries.append(.topics(texts.topicsRow, "\((info["topics"] as? Int) ?? 0)"))
        }
        entries.append(.disconnect(texts.disconnect))
        entries.append(.disconnectFooter(texts.disconnectFooter))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(computer.name), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
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
    openChatImpl = { [weak controller] in
        let _ = (context.engine.peers.resolvePeerByName(name: computer.bot, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            if case let .result(peer) = result {
                return .single(peer)
            }
            return .complete()
        }
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
                ConnectedComputers.add(context, ConnectedComputer(name: computer.name, publicKey: computer.publicKey, bot: botName, engine: state.engine, projects: (json["projects"] as? String) ?? "", secret: secret))
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
