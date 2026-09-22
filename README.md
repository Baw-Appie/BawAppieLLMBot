# BawAppieLLMBot
Telegram LLM Bot built with Swift

## Getting Started

Set the required environment variables before starting the app:

```bash
export TELEGRAM_BOT_TOKEN="your-rotated-bot-token"
export TELEGRAM_WEBHOOK_SECRET="your-webhook-secret"
export TELEGRAM_WEBHOOK_URL="https://example.com/telegram/webhook"
export OPENAI_API_KEY="your-openai-api-key"
export OPENAI_MODEL="gpt-5-mini"
export OPENAI_IMAGE_MODEL="gpt-image-2.5-flare"
```

`OPENAI_MODEL` is optional and defaults to `gpt-5.6-luna`.

## Web search

The bot can automatically use OpenAI Responses web search for current or
time-sensitive questions and when the user explicitly asks it to search or verify
something online. Search answers include clickable source links in Telegram.

## Conversation memory

The bot remembers the latest 20 successfully delivered question/answer pairs per
Telegram chat and topic, including guest messages. People in the same chat/topic
share this history. Only messages received and handled by the bot are remembered.
History survives restarts in `db.sqlite` in the working directory. Override the
file location with `CONVERSATION_DB_PATH` (the parent directory must exist and be
writable). SQLite is bundled through SQLiteNIO; no separate database server is needed.

Each request includes the most recent complete pairs fitting within 64,000 UTF-8
bytes, followed by the current message. Older pairs are discarded, not summarized.
Image requests retain the request and generation prompt, not the image itself.
Send `/reset` to delete the current chat/topic's history; in groups, any participant
can reset this shared memory. Other chats and topics are unaffected.

Run one bot process per database so turns in each chat are processed in order.
Different chats can generate replies concurrently. Docker Compose stores the database
in the `conversation-data` volume; keep this volume across container replacements.
For PM2 or direct execution, keep the database file across deployments. Use SQLite's
backup facilities, or stop the bot before copying the database and its WAL files.

To build the project using the Swift Package Manager, run the following command in the terminal from the root of the project:
```bash
swift build
```

To run the project and start the server, use the following command:
```bash
swift run
```

After the public server is running, register or remove the Telegram webhook with:

```bash
curl https://example.com/telegram/register
curl https://example.com/telegram/unregister
```

To execute tests, use the following command:
```bash
swift test
```
