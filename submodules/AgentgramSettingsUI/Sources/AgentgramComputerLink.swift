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

// The link to the computers: found on the network (Bonjour), the requests sealed with a computer's key, the computers
// and agents this phone connected

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

// One search for helpers on the network for the whole app, from its start: the statuses, the Agentgram section and
// the new computer's screen all read it
let agentgramBrowser: ComputersBrowser = {
    let browser = ComputersBrowser()
    browser.start()
    return browser
}()

// Looks for helpers on the network
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

func base64UrlEncode(_ data: Data) -> String {
    return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

// What this phone connected, per account: the computers (name, key, and the phone's secret for asking them later)
// and the agents on them (a bot and its engine). A computer goes with its last agent. Bots' tokens are not kept here.
struct PairedComputer: Codable, Equatable {
    var name: String
    var publicKey: Data
    var secret: String
}

struct PairedAgent: Codable, Equatable {
    var publicKey: Data
    var bot: String
    var engine: String
}

// An agent with its computer, as the screens and the requests use it
struct ConnectedComputer: Equatable {
    var name: String
    var publicKey: Data
    var bot: String
    var engine: String
    var secret: String
}

enum ConnectedComputers {
    private struct Stored: Codable {
        var computers: [PairedComputer] = []
        var agents: [PairedAgent] = []
    }

    // the records of before: one per agent, the computer's name and secret in each
    private struct OldRecord: Codable {
        var name: String
        var publicKey: Data
        var bot: String
        var engine: String
        var secret: String
    }

    private static func key(_ context: AccountContext) -> String {
        return "agentgram.paired.\(context.account.peerId.id._internalGetInt64Value())"
    }

    private static func oldKey(_ context: AccountContext) -> String {
        return "agentgram.computers.\(context.account.peerId.id._internalGetInt64Value())"
    }

    static let changed = ValuePromise<Int>(0, ignoreRepeated: false)

    private static func load(_ context: AccountContext) -> Stored {
        if let data = UserDefaults.standard.data(forKey: key(context)), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            return stored
        }
        var stored = Stored()
        if let data = UserDefaults.standard.data(forKey: oldKey(context)), let old = try? JSONDecoder().decode([OldRecord].self, from: data) {
            for record in old {
                if !stored.computers.contains(where: { $0.publicKey == record.publicKey }) {
                    stored.computers.append(PairedComputer(name: record.name, publicKey: record.publicKey, secret: record.secret))
                }
                stored.agents.append(PairedAgent(publicKey: record.publicKey, bot: record.bot, engine: record.engine))
            }
            // the old records stay as they were: a copy to go back to
            store(context, stored)
        }
        return stored
    }

    private static func store(_ context: AccountContext, _ stored: Stored) {
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: key(context))
        changed.set(0)
    }

    static func all(_ context: AccountContext) -> [ConnectedComputer] {
        let stored = load(context)
        return stored.agents.compactMap { agent in
            guard let computer = stored.computers.first(where: { $0.publicKey == agent.publicKey }) else {
                return nil
            }
            return ConnectedComputer(name: computer.name, publicKey: computer.publicKey, bot: agent.bot, engine: agent.engine, secret: computer.secret)
        }
    }

    // each computer once, with its first agent
    static func computers(_ context: AccountContext) -> [ConnectedComputer] {
        var seen = Set<Data>()
        return all(context).filter { seen.insert($0.publicKey).inserted }
    }

    static func add(_ context: AccountContext, _ record: ConnectedComputer) {
        var stored = load(context)
        stored.computers.removeAll(where: { $0.publicKey == record.publicKey })
        stored.computers.append(PairedComputer(name: record.name, publicKey: record.publicKey, secret: record.secret))
        stored.agents.removeAll(where: { $0.publicKey == record.publicKey && $0.bot.lowercased() == record.bot.lowercased() })
        stored.agents.append(PairedAgent(publicKey: record.publicKey, bot: record.bot, engine: record.engine))
        store(context, stored)
    }

    static func remove(_ context: AccountContext, publicKey: Data, bot: String) {
        var stored = load(context)
        stored.agents.removeAll(where: { $0.publicKey == publicKey && $0.bot.lowercased() == bot.lowercased() })
        if !stored.agents.contains(where: { $0.publicKey == publicKey }) {
            stored.computers.removeAll(where: { $0.publicKey == publicKey })
        }
        store(context, stored)
    }
}

// A request to a connected computer: the phone's secret and the time, sealed with the computer's key
func askComputer(_ endpoint: NWEndpoint, _ computer: ConnectedComputer, path: String, extra: [String: Any] = [:], completion: @escaping ([String: Any]?) -> Void) {
    // «bot»: which of the computer's agents the request is about
    var request: [String: Any] = ["secret": computer.secret, "time": Int64(Date().timeIntervalSince1970), "bot": computer.bot]
    for (key, value) in extra {
        request[key] = value
    }
    guard let plain = try? JSONSerialization.data(withJSONObject: request), let sealed = sealForComputer(plain, publicKey: computer.publicKey) else {
        completion(nil)
        return
    }
    postToComputer(endpoint, path: path, body: base64UrlEncode(sealed), completion: { status, body in
        completion(status == 200 ? (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) : nil)
    })
}

// Tapping a computer found nearby: the code to compare, then the bot's token; one already connected elsewhere says how
// to free it
func agentgramConnectNearby(context: AccountContext, computer: NearbyComputer, present: @escaping (ViewController) -> Void, push: @escaping (ViewController) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let texts = ComputersTexts(presentationData.strings)
    if computer.paired {
        present(textAlertController(context: context, title: computer.name, text: texts.takenText(computer.bot ?? ""), actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]))
        return
    }
    present(textAlertController(context: context, title: texts.codeTitle(computer.name), text: texts.codeText(computer.code), actions: [
        TextAlertAction(type: .genericAction, title: texts.cancel, action: {}),
        TextAlertAction(type: .defaultAction, title: texts.matches, action: {
            push(agentgramConnectComputerController(context: context, computer: computer))
        })
    ]))
}

// A peer by its username, once it is resolved (a bot of an agent, @BotFather)
func agentgramPeer(_ context: AccountContext, username: String) -> Signal<EnginePeer?, NoError> {
    return context.engine.peers.resolvePeerByName(name: username, referrer: nil)
    |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
        if case let .result(peer) = result {
            return .single(peer)
        }
        return .complete()
    }
    |> take(1)
}
