import Alamofire

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
}

private struct TelegramAPIResponse: Decodable, Sendable {
    let ok: Bool
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case errorDescription = "description"
    }
}
