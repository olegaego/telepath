import Foundation

// An engine's limit windows, as the helper sends them, and how they read

// The limits the helper sends in /info: per engine, its windows with the used percent and the reset time
struct EngineLimitWindow: Equatable {
    let name: String
    let percent: Double
    let resetsAt: Int64
}

func engineLimits(_ info: [String: Any]?, engine: String) -> [EngineLimitWindow] {
    guard let limits = info?["limits"] as? [String: Any], let one = limits[engine] as? [String: Any], let windows = one["windows"] as? [[String: Any]] else {
        return []
    }
    return windows.compactMap { w in
        guard let name = w["name"] as? String else {
            return nil
        }
        return EngineLimitWindow(name: name, percent: (w["percent"] as? NSNumber)?.doubleValue ?? 0.0, resetsAt: (w["resets_at"] as? NSNumber)?.int64Value ?? 0)
    }
}

func limitWindowTitle(_ name: String, ru: Bool) -> String {
    switch name {
    case "5h": return ru ? "5 часов" : "5 hours"
    case "week": return ru ? "Неделя" : "Week"
    case "month": return ru ? "Месяц" : "Month"
    default: return name
    }
}

func limitShortTitle(_ name: String, ru: Bool) -> String {
    switch name {
    case "5h": return ru ? "5 ч" : "5 h"
    case "week": return ru ? "неделя" : "week"
    case "month": return ru ? "месяц" : "month"
    default: return name
    }
}

// «до 14:00» today, «до 4 нояб.» later: when a window resets, under its percent
func limitUntilText(_ at: Int64, ru: Bool) -> String {
    if at == 0 {
        return ""
    }
    let date = Date(timeIntervalSince1970: TimeInterval(at))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: ru ? "ru_RU" : "en_US")
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : (ru ? "d MMM" : "MMM d")
    return (ru ? "до " : "until ") + formatter.string(from: date)
}

// «5 ч: 34% · неделя: 81%», for the engine picker
func limitsSummary(_ windows: [EngineLimitWindow], ru: Bool) -> String {
    return windows.map { "\(limitShortTitle($0.name, ru: ru)): \(Int($0.percent.rounded()))%" }.joined(separator: " · ")
}
