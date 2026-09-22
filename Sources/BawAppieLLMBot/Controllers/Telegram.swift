import Foundation
import Vapor

struct TelegramWebhookResponse: Content {
    let ok: Bool
}

struct TelegramRouteController: RouteCollection {
    let model = Environment.get("OPENAI_MODEL") ?? "gpt-5.6-luna"
    let imageModel = Environment.get("OPENAI_IMAGE_MODEL") ?? "gpt-image-2.5-flare"
    let openAI: OpenAI
    let telegramAPI: TelegramAPI
    private let generatedImages = GeneratedImageStore()
    private let conversations: ConversationStore
    private let conversationQueue = ConversationQueue()
    
    init(conversations: ConversationStore) throws {
        self.conversations = conversations
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
        route.get("images", ":id", use: generatedImage)
    }

    private func generatedImage(req: Request) async throws -> Response {
        guard let id = req.parameters.get("id"),
              let image = await generatedImages.image(for: id) else {
            throw Abort(.notFound)
        }
        let response = Response(status: .ok, body: .init(data: image))
        response.headers.replaceOrAdd(name: .contentType, value: "image/jpeg")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return response
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
            try await conversationQueue.withLock(message.conversationKey.storageKey) {
                try await handleMessage(message, req: req)
            }
        }
    }

    private func handleMessage(_ message: TelegramMessage, req: Request) async throws {
        guard let userText = message.text, !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isResetCommand(userText) {
            try await conversations.reset(message.conversationKey)
            try await sendImageStatus("이 대화의 기억을 초기화했습니다.", message: message)
            return
        }
        let history = try await conversations.history(for: message.conversationKey)

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
        let reply = try await openAI.generateReply(userText, history: history, model: model, httpClient: req.application.http.client.shared) { partialText in
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
        guard case .text(let fullText) = reply else {
            if case .image(let prompt) = reply {
                try await handleImage(prompt, message: message, req: req)
            }
            return
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
        await remember(user: userText, assistant: markdown, message: message, req: req)
    }

    private func handleImage(_ prompt: String, message: TelegramMessage, req: Request) async throws {
        try await sendImageStatus("이미지를 생성하고 있습니다. 최대 몇 분 정도 걸릴 수 있습니다.", message: message)
        do {
            let image = try await openAI.generateImage(
                prompt,
                model: imageModel,
                httpClient: req.application.http.client.shared
            )
            try? await telegramAPI.callTelegram(
                "sendChatAction",
                payload: SendChatActionRequest(
                    chatId: message.chat.id,
                    action: "upload_photo",
                    messageThreadId: message.messageThreadId
                )
            )
            try await telegramAPI.sendPhoto(
                image,
                chatId: message.chat.id,
                messageThreadId: message.messageThreadId,
                replyToMessageId: message.messageId
            )
            await remember(
                user: message.text ?? prompt,
                assistant: "이미지를 생성해 전송했습니다. 생성 프롬프트: \(prompt)",
                message: message, req: req
            )
        } catch {
            req.logger.report(error: error)
            try await sendImageStatus("이미지를 생성하거나 전송하지 못했습니다. 잠시 후 다시 시도해 주세요.", message: message)
        }
    }

    private func sendImageStatus(_ text: String, message: TelegramMessage) async throws {
        try await telegramAPI.callTelegram(
            "sendRichMessage",
            payload: SendRichMessageRequest(
                chatId: message.chat.id,
                richMessage: .init(markdown: text),
                messageThreadId: message.messageThreadId
            )
        )
    }

    private func handleGuestMessage(_ message: TelegramMessage, req: Request) async throws {
        guard let guestQueryId = message.guestQueryId else {
            req.logger.warning("Guest message does not include guest_query_id")
            return
        }

        guard let userText = message.text, !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Answer promptly, then edit this inline message when generation finishes.
        let sent = try await telegramAPI.callTelegram(
            "answerGuestQuery",
            payload: AnswerGuestQueryRequest(
                guestQueryId: guestQueryId,
                result: .init(
                    id: UUID().uuidString,
                    title: "답변",
                    inputMessageContent: .init(
                        richMessage: .init(markdown: "생각하고 있습니다…")
                    )
                )
            ),
            returning: SentGuestMessage.self
        )

        do {
            try await conversationQueue.withLock(message.conversationKey.storageKey) {
                try await completeGuestMessage(message, userText: userText, sent: sent, req: req)
            }
        } catch {
            req.logger.report(error: error)
            try await editGuestText("답변을 생성하거나 전송하지 못했습니다. 잠시 후 다시 시도해 주세요.", inlineMessageId: sent.inlineMessageId)
        }
    }

    private func completeGuestMessage(
        _ message: TelegramMessage, userText: String, sent: SentGuestMessage, req: Request
    ) async throws {
        if isResetCommand(userText) {
            try await conversations.reset(message.conversationKey)
            try await editGuestText("이 대화의 기억을 초기화했습니다.", inlineMessageId: sent.inlineMessageId)
            return
        }
        let history = try await conversations.history(for: message.conversationKey)
        let reply = try await openAI.generateReply(
            userText, history: history, model: model, httpClient: req.application.http.client.shared
        )
        let rememberedReply: String
        switch reply {
        case .text(let text):
            try await editGuestText(text, inlineMessageId: sent.inlineMessageId)
            rememberedReply = safeRichMarkdown(text)
        case .image(let prompt):
            try await editGuestText("이미지를 생성하고 있습니다…", inlineMessageId: sent.inlineMessageId)
            let baseURL = try GeneratedImageStore.baseURL(webhookURL: requiredEnvironment("TELEGRAM_WEBHOOK_URL"))
            let image = try await openAI.generateImage(
                prompt, model: imageModel, httpClient: req.application.http.client.shared
            )
            let id = try await generatedImages.insert(image)
            do {
                try await telegramAPI.callTelegram(
                    "editMessageMedia",
                    payload: EditGuestPhotoRequest(
                        inlineMessageId: sent.inlineMessageId,
                        media: .init(media: baseURL.appendingPathComponent(id).absoluteString)
                    )
                )
            } catch {
                await generatedImages.remove(id)
                throw error
            }
            rememberedReply = "이미지를 생성해 전송했습니다. 생성 프롬프트: \(prompt)"
        }
        await remember(user: userText, assistant: rememberedReply, message: message, req: req)
    }

    private func remember(user: String, assistant: String, message: TelegramMessage, req: Request) async {
        do {
            try await conversations.append(user: user, assistant: assistant, for: message.conversationKey)
        } catch {
            // A persistence failure must not replace an already delivered answer with an error.
            req.logger.error("Failed to save conversation history")
            req.logger.report(error: error)
        }
    }

    private func editGuestText(_ text: String, inlineMessageId: String) async throws {
        try await telegramAPI.callTelegram(
            "editMessageText",
            payload: EditGuestTextRequest(
                inlineMessageId: inlineMessageId,
                richMessage: .init(markdown: safeRichMarkdown(text))
            )
        )
    }

    private func safeRichMarkdown(_ text: String) -> String {
        let text = String(text.prefix(32_768))
        return text.isEmpty ? "응답을 생성하지 못했습니다." : text
    }
}

func isResetCommand(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines) == "/reset"
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

    var conversationKey: ConversationKey { .init(chatID: chat.id, threadID: messageThreadId) }

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

private struct EditGuestTextRequest: Content {
    let inlineMessageId: String
    let richMessage: InputRichMessage

    enum CodingKeys: String, CodingKey {
        case inlineMessageId = "inline_message_id"
        case richMessage = "rich_message"
    }
}

private struct EditGuestPhotoRequest: Encodable, Sendable {
    struct Media: Encodable, Sendable {
        let type = "photo"
        let media: String
    }

    let inlineMessageId: String
    let media: Media

    enum CodingKeys: String, CodingKey {
        case inlineMessageId = "inline_message_id"
        case media
    }
}
