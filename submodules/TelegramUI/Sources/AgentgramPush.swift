import Foundation
import CryptoKit
import TelegramCore
import BuildConfig

// Agentgram: Telegram sends pushes to a third-party iOS app only by Web Push, to an address the app names. The app
// names its relay (BuildConfig.pushRelayUrl) and puts its own APNs token into the address, sealed with the relay's
// public key: the relay keeps no list of devices, only it can read the token, and the phone never has to reach the
// relay itself. The payload is encrypted by Telegram with the account's master key, as for APNs, so the relay passes
// on only ciphertext, which the notification service extension opens. Without a relay configured, pushes go the
// Telegram way.
enum AgentgramPush {
    private static let buildConfig = BuildConfig(baseAppBundleId: Bundle.main.bundleIdentifier ?? "")

    // Whether the app's provisioning profile gives development (sandbox) APNs tokens
    static let apsIsDevelopment: Bool = {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"), let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .isoLatin1), let range = text.range(of: "<key>aps-environment</key>") else {
            return false
        }
        return text[range.upperBound...].prefix(80).contains("development")
    }()

    static var isConfigured: Bool {
        return !buildConfig.pushRelayUrl.isEmpty && !buildConfig.pushRelayKey.isEmpty && !buildConfig.pushRelayAuth.isEmpty
    }

    // The same sealed address every time for the same APNs token, so Telegram can be told to forget it later.
    static func tokenType(apnsToken: Data, sandbox: Bool) -> NotificationTokenType? {
        guard isConfigured else {
            return nil
        }
        let cacheKey = "agentgram.webPushToken.\(sandbox ? "s" : "p").\(apnsToken.base64EncodedString())"
        if let cached = UserDefaults.standard.string(forKey: cacheKey), cached.contains(buildConfig.pushRelayUrl) {
            return .webPush(token: cached)
        }
        guard let sealed = seal(apnsToken: apnsToken, sandbox: sandbox) else {
            return nil
        }
        let object: [String: Any] = [
            "endpoint": buildConfig.pushRelayUrl + "/p/" + sealed,
            "keys": [
                "p256dh": buildConfig.pushRelayKey,
                "auth": buildConfig.pushRelayAuth
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object), let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        UserDefaults.standard.set(token, forKey: cacheKey)
        return .webPush(token: token)
    }

    // ECIES on P-256: an ephemeral key, HKDF-SHA256 of the shared secret, AES-256-GCM over [sandbox byte] + token.
    // The relay does the same with its private key (push-relay/relay.mjs).
    private static func seal(apnsToken: Data, sandbox: Bool) -> String? {
        guard let relayKeyData = base64UrlDecode(buildConfig.pushRelayKey), let relayKey = try? P256.KeyAgreement.PublicKey(x963Representation: relayKeyData) else {
            return nil
        }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        guard let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: relayKey) else {
            return nil
        }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("agentgram push token".utf8), outputByteCount: 32)
        var plain = Data([sandbox ? 1 : 0])
        plain.append(apnsToken)
        guard let box = try? AES.GCM.seal(plain, using: key), let combined = box.combined else {
            return nil
        }
        var result = ephemeral.publicKey.x963Representation
        result.append(combined)
        return base64UrlEncode(result)
    }

    private static func base64UrlEncode(_ data: Data) -> String {
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func base64UrlDecode(_ string: String) -> Data? {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 {
            value.append("=")
        }
        return Data(base64Encoded: value)
    }
}
