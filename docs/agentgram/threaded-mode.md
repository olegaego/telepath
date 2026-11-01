# Threaded Mode

Темы ботов с Threaded Mode в списке чатов, под ботом.

## Где наш код

Свои файлы:
- `submodules/TelegramUI/Components/ThreadedBotSessions`: правила (какой бот, сколько сессий, обновление тем), выключатель `ThreadedBotSessions.isEnabled`.
- `submodules/TelegramUIPreferences/Sources/ThreadedBotSettings.swift`: настройки каждого бота.
- `submodules/ChatListUI/Sources/Node/ThreadedBotChatList.swift`: сессии в списке чатов поверх списка Telegram.
- `submodules/TelegramUI/Components/Communities/CommunityViewScreen/Sources/CommunityViewScreen+ThreadedBot.swift`: строка сессии на экране бота.

Вставки в файлы Telegram: точный список даёт `git diff telegram main -- submodules Telegram`. Большие вставки помечены `// Agentgram`.

## Выключатель

`ThreadedBotSessions.isEnabled`, по умолчанию включён. Выключен: все боты как в обычном Telegram (без сессий в списке, без стрелки, переключатель тем внутри чата). Позже: «Агентграм → Вид тем».

## Проверка после переноса и каждого обновления Telegram

Нужен бот с Threaded Mode и несколькими темами.

1. Список чатов: под ботом его темы, самая свежая сверху, у каждой значок темы вместо аватарки.
2. Новое сообщение в теме: тема поднимается первой под ботом, бот поднимается в списке вместе с темами.
3. У бота кнопка «New Chat» (если бот разрешает создавать темы), по нажатию новая тема.
4. Стрелка на аватарке бота открывает экран бота: «In Chat List» и «Other Topics».
5. Долгое нажатие на тему: превью; «убрать из списка» переносит её в «Other Topics», возврат обратно.
6. Режим «Topics Inside the Bot»: под ботом пусто, в чате бота сверху переключатель тем.
7. Режим «Show as One Chat»: одна строка со стопкой, по нажатию список тем.
8. Тема прочитана на другом устройстве: через 30 секунд непрочитанное пропадает и здесь.
9. Обычные боты, группы, форумы, папки, архив выглядят как в обычном Telegram.
10. Выключатель выключен: все боты как в обычном Telegram.
