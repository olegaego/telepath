import Foundation
import UIKit
import SwiftSignalKit

// Agentgram: voice messages to an agent are recognized on its computer (Agentgram Helper): Whisper on the Mac or Groq
// with the owner's key, kept on the computer. The phone only remembers the last choice, to turn it back on.

public struct AgentgramVoiceSettings: Codable, Equatable {
    public var mode: String = "whisper" // the way chosen last: "whisper" or "groq"
    public var model: String = "light"
    // recognition on for all agents
    public var on: Bool = false

    public init() {
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "whisper"
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? "light"
        self.on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
    }

    public static let groqModels = ["whisper-large-v3-turbo", "whisper-large-v3"]

    private static let key = "agentgram.voice.computer"

    public static var current: AgentgramVoiceSettings {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(AgentgramVoiceSettings.self, from: data) else {
            return AgentgramVoiceSettings()
        }
        return value
    }

    public static let changed = ValuePromise<Int>(0, ignoreRepeated: false)

    public static func update(_ f: (inout AgentgramVoiceSettings) -> Void) {
        var value = current
        f(&value)
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
        changed.set(0)
    }
}

// The Whisper models the computer can download
struct AgentgramWhisperModel: Equatable {
    let id: String
    let megabytes: Int

    static let light = AgentgramWhisperModel(id: "light", megabytes: 148)
    static let accurate = AgentgramWhisperModel(id: "accurate", megabytes: 574)
    static let all = [light, accurate]
}

// What the computer says about recognition (its /info «voice»)
struct AgentgramComputerVoice {
    let mode: String
    let model: String
    let groqModel: String
    let groqKey: Bool
    let models: [String: (downloaded: Bool, progress: Double?)]

    init?(_ info: [String: Any]?) {
        guard let voice = info?["voice"] as? [String: Any] else {
            return nil
        }
        self.mode = voice["mode"] as? String ?? "off"
        self.model = voice["model"] as? String ?? "light"
        self.groqModel = voice["groq_model"] as? String ?? AgentgramVoiceSettings.groqModels[0]
        self.groqKey = voice["groq_key"] as? Bool ?? false
        var models: [String: (downloaded: Bool, progress: Double?)] = [:]
        for (id, value) in voice["models"] as? [String: Any] ?? [:] {
            let state = value as? [String: Any] ?? [:]
            models[id] = (state["downloaded"] as? Bool ?? false, (state["progress"] as? NSNumber)?.doubleValue)
        }
        self.models = models
    }
}
