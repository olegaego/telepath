import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ConvertOpusToAAC
import LocalAudioTranscription
import AgentgramSettingsUI

// Agentgram: a voice message to an agent's bot goes with its text. The phone turns speech into text itself (iOS speech
// recognition, on the device), and the text rides as the voice message's caption, which the helper on the computer
// reads. The voice is heard by nobody else and no transcription service is used.

// Whether this send has a voice message without text, to a chat where it may need a caption
func agentgramHasVoiceWithoutText(_ messages: [EnqueueMessage]) -> Bool {
    return messages.contains { message in
        if case let .message(text, _, _, mediaReference, _, _, _, _, _, _) = message, text.isEmpty, let file = mediaReference?.media as? TelegramMediaFile, file.isVoice {
            return true
        }
        return false
    }
}

func agentgramVoiceCaptions(context: AccountContext, peerId: EnginePeer.Id, messages: [EnqueueMessage]) -> Signal<[EnqueueMessage], NoError> {
    return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
    |> mapToSignal { peer -> Signal<[EnqueueMessage], NoError> in
        guard case let .user(user) = peer, user.botInfo != nil, let username = user.addressName, agentgramIsAgentBot(context: context, username: username) else {
            return .single(messages)
        }
        let appLocale = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
        let transformed: [Signal<EnqueueMessage, NoError>] = messages.map { message in
            guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message, text.isEmpty, let file = mediaReference?.media as? TelegramMediaFile, file.isVoice, let path = context.account.postbox.mediaBox.completedResourcePath(file.resource) else {
                return .single(message)
            }
            return convertOpusToAAC(sourcePath: path, allocateTempFile: {
                return EngineTempBox.shared.tempFile(fileName: "agentgram-voice.m4a").path
            })
            |> mapToSignal { aacPath -> Signal<LocallyTranscribedAudio?, NoError> in
                guard let aacPath else {
                    return .single(nil)
                }
                return transcribeAudio(path: aacPath, appLocale: appLocale)
                |> filter { $0?.isFinal ?? true }
                |> take(1)
            }
            |> timeout(30.0, queue: Queue.mainQueue(), alternate: .single(nil))
            |> map { result -> EnqueueMessage in
                guard let caption = result?.text.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else {
                    return message
                }
                return .message(text: caption, attributes: attributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
            }
        }
        return combineLatest(transformed)
    }
}
