import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import PresentationDataUtils

// Telepath's own version and its updates. The newest version is asked of Apple (the App Store's lookup), not of a
// server of ours. At start a new version is offered once; «Check for Updates» in the Telepath section asks any time.

let agentgramAppStoreId = "6829434949"
let agentgramChannel = "gotelepath"

func agentgramAppVersion() -> (version: String, build: String) {
    let info = Bundle.main.infoDictionary ?? [:]
    return (info["CFBundleShortVersionString"] as? String ?? "", info["CFBundleVersion"] as? String ?? "")
}

// «1.0.10» is newer than «1.0.9»: numbers compared one by one
func agentgramIsNewer(_ candidate: String, than current: String) -> Bool {
    let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let b = current.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0 ..< max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y {
            return x > y
        }
    }
    return false
}

private struct AgentgramStoreVersion {
    let version: String
    let notes: String
}

// the version in the App Store and what is new in it; nil when Apple does not answer
private func agentgramStoreVersion(_ completion: @escaping (AgentgramStoreVersion?) -> Void) {
    guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(agentgramAppStoreId)&t=\(Int(Date().timeIntervalSince1970))") else {
        completion(nil)
        return
    }
    URLSession.shared.dataTask(with: url) { data, _, _ in
        var found: AgentgramStoreVersion?
        if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let result = (json["results"] as? [[String: Any]])?.first, let version = result["version"] as? String {
            found = AgentgramStoreVersion(version: version, notes: result["releaseNotes"] as? String ?? "")
        }
        Queue.mainQueue().async {
            completion(found)
        }
    }.resume()
}

private func agentgramOpenAppStore() {
    if let url = URL(string: "itms-apps://apps.apple.com/app/id\(agentgramAppStoreId)") {
        UIApplication.shared.open(url)
    }
}

private func agentgramUpdateAlert(_ context: AccountContext, _ store: AgentgramStoreVersion) -> ViewController {
    let ru = context.sharedContext.currentPresentationData.with { $0 }.strings.primaryComponent.languageCode.hasPrefix("ru")
    let title = ru ? "Есть обновление \(store.version)" : "Update \(store.version) Is Available"
    let notes = store.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    return textAlertController(context: context, title: title, text: notes.isEmpty ? (ru ? "Обновите Telepath в App Store." : "Update Telepath in the App Store.") : notes, actions: [
        TextAlertAction(type: .genericAction, title: ru ? "Позже" : "Later", action: {}),
        TextAlertAction(type: .defaultAction, title: ru ? "Обновить" : "Update", action: { agentgramOpenAppStore() })
    ])
}

// «Check for Updates»: the update, or that this is the newest one
func agentgramCheckForUpdates(context: AccountContext, present: @escaping (ViewController) -> Void) {
    let ru = context.sharedContext.currentPresentationData.with { $0 }.strings.primaryComponent.languageCode.hasPrefix("ru")
    agentgramStoreVersion { store in
        guard let store else {
            present(agentgramAlert(context, ru ? "Не удалось проверить. Попробуйте позже." : "Could not check. Try again later."))
            return
        }
        if agentgramIsNewer(store.version, than: agentgramAppVersion().version) {
            present(agentgramUpdateAlert(context, store))
        } else {
            present(agentgramAlert(context, ru ? "У вас последняя версия Telepath." : "You have the latest version of Telepath."))
        }
    }
}

// At start: a version newer than this one is offered once, not at every start
public func agentgramOfferUpdate(context: AccountContext, present: @escaping (ViewController) -> Void) {
    agentgramStoreVersion { store in
        guard let store, agentgramIsNewer(store.version, than: agentgramAppVersion().version) else {
            return
        }
        let key = "agentgram.update.offered.\(store.version)"
        if UserDefaults.standard.bool(forKey: key) {
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        present(agentgramUpdateAlert(context, store))
    }
}
