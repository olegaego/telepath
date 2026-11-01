import Foundation
import UIKit
import SwiftSignalKit
import AccountContext

// «Чат-бот»: an agent with no computer. The phone itself reads the bot's messages (Bot API, long polling) while
// Telepath is open and answers with a model from OpenRouter. The bot's token and the OpenRouter key stay on this
// phone: they go only to api.telegram.org and openrouter.ai. Only the account's owner is answered.

public struct AgentgramChatBot: Codable, Equatable {
    public var bot: String
    var token: String
    var key: String
    var model: String
}

// The models offered when adding a chat bot, the first is the default
let agentgramChatModels: [(id: String, name: String)] = [
    ("qwen/qwen3.8-flash", "Qwen 3.8 Flash"),
    ("deepseek/deepseek-v4-flash", "DeepSeek V4 Flash"),
    ("google/gemini-3.8-flash", "Gemini 3.8 Flash"),
    ("moonshotai/kimi-k3", "Kimi K3"),
    ("openai/gpt-6.1-sol", "GPT-6.1 Sol")
]

func agentgramChatModelName(_ id: String) -> String {
    return agentgramChatModels.first(where: { $0.id == id })?.name ?? id
}

public enum AgentgramChatBots {
    static let changed = ValuePromise<Int>(0, ignoreRepeated: false)

    private static func key(_ context: AccountContext) -> String {
        return "agentgram.chatbots.\(context.account.peerId.id._internalGetInt64Value())"
    }

    public static func all(_ context: AccountContext) -> [AgentgramChatBot] {
        guard let data = UserDefaults.standard.data(forKey: key(context)), let bots = try? JSONDecoder().decode([AgentgramChatBot].self, from: data) else {
            return []
        }
        return bots
    }

    private static func store(_ context: AccountContext, _ bots: [AgentgramChatBot]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(bots), forKey: key(context))
        changed.set(0)
    }

    static func put(_ context: AccountContext, _ bot: AgentgramChatBot) {
        var bots = all(context).filter { $0.bot.lowercased() != bot.bot.lowercased() }
        bots.append(bot)
        store(context, bots)
    }

    static func remove(_ context: AccountContext, bot: String) {
        store(context, all(context).filter { $0.bot.lowercased() != bot.lowercased() })
        ChatBotHistory.forget(bot: bot)
    }
}

// MARK: - Bot API and OpenRouter

private func postJSON(_ url: String, _ body: [String: Any], headers: [String: String] = [:], timeout: TimeInterval, completion: @escaping ([String: Any]?) -> Void) -> URLSessionDataTask? {
    guard let url = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: body) else {
        completion(nil)
        return nil
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    let task = URLSession.shared.dataTask(with: request, completionHandler: { data, _, _ in
        completion(data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    })
    task.resume()
    return task
}

@discardableResult
func agentgramBotCall(_ token: String, _ method: String, _ params: [String: Any], timeout: TimeInterval = 20.0, completion: @escaping ([String: Any]?) -> Void = { _ in }) -> URLSessionDataTask? {
    return postJSON("https://api.telegram.org/bot\(token)/\(method)", params, timeout: timeout, completion: completion)
}

// Checks an OpenRouter key: true when OpenRouter knows it
func agentgramCheckOpenRouterKey(_ key: String, completion: @escaping (Bool) -> Void) {
    guard let url = URL(string: "https://openrouter.ai/api/v1/key") else {
        completion(false)
        return
    }
    var request = URLRequest(url: url, timeoutInterval: 20.0)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: request, completionHandler: { _, response, _ in
        completion((response as? HTTPURLResponse)?.statusCode == 200)
    }).resume()
}

private let chatSystemPrompt = "You are a chat bot in Telegram. Answer briefly and to the point, in the language of the person you talk to."

private func openRouterAnswer(key: String, model: String, messages: [[String: String]], completion: @escaping (String?, String?) -> Void) {
    let body: [String: Any] = ["model": model, "messages": [["role": "system", "content": chatSystemPrompt]] + messages]
    let _ = postJSON("https://openrouter.ai/api/v1/chat/completions", body, headers: ["Authorization": "Bearer \(key)"], timeout: 120.0, completion: { result in
        if let error = (result?["error"] as? [String: Any])?["message"] as? String {
            completion(nil, error)
            return
        }
        let choices = result?["choices"] as? [[String: Any]]
        let text = ((choices?.first?["message"] as? [String: Any])?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        completion(text.isEmpty ? nil : text, text.isEmpty ? "empty answer" : nil)
    })
}

// Each chat's last 40 messages, in a file on the phone
private enum ChatBotHistory {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("agentgram-chatbots", isDirectory: true)
    }

    private static func file(bot: String, chat: String) -> URL {
        return folder.appendingPathComponent("\(bot.lowercased())-\(chat).json")
    }

    static func load(bot: String, chat: String) -> [[String: String]] {
        guard let data = try? Data(contentsOf: file(bot: bot, chat: chat)), let messages = try? JSONDecoder().decode([[String: String]].self, from: data) else {
            return []
        }
        return messages
    }

    static func save(bot: String, chat: String, _ messages: [[String: String]]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(messages.suffix(40))).write(to: file(bot: bot, chat: chat), options: .atomic)
    }

    static func forget(bot: String) {
        let prefix = bot.lowercased() + "-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

// MARK: - The bot, run from the phone

private final class ChatBotRunner {
    let bot: AgentgramChatBot
    let owner: Int64
    private let queue = DispatchQueue(label: "agentgram.chatbot")
    private var running = false
    private var offset: Int64 = 0
    private var task: URLSessionDataTask?

    init(bot: AgentgramChatBot, owner: Int64) {
        self.bot = bot
        self.owner = owner
    }

    func start() {
        self.queue.async {
            if self.running {
                return
            }
            self.running = true
            self.poll()
        }
    }

    func stop() {
        self.queue.async {
            self.running = false
            self.task?.cancel()
            self.task = nil
        }
    }

    private func poll() {
        guard self.running else {
            return
        }
        self.task = agentgramBotCall(self.bot.token, "getUpdates", ["offset": self.offset, "timeout": 25, "allowed_updates": ["message"]], timeout: 35.0, completion: { [weak self] result in
            guard let self else {
                return
            }
            self.queue.async {
                guard self.running else {
                    return
                }
                guard result?["ok"] as? Bool == true, let updates = result?["result"] as? [[String: Any]] else {
                    // no network, or the bot is read elsewhere too (409): try again a bit later
                    self.queue.asyncAfter(deadline: .now() + 5.0, execute: { self.poll() })
                    return
                }
                for update in updates {
                    if let id = (update["update_id"] as? NSNumber)?.int64Value {
                        self.offset = max(self.offset, id + 1)
                    }
                    if let message = update["message"] as? [String: Any] {
                        self.handle(message)
                    }
                }
                self.poll()
            }
        })
    }

    private func handle(_ message: [String: Any]) {
        guard let from = (message["from"] as? [String: Any])?["id"] as? NSNumber, from.int64Value == self.owner else {
            return
        }
        guard let chat = (message["chat"] as? [String: Any])?["id"] as? NSNumber, let text = message["text"] as? String, !text.isEmpty else {
            return
        }
        let thread = (message["message_thread_id"] as? NSNumber)?.int64Value
        let historyKey = thread.map { "\(chat.int64Value)-\($0)" } ?? "\(chat.int64Value)"
        var place: [String: Any] = ["chat_id": chat.int64Value]
        if let thread {
            place["message_thread_id"] = thread
        }
        if text == "/start" {
            return
        }
        agentgramBotCall(self.bot.token, "sendChatAction", place.merging(["action": "typing"], uniquingKeysWith: { $1 }))
        var history = ChatBotHistory.load(bot: self.bot.bot, chat: historyKey)
        history.append(["role": "user", "content": text])
        let bot = self.bot
        openRouterAnswer(key: bot.key, model: bot.model, messages: Array(history.suffix(40)), completion: { answer, error in
            if let answer {
                history.append(["role": "assistant", "content": answer])
                ChatBotHistory.save(bot: bot.bot, chat: historyKey, history)
            }
            let reply = answer ?? "OpenRouter: \(error ?? "no answer")"
            agentgramBotCall(bot.token, "sendMessage", place.merging(["text": String(reply.prefix(4096))], uniquingKeysWith: { $1 }))
        })
    }
}

// Runs the account's chat bots while Telepath is in front, stops them when it goes to the background
private final class ChatBotsService {
    private let context: AccountContext
    private var runners: [String: ChatBotRunner] = [:]
    private var active = UIApplication.shared.applicationState == .active
    private var disposable: Disposable?
    private var observers: [NSObjectProtocol] = []

    init(context: AccountContext) {
        self.context = context
        self.disposable = (AgentgramChatBots.changed.get() |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.sync()
        })
        self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.active = true
            self?.sync()
        }))
        self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.active = false
            self?.sync()
        }))
    }

    private func sync() {
        let bots = self.active ? AgentgramChatBots.all(self.context) : []
        let owner = self.context.account.peerId.id._internalGetInt64Value()
        for (name, runner) in self.runners where !bots.contains(runner.bot) {
            runner.stop()
            self.runners[name] = nil
        }
        for bot in bots where self.runners[bot.bot] == nil {
            let runner = ChatBotRunner(bot: bot, owner: owner)
            self.runners[bot.bot] = runner
            runner.start()
        }
    }
}

private var chatBotsServices: [Int64: ChatBotsService] = [:]

public func agentgramStartChatBots(context: AccountContext) {
    let id = context.account.peerId.id._internalGetInt64Value()
    if chatBotsServices[id] == nil {
        chatBotsServices[id] = ChatBotsService(context: context)
    }
}
