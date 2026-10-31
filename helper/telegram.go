package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"time"
)

// A small Telegram Bot API client: only what the helper needs, straight to api.telegram.org with the bot's token.

type Bot struct {
	token  string
	client *http.Client
}

func NewBot(token string) *Bot {
	return &Bot{token: token, client: &http.Client{Timeout: 70 * time.Second}}
}

type apiResponse struct {
	OK          bool            `json:"ok"`
	Result      json.RawMessage `json:"result"`
	Description string          `json:"description"`
	Parameters  struct {
		RetryAfter int `json:"retry_after"`
	} `json:"parameters"`
}

type APIError struct {
	Method      string
	Description string
	RetryAfter  int
}

func (e *APIError) Error() string {
	return fmt.Sprintf("%s: %s", e.Method, e.Description)
}

func (b *Bot) call(method string, params any, out any) error {
	body, err := json.Marshal(params)
	if err != nil {
		return err
	}
	resp, err := b.client.Post("https://api.telegram.org/bot"+b.token+"/"+method, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return b.decode(method, resp.Body, out)
}

func (b *Bot) decode(method string, r io.Reader, out any) error {
	var res apiResponse
	if err := json.NewDecoder(r).Decode(&res); err != nil {
		return err
	}
	if !res.OK {
		return &APIError{Method: method, Description: res.Description, RetryAfter: res.Parameters.RetryAfter}
	}
	if out != nil {
		return json.Unmarshal(res.Result, out)
	}
	return nil
}

type User struct {
	ID        int64  `json:"id"`
	IsBot     bool   `json:"is_bot"`
	FirstName string `json:"first_name"`
	Username  string `json:"username"`
}

type Chat struct {
	ID   int64  `json:"id"`
	Type string `json:"type"`
}

type PhotoSize struct {
	FileID string `json:"file_id"`
	Width  int    `json:"width"`
}

type Document struct {
	FileID   string `json:"file_id"`
	FileName string `json:"file_name"`
	MimeType string `json:"mime_type"`
}

type Message struct {
	MessageID         int64       `json:"message_id"`
	MessageThreadID   int64       `json:"message_thread_id"`
	From              *User       `json:"from"`
	Chat              Chat        `json:"chat"`
	Text              string      `json:"text"`
	Caption           string      `json:"caption"`
	Photo             []PhotoSize `json:"photo"`
	Document          *Document   `json:"document"`
	ForumTopicCreated *struct {
		Name string `json:"name"`
	} `json:"forum_topic_created"`
}

type CallbackQuery struct {
	ID      string   `json:"id"`
	From    User     `json:"from"`
	Message *Message `json:"message"`
	Data    string   `json:"data"`
}

type Update struct {
	UpdateID      int64          `json:"update_id"`
	Message       *Message       `json:"message"`
	CallbackQuery *CallbackQuery `json:"callback_query"`
}

type Button struct {
	Text         string `json:"text"`
	CallbackData string `json:"callback_data"`
}

type Keyboard struct {
	InlineKeyboard [][]Button `json:"inline_keyboard"`
}

func (b *Bot) GetMe() (User, error) {
	var u User
	err := b.call("getMe", map[string]any{}, &u)
	return u, err
}

func (b *Bot) GetUpdates(offset int64) ([]Update, error) {
	var ups []Update
	err := b.call("getUpdates", map[string]any{"offset": offset, "timeout": 50, "allowed_updates": []string{"message", "callback_query"}}, &ups)
	return ups, err
}

func (b *Bot) Send(chat, thread int64, text string, kb *Keyboard) (Message, error) {
	params := map[string]any{"chat_id": chat, "text": text}
	if thread != 0 {
		params["message_thread_id"] = thread
	}
	if kb != nil {
		params["reply_markup"] = kb
	}
	var m Message
	err := b.call("sendMessage", params, &m)
	return m, err
}

func (b *Bot) SendRich(chat, thread int64, markdown string, kb *Keyboard) (Message, error) {
	params := map[string]any{"chat_id": chat, "rich_message": map[string]any{"markdown": markdown}}
	if thread != 0 {
		params["message_thread_id"] = thread
	}
	if kb != nil {
		params["reply_markup"] = kb
	}
	var m Message
	err := b.call("sendRichMessage", params, &m)
	return m, err
}

func (b *Bot) Edit(chat, message int64, text string, kb *Keyboard) error {
	params := map[string]any{"chat_id": chat, "message_id": message, "text": text}
	if kb != nil {
		params["reply_markup"] = kb
	}
	return b.call("editMessageText", params, nil)
}

func (b *Bot) Delete(chat, message int64) error {
	return b.call("deleteMessage", map[string]any{"chat_id": chat, "message_id": message}, nil)
}

func (b *Bot) Answer(callbackID, text string) error {
	return b.call("answerCallbackQuery", map[string]any{"callback_query_id": callbackID, "text": text}, nil)
}

func (b *Bot) Typing(chat, thread int64) {
	params := map[string]any{"chat_id": chat, "action": "typing"}
	if thread != 0 {
		params["message_thread_id"] = thread
	}
	_ = b.call("sendChatAction", params, nil)
}

// Download a file the owner sent (a photo or a document), up to Telegram's 20 MB for bots
func (b *Bot) Download(fileID string) ([]byte, string, error) {
	var f struct {
		FilePath string `json:"file_path"`
	}
	if err := b.call("getFile", map[string]any{"file_id": fileID}, &f); err != nil {
		return nil, "", err
	}
	resp, err := b.client.Get("https://api.telegram.org/file/bot" + b.token + "/" + url.PathEscape(f.FilePath))
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	return data, f.FilePath, err
}

// A photo the agent made, as a file upload
func (b *Bot) SendPhoto(chat, thread int64, name string, data []byte) error {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	_ = w.WriteField("chat_id", fmt.Sprint(chat))
	if thread != 0 {
		_ = w.WriteField("message_thread_id", fmt.Sprint(thread))
	}
	part, err := w.CreateFormFile("photo", name)
	if err != nil {
		return err
	}
	if _, err := part.Write(data); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	resp, err := b.client.Post("https://api.telegram.org/bot"+b.token+"/sendPhoto", w.FormDataContentType(), &buf)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return b.decode("sendPhoto", resp.Body, nil)
}
