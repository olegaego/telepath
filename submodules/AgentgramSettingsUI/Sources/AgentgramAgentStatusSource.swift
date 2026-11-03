import Foundation
import Network
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChatListUI

// Where the sessions' status comes from, for the chat list and the topics: which bots are agents (the bots of the
// computers this phone connected), and, for a computer on the same Wi-Fi, its own word every two seconds (/status:
// what each topic does, its steps, the engine's limits). Away from home the chat list reads the bot's messages
// instead (AgentgramAgentStatus). Nothing here talks to any server but the computer itself.

private var started = false
private var nearbyEndpoints: [Data: NWEndpoint] = [:]

func agentgramNearbyEndpoint(_ publicKey: Data) -> NWEndpoint? {
    return nearbyEndpoints[publicKey]
}
private var botIds: [String: EnginePeer.Id] = [:]

public func agentgramStartAgentStatus(context: AccountContext) {
    if started {
        return
    }
    started = true
    let found = agentgramBrowser

    // the agents' bots, by their usernames, as peers
    let bots: Signal<[EnginePeer.Id], NoError> = ConnectedComputers.changed.get()
    |> mapToSignal { _ -> Signal<[EnginePeer.Id], NoError> in
        let names = Array(Set(ConnectedComputers.all(context).map { $0.bot.lowercased() }))
        if names.isEmpty {
            return .single([])
        }
        return combineLatest(names.map { name in
            agentgramPeer(context, username: name)
            |> map { peer -> (String, EnginePeer.Id?) in (name, peer?.id) }
        })
        // botIds is read on the main queue (the status timer, «Stop»): it is written there too, never from the
        // queue the peers come on
        |> deliverOnMainQueue
        |> map { pairs -> [EnginePeer.Id] in
            for (name, id) in pairs {
                if let id {
                    botIds[name] = id
                }
            }
            return pairs.compactMap { $0.1 }
        }
    }

    // every two seconds, each connected computer that is nearby: its topics
    let nearby: Signal<[AgentgramAgentStatus.Session], NoError> = Signal { subscriber in
        let timer = SwiftSignalKit.Timer(timeout: 2.0, repeat: true, completion: {
            let _ = (found.computers.get() |> take(1)).start(next: { computers in
                var endpoints: [Data: NWEndpoint] = [:]
                for computer in computers {
                    endpoints[computer.publicKey] = computer.endpoint
                }
                nearbyEndpoints = endpoints
                if AgentgramStatusesMode.pending {
                    let _ = agentgramSendStatusesMode(context: context)
                }
                let connected = ConnectedComputers.computers(context).filter { endpoints[$0.publicKey] != nil }
                // «off»: only Telegram's own «typing…», no statuses from the computer either
                if connected.isEmpty || AgentgramStatusesMode.current == .off {
                    subscriber.putNext([])
                    return
                }
                var collected: [[AgentgramAgentStatus.Session]] = []
                var left = connected.count
                for computer in connected {
                    askComputer(endpoints[computer.publicKey]!, computer, path: "/status", completion: { result in
                        collected.append(sessions(from: result, bot: botIds[computer.bot.lowercased()], botIds: botIds))
                        left -= 1
                        if left == 0 {
                            subscriber.putNext(collected.flatMap { $0 })
                        }
                    })
                }
            })
        }, queue: Queue.mainQueue())
        timer.start()
        return ActionDisposable {
            timer.invalidate()
        }
    }

    AgentgramAgentStatus.configure(account: context.account, bots: bots, nearby: nearby, stopNearby: { bot, thread in
        guard let name = botIds.first(where: { $0.value == bot })?.key, let computer = ConnectedComputers.all(context).first(where: { $0.bot.lowercased() == name }), let endpoint = nearbyEndpoints[computer.publicKey] else {
            return false
        }
        askComputer(endpoint, computer, path: "/stop", extra: ["chat": context.account.peerId.id._internalGetInt64Value(), "thread": thread], completion: { _ in })
        return true
    })
    AgentgramAgentStatus.start()
}

// The helper's /status as the chat list's sessions; and its limits for the session's sheet
// a computer with several agents tells each topic's bot; an older helper only its one bot
private func sessions(from result: [String: Any]?, bot defaultBot: EnginePeer.Id?, botIds: [String: EnginePeer.Id]) -> [AgentgramAgentStatus.Session] {
    guard let result, let topics = result["topics"] as? [[String: Any]] else {
        return []
    }
    let engineNow = agentgramEngineName(result["engine"] as? String)
    if let defaultBot {
        AgentgramAgentStatus.engines[defaultBot] = engineNow
    }
    if let limits = result["limits"] as? [String: Any] {
        for (engine, name) in agentgramEngines {
            var windows: [String: AgentgramAgentStatus.Limit] = [:]
            let time = ((limits[engine] as? [String: Any])?["time"] as? NSNumber)?.int32Value
            for window in engineLimits(["limits": limits], engine: engine) {
                windows[window.name] = AgentgramAgentStatus.Limit(pct: Int(window.percent.rounded()), resetsAt: window.resetsAt == 0 ? nil : Int32(window.resetsAt), updatedAt: time == 0 ? nil : time)
            }
            AgentgramAgentStatus.limits[name] = windows
        }
    }
    return topics.compactMap { topic -> AgentgramAgentStatus.Session? in
        guard let thread = (topic["thread"] as? NSNumber)?.int64Value, let state = topic["state"] as? String else {
            return nil
        }
        guard let bot = (topic["bot"] as? String).flatMap({ $0.isEmpty ? nil : botIds[$0.lowercased()] }) ?? defaultBot else {
            return nil
        }
        let detail = topic["detail"] as? String ?? ""
        var session = AgentgramAgentStatus.Session(bot: bot, thread: thread, state: state, detail: detail, since: (topic["since"] as? NSNumber)?.int32Value ?? 0, queued: (topic["queued"] as? NSNumber)?.intValue ?? 0, model: (topic["engine"] as? String).flatMap { $0.isEmpty ? nil : agentgramEngineName($0) } ?? engineNow)
        if state == "working" {
            (session.state, session.detail) = AgentgramAgentStatus.stepState(detail)
        }
        if let context = topic["context"] as? [String: Any], let used = (context["used"] as? NSNumber)?.intValue, let max = (context["max"] as? NSNumber)?.intValue, max > 0 {
            session.context = (used, max)
        }
        session.steps = (topic["steps"] as? [[String: Any]] ?? []).map { step in
            let (state, detail) = AgentgramAgentStatus.stepState(step["text"] as? String ?? "")
            return AgentgramAgentStatus.Step(state: state, detail: detail, secs: (step["secs"] as? NSNumber)?.intValue ?? 0)
        }
        return session
    }
}
