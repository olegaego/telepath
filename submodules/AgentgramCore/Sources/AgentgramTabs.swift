import Foundation

// Agentgram: which tabs are at the bottom («Agentgram → Tabs»). Chats and Settings are always there; Contacts and
// Calls are off unless turned on (both screens still open from search, New Message and the profile).
public enum AgentgramTabs {
    public static let didChange = Notification.Name("AgentgramTabsDidChange")

    private static let contactsKey = "agentgram.tabs.contacts"
    private static let callsKey = "agentgram.tabs.calls"

    public static var showsContacts: Bool {
        get {
            return UserDefaults.standard.bool(forKey: contactsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: contactsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // the superfolder's tab, once it is made; on unless turned off
    private static let superfolderKey = "agentgram.tabs.superfolderOff"

    public static var showsSuperfolder: Bool {
        get {
            return !UserDefaults.standard.bool(forKey: superfolderKey)
        }
        set {
            UserDefaults.standard.set(!newValue, forKey: superfolderKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // the superfolder's tab before Chats instead of after
    private static let superfolderFirstKey = "agentgram.tabs.superfolderFirst"

    public static var superfolderFirst: Bool {
        get {
            return UserDefaults.standard.bool(forKey: superfolderFirstKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: superfolderFirstKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    public static var showsCalls: Bool {
        get {
            return UserDefaults.standard.bool(forKey: callsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: callsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
