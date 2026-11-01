import Foundation
import TelegramPresentationData

// The words of the computer and agent screens, Russian and English

struct ComputersTexts {
    let ru: Bool

    init(_ strings: PresentationStrings) {
        self.ru = strings.primaryComponent.languageCode.hasPrefix("ru")
    }

    var title: String { ru ? "Компьютеры" : "Computers" }
    var nearbyHeader: String { ru ? "РЯДОМ, В ЭТОЙ СЕТИ" : "NEARBY, ON THIS NETWORK" }
    var searching: String { ru ? "Ищу…" : "Searching…" }
    var connect: String { ru ? "Подключить" : "Connect" }
    var footer: String { ru ? "Запусти Telepath для компьютера на Маке или Windows в той же Wi-Fi. Он появится здесь. Подключиться нужно один раз, дальше одна сеть не нужна." : "Run the Telepath helper on a Mac or Windows computer on the same Wi-Fi. It shows up here. You connect once; after that the same network is not needed." }
    func codeTitle(_ name: String) -> String { ru ? "Подключить «\(name)»" : "Connect \(name)" }
    func codeText(_ code: String) -> String { ru ? "Код на экране компьютера должен быть таким:\n\n\(code)\n\nСовпадает?" : "The code on the computer should be:\n\n\(code)\n\nDoes it match?" }
    var matches: String { ru ? "Совпадает" : "It Matches" }
    var cancel: String { ru ? "Отмена" : "Cancel" }
    var done: String { ru ? "Подключено" : "Connected" }
    func doneText(_ bot: String, _ computer: String) -> String { ru ? "@\(bot) теперь работает на «\(computer)». Напиши ему." : "@\(bot) now works on \(computer). Write to it." }
    var failed: String { ru ? "Не вышло подключить" : "Could not connect" }
    func platformTitle(_ platform: String) -> String { platform == "windows" ? (ru ? "Агент на Windows" : "An Agent on Windows") : (ru ? "Агент на Маке" : "An Agent on a Mac") }
    var platformText: String { ru ? "Агент работает через Telepath Helper, маленькую программу на компьютере." : "The agent works through Telepath Helper, a small program on the computer." }
    // what to do, step by step; the first one downloads
    func steps(_ platform: String) -> [(String, String)] {
        if platform == "windows" {
            return [
                (ru ? "Скачай помощник" : "Download the helper", ru ? "С GitHub" : "From GitHub"),
                (ru ? "Распакуй и запусти" : "Unpack and run it", ru ? "Telepath Helper.exe из архива. Если Windows предупредит, нажми «Подробнее» → «Выполнить в любом случае»." : "Telepath Helper.exe from the archive. If Windows warns you, tap More info → Run anyway."),
                (ru ? "Найди значок" : "Find its icon", ru ? "Справа внизу, у часов. Если его не видно, он под стрелкой «^»." : "Bottom right, by the clock. If it is not there, it is under the «^» arrow."),
                (ru ? "Подключи" : "Connect", ru ? "Телефон и компьютер в одной Wi-Fi. Компьютер появится ниже." : "The phone and the computer on the same Wi-Fi. The computer appears below.")
            ]
        }
        return [
            (ru ? "Скачай помощник" : "Download the helper", ru ? "С GitHub" : "From GitHub"),
            (ru ? "Перетащи в «Программы»" : "Drag it to Applications", ru ? "Открой скачанный файл и перетащи Telepath Helper в папку «Программы»." : "Open the downloaded file and drag Telepath Helper to Applications."),
            (ru ? "Запусти его" : "Run it", ru ? "Значок появится сверху справа, в строке меню. Если Мак спросит, открыть ли, нажми «Открыть»." : "Its icon appears at the top right, in the menu bar. If the Mac asks whether to open it, tap Open."),
            (ru ? "Подключи" : "Connect", ru ? "Телефон и Мак в одной Wi-Fi. Мак появится ниже." : "The phone and the Mac on the same Wi-Fi. The Mac appears below.")
        ]
    }
    func download(_ platform: String) -> String { platform == "windows" ? (ru ? "Скачать для Windows" : "Download for Windows") : (ru ? "Скачать для Mac" : "Download for Mac") }
    var downloadButton: String { ru ? "Скачать" : "Download" }
    var onceFooter: String { ru ? "Подключиться нужно один раз, в одной Wi-Fi. Дальше агент работает откуда угодно." : "You connect once, on the same Wi-Fi. Then the agent works from anywhere." }
    var nearbyNow: String { ru ? "в сети, рядом" : "online, nearby" }
    var notNearby: String { ru ? "не в сети рядом" : "not online nearby" }
    var engineFar: String { ru ? "Движок меняется, когда телефон в той же Wi-Fi, что компьютер. Ещё его можно сменить в меню значка Telepath на компьютере." : "The engine is changed when the phone is on the same Wi-Fi as the computer. It can also be changed in the Telepath icon's menu on the computer." }
    var engineTitle: String { ru ? "На чём работает" : "Runs On" }
    var notInstalled: String { ru ? "не установлен на компьютере" : "not installed on the computer" }
    var engineFooter: String { ru ? "Лимиты берутся из Claude Code и Codex на компьютере и обновляются после каждого ответа агента. Темы у каждого движка свои: переключил, и в теме начнётся новая сессия.\n\nВходить в Claude Code и Codex нужно на компьютере. Telepath логины и пароли не спрашивает." : "Limits come from Claude Code and Codex on the computer and update after each answer. Each engine has its own sessions: after a switch, a topic starts a new one.\n\nYou sign in to Claude Code and Codex on the computer. Telepath never asks for logins or passwords." }
    func engineRunsOn(_ computer: String) -> String { ru ? "Работает на \(computer)" : "Runs on \(computer)" }
    var engineFailed: String { ru ? "Не вышло сменить движок. Компьютер рядом?" : "Could not change the engine. Is the computer nearby?" }
    var statusesRow: String { ru ? "Статусы" : "Statuses" }
    var voiceRow: String { ru ? "Распознавание" : "Recognition" }
    var voiceWay: String { ru ? "Способ" : "Method" }
    var voiceAway: String { ru ? "Компьютер сейчас не в этой сети. Распознавание включается, когда телефон в той же Wi-Fi, или в меню значка Telepath на компьютере." : "The computer is not on this network now. Recognition is turned on when the phone is on the same Wi-Fi, or in the Telepath icon's menu on the computer." }
    var modelRow: String { ru ? "Модель" : "Model" }
    var accessRow: String { ru ? "Доступ" : "Access" }
    var accessOnlyYou: String { ru ? "только ты" : "only you" }
    func accessYouAnd(_ n: Int) -> String { ru ? "ты и ещё \(n)" : "you and \(n) more" }
    var noTopicsTitle: String { ru ? "У бота нет тем" : "The bot has no topics" }
    var noTopicsText: String { ru ? "Сейчас весь чат одна сессия. Включи темы: @BotFather → /mybots → бот → Bot Settings → Threaded Mode." : "Its whole chat is one session now. Turn topics on: @BotFather → /mybots → the bot → Bot Settings → Threaded Mode." }
    var turnsToday: String { ru ? "ходов сегодня" : "turns today" }
    func sessionsCount(_ n: Int) -> String { ru ? "сессий: \(n)" : "sessions: \(n)" }
    var disconnectConfirm: String { ru ? "Помощник на компьютере забудет бота и токен. Сам бот и его чаты останутся." : "The helper on the computer forgets the bot and its token. The bot and its chats stay." }
    var computerRow: String { ru ? "Компьютер" : "Computer" }
    var openChat: String { ru ? "открыть чат" : "open chat" }
    var engineRow: String { ru ? "На чём работает" : "Runs On" }
    var projectsRow: String { ru ? "Папка проектов" : "Projects Folder" }
    var disconnect: String { ru ? "Отключить" : "Disconnect" }
    var disconnectFar: String { ru ? "Компьютер не в этой сети, поэтому он сам не узнает об отключении. Убрать его из списка? Чтобы помощник забыл токен, подключись к той же Wi-Fi или запусти на нём «agentgram-helper pair»." : "The computer is not on this network, so it will not learn about this. Remove it from the list? For the helper to forget the token, join the same Wi-Fi or run «agentgram-helper pair» on it." }
    var remove: String { ru ? "Убрать" : "Remove" }
    var taken: String { ru ? "уже подключён" : "connected" }
    func takenText(_ bot: String) -> String {
        let who = bot.isEmpty ? "" : (ru ? " с ботом @\(bot)" : " with @\(bot)")
        return ru ? "Этот компьютер уже подключён\(who) к другому телефону или к прошлой установке Telepath. Чтобы подключить его сюда, запусти на нём «agentgram-helper pair»." : "This computer is already connected\(who) to another phone or an earlier Telepath install. To connect it here, run «agentgram-helper pair» on it."
    }
    var tokenHeader: String { ru ? "ТОКЕН БОТА" : "BOT TOKEN" }
    var tokenPlaceholder: String { ru ? "123456789:AA…" : "123456789:AA…" }
    var tokenFooter: String { ru ? "Этот бот будет работать на компьютере: ты пишешь ему, отвечает агент. Токен возьми у @BotFather: /token → выбери бота → скопируй.\n\nТокен уходит только на этот компьютер, напрямую по твоей сети, зашифрованным ключом компьютера. На телефоне он не сохраняется. Код Telepath открыт, это всегда можно проверить." : "This bot will work on the computer: you write to it, the agent answers. Get the token from @BotFather: /token → pick the bot → copy.\n\nThe token goes only to this computer, straight over your network, encrypted with the computer's key. It is not kept on the phone. Telepath's code is open, you can always check this." }
    var engineHeader: String { ru ? "НА ЧЁМ РАБОТАЕТ" : "RUNS ON" }
    var connectButton: String { ru ? "Подключить" : "Connect" }
    var badToken: String { ru ? "Это не похоже на токен бота. Скопируй его у @BotFather целиком." : "This does not look like a bot token. Copy it whole from @BotFather." }
    var connecting: String { ru ? "Подключаю…" : "Connecting…" }
}
