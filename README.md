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
