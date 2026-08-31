import Foundation
import Vapor

struct TelegramWebhookResponse: Content {
    let ok: Bool
}

struct TelegramRouteController: RouteCollection {
    let model = Environment.get("OPENAI_MODEL") ?? "gpt-5.6-luna"
    let openAI: OpenAI
    let telegramAPI: TelegramAPI
    
    init() throws {
        openAI = OpenAI(apiKey: try requiredEnvironment("OPENAI_API_KEY"))
        telegramAPI = TelegramAPI(
            apiUrl: Environment.get("TELEGRAM_API_ENDPOINT"),
            token: try requiredEnvironment("TELEGRAM_BOT_TOKEN")
        )
    }
    
    func boot(routes: any RoutesBuilder) throws {
        let route = routes.grouped("telegram")

        route.get("register", use: registerWebhook)
        route.get("unregister", use: unregisterWebhook)
        route.on(.POST, "webhook", body: .collect(maxSize: "10mb"), use: processWebhook)
    }

    func processWebhook(req: Request) async throws -> TelegramWebhookResponse {
        let webhookSecret = try requiredEnvironment("TELEGRAM_WEBHOOK_SECRET")
        guard req.headers.first(name: "X-Telegram-Bot-Api-Secret-Token") == webhookSecret else {
            throw Abort(.forbidden)
        }

        let update = try req.content.decode(TelegramUpdate.self)
        Task {
            do {
                try await handle(update, req: req)
            } catch {
                req.logger.report(error: error)
            }
        }

        return .init(ok: true)
    }

    func registerWebhook(req _: Request) async throws -> TelegramWebhookResponse {
        try await telegramAPI.callTelegram(
            "setWebhook",
            payload: SetWebhookRequest(
                url: try requiredEnvironment("TELEGRAM_WEBHOOK_URL"),
                secretToken: try requiredEnvironment("TELEGRAM_WEBHOOK_SECRET"),
                allowedUpdates: ["message", "guest_message"]
            )
        )
        return .init(ok: true)
    }

    func unregisterWebhook(req _: Request) async throws -> TelegramWebhookResponse {
        try await telegramAPI.callTelegram("deleteWebhook", payload: DeleteWebhookRequest())
        return .init(ok: true)
    }

    private func handle(_ update: TelegramUpdate, req: Request) async throws {
        if let message = update.guestMessage {
            try await handleGuestMessage(message, req: req)
        } else if let message = update.message {
            try await handleMessage(message, req: req)
        }
    }

    private func handleMessage(_ message: TelegramMessage, req: Request) async throws {
        guard let userText = message.text, !userText.isEmpty else { return }

        try await telegramAPI.callTelegram(
            "sendChatAction",
            payload: SendChatActionRequest(
                chatId: message.chat.id,
                action: "typing",
                messageThreadId: message.messageThreadId
            )
        )

        let draftId = max(message.messageId, 1)
        var lastFlush = Date.distantPast
        let fullText = try await openAI.generateAIText(userText, model: model, httpClient: req.application.http.client.shared) { partialText in
            let now = Date()
            guard now.timeIntervalSince(lastFlush) >= 2.5 else { return }
            try? await telegramAPI.callTelegram(
                "sendRichMessageDraft",
                payload: SendRichMessageDraftRequest(
                    chatId: message.chat.id,
                    draftId: draftId,
                    richMessage: .init(markdown: safeRichMarkdown(partialText)),
                    messageThreadId: message.messageThreadId
                )
            )
            lastFlush = now
        }
        let markdown = safeRichMarkdown(fullText)

        try? await telegramAPI.callTelegram(
            "sendRichMessageDraft",
            payload: SendRichMessageDraftRequest(
                chatId: message.chat.id,
                draftId: draftId,
                richMessage: .init(markdown: markdown),
                messageThreadId: message.messageThreadId
            )
        )
        try await telegramAPI.callTelegram(
            "sendRichMessage",
            payload: SendRichMessageRequest(
                chatId: message.chat.id,
                richMessage: .init(markdown: markdown),
                messageThreadId: message.messageThreadId
            )
        )
    }

    private func handleGuestMessage(_ message: TelegramMessage, req: Request) async throws {
        guard let guestQueryId = message.guestQueryId else {
            req.logger.warning("Guest message does not include guest_query_id")
            return
        }

        try await telegramAPI.callTelegram(
            "answerGuestQuery",
            payload: AnswerGuestQueryRequest(
                guestQueryId: guestQueryId,
                result: .init(
                    id: UUID().uuidString,
                    title: "답변",
                    inputMessageContent: .init(
                        richMessage: .init(markdown: safeRichMarkdown(try await openAI.generateAIText(
                            message.text ?? "",
                            model: model, 
                            httpClient: req.application.http.client.shared
                        )))
                    )
                )
            )
        )
    }

    private func safeRichMarkdown(_ text: String) -> String {
        let text = String(text.prefix(32_768))
        return text.isEmpty ? "응답을 생성하지 못했습니다." : text
    }
}

private struct TelegramUpdate: Content {
    let message: TelegramMessage?
    let guestMessage: TelegramMessage?

    enum CodingKeys: String, CodingKey {
        case message
        case guestMessage = "guest_message"
    }
}

private struct TelegramMessage: Content {
    let messageId: Int
    let chat: TelegramChat
    let messageThreadId: Int?
    let guestQueryId: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case chat
        case messageThreadId = "message_thread_id"
        case guestQueryId = "guest_query_id"
        case text
    }
}

private struct TelegramChat: Content {
    let id: Int64
}

private struct SetWebhookRequest: Content {
    let url: String
    let secretToken: String
    let allowedUpdates: [String]

    enum CodingKeys: String, CodingKey {
        case url
        case secretToken = "secret_token"
        case allowedUpdates = "allowed_updates"
    }
}

private struct DeleteWebhookRequest: Content {}

private struct SendChatActionRequest: Content {
    let chatId: Int64
    let action: String
    let messageThreadId: Int?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case action
        case messageThreadId = "message_thread_id"
    }
}

private struct InputRichMessage: Codable, Sendable {
    let markdown: String
}

private struct SendRichMessageDraftRequest: Content {
    let chatId: Int64
    let draftId: Int
    let richMessage: InputRichMessage
    let messageThreadId: Int?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case draftId = "draft_id"
        case richMessage = "rich_message"
        case messageThreadId = "message_thread_id"
    }
}

private struct SendRichMessageRequest: Content {
    let chatId: Int64
    let richMessage: InputRichMessage
    let messageThreadId: Int?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case richMessage = "rich_message"
        case messageThreadId = "message_thread_id"
    }
}

private struct AnswerGuestQueryRequest: Content {
    struct Result: Codable, Sendable {
        let type = "article"
        let id: String
        let title: String
        let inputMessageContent: InputMessageContent

        enum CodingKeys: String, CodingKey {
            case type, id, title
            case inputMessageContent = "input_message_content"
        }
    }

    struct InputMessageContent: Codable, Sendable {
        let richMessage: InputRichMessage

        enum CodingKeys: String, CodingKey {
            case richMessage = "rich_message"
        }
    }

    let guestQueryId: String
    let result: Result

    enum CodingKeys: String, CodingKey {
        case guestQueryId = "guest_query_id"
        case result
    }
}
