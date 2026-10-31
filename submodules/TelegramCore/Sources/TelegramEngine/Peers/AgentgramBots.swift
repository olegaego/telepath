import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

// Agentgram: the bots the user owns, and a bot's token, to connect a bot to the Agentgram helper on the user's
// computer. The token goes from here only to that computer, sealed with its key.
public extension TelegramEngine.Peers {
    func agentgramOwnedBots() -> Signal<[EnginePeer], NoError> {
        let account = self.account
        return account.network.request(Api.functions.bots.getAdminedBots())
        |> map(Optional.init)
        |> `catch` { _ -> Signal<[Api.User]?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { users -> Signal<[EnginePeer], NoError> in
            guard let users else {
                return .single([])
            }
            return account.postbox.transaction { transaction -> [EnginePeer] in
                updatePeers(transaction: transaction, accountPeerId: account.peerId, peers: AccumulatedPeers(users: users))
                return users.compactMap { transaction.getPeer($0.peerId).flatMap(EnginePeer.init) }
            }
        }
    }

    func agentgramBotToken(botId: EnginePeer.Id) -> Signal<String?, NoError> {
        let account = self.account
        return account.postbox.transaction { transaction -> Api.InputUser? in
            return transaction.getPeer(botId).flatMap(apiInputUser)
        }
        |> mapToSignal { inputUser -> Signal<String?, NoError> in
            guard let inputUser else {
                return .single(nil)
            }
            return account.network.request(Api.functions.bots.exportBotToken(bot: inputUser, revoke: .boolFalse))
            |> map { result -> String? in
                switch result {
                case let .exportedBotToken(data):
                    return data.token
                }
            }
            |> `catch` { _ -> Signal<String?, NoError> in
                return .single(nil)
            }
        }
    }
}
