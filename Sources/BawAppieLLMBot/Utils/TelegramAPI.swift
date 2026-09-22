import Alamofire
import Foundation

enum TelegramAPIError : Error {
    case RequestFailure(String)
}

struct TelegramAPI {
    var apiUrl = "https://api.telegram.org"
    var token: String
    
    init(apiUrl: String?, token: String) {
        if(apiUrl != nil) {
            self.apiUrl = apiUrl!
        }
        self.token = token
    }
    
    func callTelegram<Payload: Encodable & Sendable>(
        _ method: String,
        payload: Payload
    ) async throws {
        let result = try await AF.request(
            "\(apiUrl)/bot\(token)/\(method)",
            method: .post,
            parameters: payload,
            encoder: JSONParameterEncoder.default
        )
        .serializingDecodable(TelegramAPIResponse.self)
        .value

        guard result.ok else {
            throw TelegramAPIError.RequestFailure("Telegram \(method): \(result.errorDescription ?? "request failed")")
        }
    }

    func sendPhoto(_ image: Data, chatId: Int64, messageThreadId: Int?, replyToMessageId: Int) async throws {
        let replyParameters = try JSONEncoder().encode(PhotoReplyParameters(messageId: replyToMessageId))
        let result = try await AF.upload(
            multipartFormData: { form in
                form.append(Data(String(chatId).utf8), withName: "chat_id")
                if let messageThreadId {
                    form.append(Data(String(messageThreadId).utf8), withName: "message_thread_id")
                }
                form.append(replyParameters, withName: "reply_parameters")
                form.append(image, withName: "photo", fileName: "generated.jpg", mimeType: "image/jpeg")
            },
            to: "\(apiUrl)/bot\(token)/sendPhoto",
            method: .post
        )
        .serializingDecodable(TelegramAPIResponse.self)
        .value

        guard result.ok else {
            throw TelegramAPIError.RequestFailure("Telegram sendPhoto: \(result.errorDescription ?? "request failed")")
        }
    }

    func callTelegram<Payload: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String,
        payload: Payload,
        returning: Result.Type
    ) async throws -> Result {
        let response = try await AF.request(
            "\(apiUrl)/bot\(token)/\(method)",
            method: .post,
            parameters: payload,
            encoder: JSONParameterEncoder.default
        )
        .serializingDecodable(TelegramResultResponse<Result>.self)
        .value
        guard response.ok, let result = response.result else {
            throw TelegramAPIError.RequestFailure("Telegram \(method): \(response.errorDescription ?? "missing result")")
        }
        return result
    }
}

struct SentGuestMessage: Decodable, Sendable {
    let inlineMessageId: String

    enum CodingKeys: String, CodingKey {
        case inlineMessageId = "inline_message_id"
    }
}

private struct TelegramResultResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let result: Result?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case ok, result
        case errorDescription = "description"
    }
}

private struct PhotoReplyParameters: Encodable {
    let messageId: Int
    let allowSendingWithoutReply = true

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case allowSendingWithoutReply = "allow_sending_without_reply"
    }
}

private struct TelegramAPIResponse: Decodable, Sendable {
    let ok: Bool
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case errorDescription = "description"
    }
}
