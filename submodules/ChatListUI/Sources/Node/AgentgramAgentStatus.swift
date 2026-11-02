import Foundation
import SwiftSignalKit
import TelegramCore

// Agentgram: what each agent session is doing right now, shown the way Telegram shows «typing…»: the session's row
// in the chat list says «Running a command · 8 min» in place of the last message.
public enum AgentgramAgentStatus {
    public struct Session: Equatable {
        public var bot: EnginePeer.Id
        public var thread: Int64
        public var state: String
        public var detail: String
        public var since: Int32
        public var queued: Int
        public var model: String?
        public var steps: [Step] = []
        // tokens of the session's context: used of max
        public var context: (used: Int, max: Int)?

        public init(bot: EnginePeer.Id, thread: Int64, state: String, detail: String, since: Int32, queued: Int, model: String?) {
            self.bot = bot
            self.thread = thread
            self.state = state
            self.detail = detail
            self.since = since
            self.queued = queued
            self.model = model
        }

        public static func ==(lhs: Session, rhs: Session) -> Bool {
            return lhs.bot == rhs.bot && lhs.thread == rhs.thread && lhs.state == rhs.state && lhs.detail == rhs.detail && lhs.since == rhs.since && lhs.queued == rhs.queued && lhs.model == rhs.model && lhs.steps == rhs.steps && lhs.context?.used == rhs.context?.used && lhs.context?.max == rhs.context?.max
        }

        // a turn goes; «idle» is a session where nothing runs now
        public var working: Bool {
            return state != "waiting_you" && state != "error" && state != "idle"
        }
    }

    public struct Step: Equatable {
        public var state: String
        public var detail: String
        public var secs: Int

        public init(state: String, detail: String, secs: Int) {
            self.state = state
            self.detail = detail
            self.secs = secs
        }
    }

    // the engine's limits from the computer nearby: percent used and when they reset
    public struct Limit: Equatable {
        public var pct: Int
        public var resetsAt: Int32?

        public init(pct: Int, resetsAt: Int32?) {
            self.pct = pct
            self.resetsAt = resetsAt
        }
    }
    // the limits of each engine («Claude Code», «Codex») by window («5h», «week»): a session shows its own engine's
    // Read from any queue (chat history is built off the main one), written on the main one: kept behind a lock
    private static let limitsValue = Atomic<[String: [String: Limit]]>(value: [:])
    public static var limits: [String: [String: Limit]] {
        get { return limitsValue.with { $0 } }
        set { let _ = limitsValue.swap(newValue) }
    }
    // the engine each agent works on now: a topic that has not answered yet shows it
    private static let enginesValue = Atomic<[EnginePeer.Id: String]>(value: [:])
    public static var engines: [EnginePeer.Id: String] {
        get { return enginesValue.with { $0 } }
        set { let _ = enginesValue.swap(newValue) }
    }

    public static func fiveHour(_ engine: String?) -> Limit? {
        return limits[engine ?? "Claude Code"]?["5h"]
    }

    public static func week(_ engine: String?) -> Limit? {
        return limits[engine ?? "Claude Code"]?["week"]
    }

    // Codex on the free plan has a month instead
    public static func month(_ engine: String?) -> Limit? {
        return limits[engine ?? "Claude Code"]?["month"]
    }

    // how a status is drawn: a process (the typing dots), a settled line, an error (red)
    public enum Kind {
        case working
        case settled
        case error
    }

    // The two sources. Away from home: the bot's own messages in each topic (its draft «… step», a question, «Ошибка»,
    // the answer), which reach the phone through Telegram anyway. On the same Wi-Fi: the helper itself, every step at
    // once (set from Agentgram's settings module, which knows the connected computers). Nothing goes to any server of ours.
    private static var account: Account?
    private static var botsDisposable: Disposable?
    private static var nearbyDisposable: Disposable?
    private static var fromMessages: [Session] = []
    private static var fromDrafts: [Session] = []
    private static var draftsDisposable: Disposable?
    // when each topic's draft appeared: the «2 min» counts from it
    private static var draftSince: [String: Int32] = [:]
    private static var fromNearby: [Session] = []
    private static let agentBotsValue = Atomic<Set<EnginePeer.Id>>(value: Set())
    public private(set) static var agentBots: Set<EnginePeer.Id> {
        get { return agentBotsValue.with { $0 } }
        set { let _ = agentBotsValue.swap(newValue) }
    }
    private static var stopNearby: ((EnginePeer.Id, Int64) -> Bool)?

    private static let sessionsPromise = ValuePromise<[Session]>([], ignoreRepeated: false)   // every second: the «8 s» keeps counting
    private static var timer: SwiftSignalKit.Timer?
    private static let lastValue = Atomic<[Session]>(value: [])
    public private(set) static var last: [Session] {
        get { return lastValue.with { $0 } }
        set { let _ = lastValue.swap(newValue) }
    }

    public static var sessions: Signal<[Session], NoError> {
        return sessionsPromise.get()
    }

    public static func isAgent(_ peerId: EnginePeer.Id) -> Bool {
        return agentBots.contains(peerId)
    }

    // Agentgram's settings module tells which bots are agents, what the computers nearby say, and how to stop a turn there
    public static func configure(account: Account, bots: Signal<[EnginePeer.Id], NoError>, nearby: Signal<[Session], NoError>, stopNearby: @escaping (EnginePeer.Id, Int64) -> Bool) {
        self.account = account
        self.stopNearby = stopNearby
        botsDisposable?.dispose()
        botsDisposable = (bots
        |> distinctUntilChanged
        |> mapToSignal { botIds -> Signal<[Session], NoError> in
            Queue.mainQueue().async {
                agentBots = Set(botIds)
            }
            if botIds.isEmpty {
                return .single([])
            }
            return combineLatest(botIds.map { botId in
                chatListViewForLocationPlain(chatListLocation: .forum(peerId: botId), location: .initial(count: 50, filter: nil), account: account, shouldLoadCanMessagePeer: false)
                |> map { update -> [Session] in
                    return update.list.items.compactMap { topic -> Session? in
                        guard case let .forum(threadId) = topic.id, let message = topic.messages.last else {
                            return nil
                        }
                        return sessionFromMessage(message, bot: botId, thread: threadId)
                    }
                }
            })
            |> map { lists in lists.flatMap { $0 } }
        }
        |> deliverOnMainQueue).start(next: { value in
            fromMessages = value
            publish()
        })
        // the helper streams a session's steps away from home as the bot's live draft in the topic: Telegram keeps it
        // nowhere, Agentgram reads it here and hides it in the chat
        draftsDisposable?.dispose()
        draftsDisposable = (bots
        |> distinctUntilChanged
        |> mapToSignal { botIds -> Signal<[EnginePeer.Id: [Int64: String]], NoError> in
            return TelegramEngine(account: account).messages.agentgramLiveDrafts(peerIds: Set(botIds))
        }
        |> deliverOnMainQueue).start(next: { drafts in
            var sessions: [Session] = []
            var seen = Set<String>()
            let now = Int32(Date().timeIntervalSince1970)
            for (bot, threads) in drafts {
                for (thread, text) in threads {
                    let key = "\(bot.id._internalGetInt64Value()):\(thread)"
                    seen.insert(key)
                    let since = draftSince[key] ?? now
                    draftSince[key] = since
                    if var session = sessionFromDraft(text, bot: bot, thread: thread) {
                        session.since = since
                        sessions.append(session)
                    }
                }
            }
            draftSince = draftSince.filter { seen.contains($0.key) }
            fromDrafts = sessions
            publish()
        })
        nearbyDisposable?.dispose()
        nearbyDisposable = (nearby |> deliverOnMainQueue).start(next: { value in
            fromNearby = value
            publish()
        })
    }

    // Telegram's own «typing…» of an agent's bot in a topic: the session works, even with nothing else telling it
    // (statuses off, away from home); it ends a few seconds after the last «typing…»
    private static var typing: [String: (session: Session, seen: Double)] = [:]

    public static func noteTyping(bot: EnginePeer.Id, thread: Int64) {
        guard agentBots.contains(bot) else {
            return
        }
        let key = "\(bot.id._internalGetInt64Value()):\(thread)"
        let now = CFAbsoluteTimeGetCurrent()
        if let current = typing[key] {
            typing[key] = (current.session, now)
        } else {
            // «typing»: the session works (the panel with «СТОП»), but the words stay Telegram's own «typing…»
            let since = Int32(Date().timeIntervalSince1970)
            // the bot has already answered in that topic: publish() would drop this at once, and the chat that told
            // us about the typing would tell us again, round and round until the stack ends
            if fromMessages.contains(where: { $0.bot == bot && $0.thread == thread && $0.since >= since && !$0.working }) {
                return
            }
            typing[key] = (Session(bot: bot, thread: thread, state: "typing", detail: "", since: since, queued: 0, model: nil), now)
            publish()
        }
    }

    // the computer nearby knows best; then a topic that types; for the rest, what the bot's messages say
    private static var publishing = false

    private static func publish() {
        // the subscribers run inside sessionsPromise.set and may ask to publish again: not from inside
        if publishing {
            return
        }
        publishing = true
        defer { publishing = false }
        let now = CFAbsoluteTimeGetCurrent()
        typing = typing.filter { now - $0.value.seen < 7.0 }
        // the bot answered in that topic after it started typing: the turn is over, now
        typing = typing.filter { _, value in
            !fromMessages.contains(where: { $0.bot == value.session.bot && $0.thread == value.session.thread && $0.since >= value.session.since && !$0.working })
        }
        var merged = fromNearby
        for session in fromDrafts where !merged.contains(where: { $0.bot == session.bot && $0.thread == session.thread }) {
            merged.append(session)
        }
        for (_, value) in typing where !merged.contains(where: { $0.bot == value.session.bot && $0.thread == value.session.thread }) {
            merged.append(value.session)
        }
        for session in fromMessages where !merged.contains(where: { $0.bot == session.bot && $0.thread == session.thread }) {
            merged.append(session)
        }
        last = merged
        sessionsPromise.set(merged)
    }

    // says what it knows every second, so «8 s» counts one by one
    public static func start() {
        if timer != nil {
            return
        }
        let tick = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: {
            if typing.isEmpty {
                sessionsPromise.set(last)
            } else {
                publish()
            }
        }, queue: Queue.mainQueue())
        timer = tick
        tick.start()
    }

    // The helper's messages, read as a status: its draft (steps, the last one «… »), «Закончу текущее» (queued),
    // «Ошибка: …», a question or buttons (waits for you), else the topic rests
    static func sessionFromMessage(_ message: EngineMessage, bot: EnginePeer.Id, thread: Int64) -> Session? {
        guard message.author?.id == bot else {
            return nil
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var session = Session(bot: bot, thread: thread, state: "idle", detail: "", since: message.timestamp, queued: 0, model: nil)
        if let steps = parseSteps(text), let current = steps.last {
            (session.state, session.detail) = (current.state, current.detail)
            session.steps = steps
        } else if text == "Закончу текущее и возьмусь." {
            session.state = "thinking"
            session.queued = 1
        } else if text.hasPrefix("Ошибка:") {
            session.state = "error"
            session.detail = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces).components(separatedBy: "\n").first ?? ""
        } else if message.attributes.contains(where: { $0 is ReplyMarkupMessageAttribute }) || text.hasSuffix("?") {
            session.state = "waiting_you"
        }
        return session
    }

    // The helper's live draft: its steps, the current one «… »
    static func sessionFromDraft(_ text: String, bot: EnginePeer.Id, thread: Int64) -> Session? {
        guard let steps = parseSteps(text), let current = steps.last else {
            return nil
        }
        var session = Session(bot: bot, thread: thread, state: current.state, detail: current.detail, since: 0, queued: 0, model: engines[bot])
        session.steps = steps
        return session
    }

    // The helper's steps: a line per step, «✓ » done, the last one «… » going now; nil for any other text
    static func parseSteps(_ text: String) -> [Step]? {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let last = lines.last, last.hasPrefix("… "), lines.allSatisfy({ $0.hasPrefix("✓ ") || $0.hasPrefix("… ") }) else {
            return nil
        }
        return lines.map { line in
            let (state, detail) = stepState(String(line.dropFirst(2)))
            return Step(state: state, detail: detail, secs: 0)
        }
    }

    // a step of the helper («Читаю main.go», «Запускаю: go build») as the state the list draws
    public static func stepState(_ step: String) -> (String, String) {
        for (prefix, state) in [("Читаю ", "reading"), ("Правлю ", "editing"), ("Пишу ", "editing"), ("Запускаю: ", "running"), ("Ищу", "searching")] where step.hasPrefix(prefix) {
            return (state, String(step.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        if step == "Думаю" || step.isEmpty {
            return ("thinking", "")
        }
        return ("working", step)
    }

    // the helper's draft: steps, the current one «… ». Agentgram shows it as the work panel and hides the message
    public static func isDraft(_ message: EngineMessage) -> Bool {
        guard let author = message.author?.id, agentBots.contains(author) else {
            return false
        }
        return parseSteps(message.text) != nil
    }

    public static func session(bot: EnginePeer.Id, thread: Int64) -> Session? {
        return last.first(where: { $0.bot == bot && $0.thread == thread })
    }

    // stops the session's turn (the «стоп» of the panel in the topic): the computer directly when it is nearby,
    // else /stop in the topic, as the owner would type it
    public static func stop(bot: EnginePeer.Id, thread: Int64) {
        if stopNearby?(bot, thread) == true {
            return
        }
        guard let account else {
            return
        }
        let _ = enqueueMessages(account: account, peerId: bot, messages: [.message(text: "/stop", attributes: [], inlineStickers: [:], mediaReference: nil, threadId: thread == 0 ? nil : thread, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]).start()
    }

    // «8 с», «2:05»
    public static func elapsed(_ seconds: Int, russian: Bool = true) -> String {
        return seconds < 60 ? "\(seconds) " + (russian ? "с" : "s") : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // «думает», «читает Foo.swift» — one step, without the time
    public static func stepText(state: String, detail: String, russian: Bool) -> String {
        var session = Session(bot: EnginePeer.Id(namespace: Namespaces.Peer.CloudUser, id: EnginePeer.Id.Id._internalFromInt64Value(0)), thread: 0, state: state, detail: detail, since: Int32(Date().timeIntervalSince1970), queued: 0, model: nil)
        session.state = state
        let full = text(session, russian: russian)
        if let range = full.range(of: " · ", options: .backwards) {
            return String(full[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return full.trimmingCharacters(in: .whitespaces)
    }

    // «запускает команду · 8 мин»
    public static func text(_ session: Session, russian: Bool) -> String {
        let what: String
        switch session.state {
        case "thinking":
            what = russian ? "думает" : "thinking"
        case "typing":
            what = russian ? "печатает" : "typing"
        case "reading":
            what = russian ? "читает \(session.detail)" : "reading \(session.detail)"
        case "editing":
            what = russian ? "правит \(session.detail)" : "editing \(session.detail)"
        case "running":
            what = russian ? "запускает команду" : "running a command"
        case "searching":
            what = russian ? "ищет" : "searching"
        case "working":
            // the helper says its other steps in Russian: in English the known ones are named, the rest is «working»
            var detail = session.detail
            if !russian {
                let english = [("Работаю", "working"), ("Составляю план", "planning"), ("Запускаю помощника", "running a helper"), ("Читаю страницу", "reading a page")]
                if let (ru, en) = english.first(where: { detail.hasPrefix($0.0) }) {
                    detail = en + detail.dropFirst(ru.count)
                } else if detail.unicodeScalars.contains(where: { (0x0400 ... 0x04FF).contains($0.value) }) {
                    detail = ""
                }
            }
            let lowered = detail.prefix(1).lowercased() + detail.dropFirst()
            what = lowered.isEmpty ? (russian ? "работает" : "working") : lowered
        case "waiting_you", "idle":
            return russian ? "ждёт сообщения" : "waiting for a message"
        case "error":
            return session.detail.isEmpty ? (russian ? "ошибка" : "error") : session.detail
        default:
            what = session.state
        }
        let seconds = max(0, Int32(Date().timeIntervalSince1970) - session.since)
        let elapsed: String
        if seconds < 60 {
            elapsed = russian ? "\(seconds) с" : "\(seconds) s"
        } else {
            elapsed = russian ? "\(seconds / 60) мин" : "\(seconds / 60) min"
        }
        return "\(what) · \(elapsed)"
    }

    // the sessions as chat list «activities»: the session's row, and the bot's row with how many of them work.
    // Only while a turn goes (grey, with the dots, in place of the last message); an error is just the red dot.
    static let marker = "\u{0}agentgram:"
    static let settledMarker = "\u{0}agentgram!"
    static let errorMarker = "\u{0}agentgram×"

    static func activity(_ kind: Kind, _ text: String, peerId: EnginePeer.Id) -> PeerInputActivity {
        let prefix: String
        switch kind {
        case .working:
            prefix = marker
        case .settled:
            prefix = settledMarker
        case .error:
            prefix = errorMarker
        }
        return .interactingWithEmoji(emoticon: prefix + text, messageId: EngineMessage.Id(peerId: peerId, namespace: Namespaces.Message.Cloud, id: 0), interaction: nil)
    }

    static func activities(engine: TelegramEngine, russian: Bool) -> Signal<[ChatListNodePeerInputActivities.ItemId: [(EnginePeer, PeerInputActivity)]], NoError> {
        return sessions
        |> mapToSignal { sessions -> Signal<[ChatListNodePeerInputActivities.ItemId: [(EnginePeer, PeerInputActivity)]], NoError> in
            if sessions.isEmpty {
                return .single([:])
            }
            let bots = Set(sessions.map { $0.bot })
            return engine.data.get(EngineDataMap(bots.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
            |> map { peers -> [ChatListNodePeerInputActivities.ItemId: [(EnginePeer, PeerInputActivity)]] in
                var result: [ChatListNodePeerInputActivities.ItemId: [(EnginePeer, PeerInputActivity)]] = [:]
                for session in sessions {
                    guard let maybePeer = peers[session.bot], let peer = maybePeer else {
                        continue
                    }
                    let itemId = ChatListNodePeerInputActivities.ItemId(peerId: session.bot, threadId: session.thread)
                    if session.state == "typing" {
                        continue
                    } else if session.working {
                        result[itemId] = [(peer, activity(.working, text(session, russian: russian), peerId: session.bot))]
                    } else if session.state == "error" {
                        result[itemId] = [(peer, activity(.error, "", peerId: session.bot))]
                    }
                }
                for bot in bots {
                    guard let maybePeer = peers[bot], let peer = maybePeer else {
                        continue
                    }
                    let working = sessions.filter { $0.bot == bot && $0.working }
                    if working.count == 0 {
                        continue
                    }
                    // a bot without topics has one session, the whole chat: its row says what it does
                    if working.count == 1, working[0].thread == 0 {
                        result[ChatListNodePeerInputActivities.ItemId(peerId: bot, threadId: nil)] = [(peer, activity(.working, text(working[0], russian: russian), peerId: bot))]
                        continue
                    }
                    result[ChatListNodePeerInputActivities.ItemId(peerId: bot, threadId: nil)] = [(peer, activity(.working, workingLine(working.count, russian: russian), peerId: bot))]
                }
                return result
            }
        }
    }

    // «1 сессия работает», «3 сессии работают», «5 сессий работают»
    static func workingLine(_ count: Int, russian: Bool) -> String {
        if !russian {
            return count == 1 ? "1 session working" : "\(count) sessions working"
        }
        let tens = count % 100
        let ones = count % 10
        if ones == 1 && tens != 11 {
            return "\(count) сессия работает"
        } else if (2 ... 4).contains(ones) && !(12 ... 14).contains(tens) {
            return "\(count) сессии работают"
        } else {
            return "\(count) сессий работают"
        }
    }

    // the line under a session's title inside its topic: what it does, «ждёт сообщения», or the error; nothing when the server
    // does not know the session (the title says how many messages, as usual)
    public static func titleActivity(bot: EnginePeer.Id, thread: Int64, russian: Bool) -> Signal<PeerInputActivity?, NoError> {
        return sessions
        |> map { sessions -> PeerInputActivity? in
            guard let session = sessions.first(where: { $0.bot == bot && $0.thread == thread }), session.state != "typing" else {
                return nil
            }
            let kind: Kind = session.working ? .working : (session.state == "error" ? .error : .settled)
            return activity(kind, text(session, russian: russian), peerId: bot)
        }
    }

    // a status smuggled through the «activity» the chat list already knows how to draw
    static func customText(_ activity: PeerInputActivity) -> String? {
        return custom(activity)?.text
    }

    public static func custom(_ activity: PeerInputActivity) -> (text: String, kind: Kind)? {
        if case let .interactingWithEmoji(emoticon, _, _) = activity {
            for (prefix, kind) in [(marker, Kind.working), (settledMarker, .settled), (errorMarker, .error)] where emoticon.hasPrefix(prefix) {
                return (String(emoticon.dropFirst(prefix.count)), kind)
            }
        }
        return nil
    }
}
