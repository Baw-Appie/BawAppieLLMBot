import Alamofire
import Foundation

enum TelegramAPIError : Error {
    case RequestFailure(String)

    var message: String {
        switch self {
        case .RequestFailure(let message): return message
        }
    }
}

extension TelegramAPIError: LocalizedError {
    var errorDescription: String? { message }
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

    /// Resolves a `file_id` to a download path, then fetches the bytes.
    /// Telegram's Bot API only serves files up to 20 MB through this route.
    func downloadFile(fileId: String, maxBytes: Int) async throws -> Data {
        let file = try await callTelegram(
            "getFile", payload: GetFileRequest(fileId: fileId), returning: TelegramFile.self
        )
        if let size = file.fileSize, size > maxBytes {
            throw TelegramAPIError.RequestFailure("Telegram getFile: file is larger than \(maxBytes) bytes")
        }
        guard let path = file.filePath, !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else {
            throw TelegramAPIError.RequestFailure("Telegram getFile: missing usable file_path")
        }
        let escaped = path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let response = await AF.request("\(apiUrl)/file/bot\(token)/\(escaped)")
            .serializingData()
            .response
        guard let status = response.response?.statusCode, status == 200, let data = response.data else {
            throw TelegramAPIError.RequestFailure(
                "Telegram file download failed (HTTP \(response.response?.statusCode ?? 0))"
            )
        }
        guard !data.isEmpty, data.count <= maxBytes else {
            throw TelegramAPIError.RequestFailure("Telegram file download returned an unusable payload")
        }
        return data
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

private struct GetFileRequest: Encodable, Sendable {
    let fileId: String

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
    }
}

struct TelegramFile: Decodable, Sendable {
    let filePath: String?
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileSize = "file_size"
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
