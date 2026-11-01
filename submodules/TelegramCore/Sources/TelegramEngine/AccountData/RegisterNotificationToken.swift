import Foundation
import SwiftSignalKit
import Postbox
internal import TelegramApi


public enum NotificationTokenType {
    case aps(encrypt: Bool)
    case voip
    // Agentgram: Telegram reaches a third-party iOS app only by Web Push; the token is the JSON Telegram expects
    // (endpoint and keys), the app's APNs token sealed in the endpoint. Payloads are encrypted with the account's
    // master key, as for APNs, so the relay passes on only ciphertext.
    case webPush(token: String)
}

func _internal_unregisterNotificationToken(account: Account, token: Data, type: NotificationTokenType, otherAccountUserIds: [PeerId.Id]) -> Signal<Never, NoError> {
    let mappedType: Int32
    var tokenString = hexString(token)
    switch type {
        case .aps:
            mappedType = 1
        case .voip:
            mappedType = 9
        case let .webPush(webPushToken):
            mappedType = 10
            tokenString = webPushToken
    }
    return account.network.request(Api.functions.account.unregisterDevice(tokenType: mappedType, token: tokenString, otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
    |> retryRequest
    |> ignoreValues
}

func _internal_registerNotificationToken(account: Account, token: Data, type: NotificationTokenType, sandbox: Bool, otherAccountUserIds: [PeerId.Id], excludeMutedChats: Bool) -> Signal<Bool, NoError> {
    return masterNotificationsKey(account: account, ignoreDisabled: false)
    |> mapToSignal { masterKey -> Signal<Bool, NoError> in
        let mappedType: Int32
        var keyData = Data()
        // Agentgram
        var tokenString = hexString(token)
        switch type {
            case let .aps(encrypt):
                mappedType = 1
                if encrypt {
                    keyData = masterKey.data
                }
            case .voip:
                mappedType = 9
                keyData = masterKey.data
            // Agentgram
            case let .webPush(webPushToken):
                mappedType = 10
                keyData = masterKey.data
                tokenString = webPushToken
        }
        var flags: Int32 = 0
        if excludeMutedChats {
            flags |= 1 << 0
        }
        return account.network.request(Api.functions.account.registerDevice(flags: flags, tokenType: mappedType, token: tokenString, appSandbox: sandbox ? .boolTrue : .boolFalse, secret: Buffer(data: keyData), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
        |> map { _ -> Bool in
            return true
        }
        |> `catch` { error -> Signal<Bool, NoError> in
            if error.errorDescription == "TOKEN_WAS_INVALIDATED" {
                return .single(false)
            } else {
                return .single(true)
            }
        }
    }
}
