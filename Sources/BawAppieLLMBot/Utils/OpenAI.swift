import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

enum OpenAIError: Error {
    case RequestFailure(String)
    case DecodeFailure(String)
}

struct OpenAI {
    let apiUrl: String = "https://api.openai.com"
    let apiKey: String
    
    func generateAIText(
        _ userText: String,
        model: String,
        httpClient: HTTPClient,
        onPartialText: ((String) async -> Void)? = nil,
    ) async throws -> String {
        let body = try JSONEncoder().encode(ChatCompletionRequest(
            messages: [
                .init(
                    role: "developer",
                    content: "You are BawAppieLLMBot, a helpful Telegram assistant. " +
                        "Answer kindly and politely in Korean using Telegram Rich Markdown, which follows " +
                        "GitHub Flavored Markdown. Use headings, lists, tables, blockquotes, fenced code blocks, " +
                        "and LaTeX formulas when useful. Use tables only when they make structured information clearer."
                ),
                .init(role: "user", content: userText)
            ],
            model: model
        ))
        var request = HTTPClientRequest(url: "\(apiUrl)/v1/chat/completions")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Accept", value: "text/event-stream")
        request.body = .bytes(body)

        let response = try await httpClient.execute(request, timeout: .seconds(60))
        guard response.status == .ok else {
            var errorBody = try await response.body.collect(upTo: 1_048_576)
            let bytes = errorBody.readBytes(length: errorBody.readableBytes) ?? []
            let apiError = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(bytes))
            let reason = apiError?.error.message ?? "OpenAI API request failed (\(response.status.code))"
            throw OpenAIError.RequestFailure("OpenAI chat completions: \(reason)")
        }

        var fullText = ""
        var pending = ByteBufferAllocator().buffer(capacity: 0)
        var eventData: [String] = []
        let decoder = JSONDecoder()

        stream: for try await var chunk in response.body {
            pending.writeBuffer(&chunk)

            while let newlineIndex = pending.readableBytesView.firstIndex(of: 0x0A) {
                var line = pending.readString(length: newlineIndex - pending.readerIndex) ?? ""
                pending.moveReaderIndex(forwardBy: 1)
                if line.last == "\r" { line.removeLast() }

                if line.isEmpty {
                    let data = eventData.joined(separator: "\n")
                    eventData.removeAll(keepingCapacity: true)
                    guard !data.isEmpty else { continue }
                    if data == "[DONE]" { break stream }
                    guard let text = try decodeStreamText(data, decoder: decoder) else { continue }
                    fullText += text
                    await onPartialText?(fullText)
                } else if line.hasPrefix("data:") {
                    var data = line.dropFirst(5)
                    if data.first == " " { data = data.dropFirst() }
                    eventData.append(String(data))
                }
            }

            pending.discardReadBytes()
        }

        return fullText.isEmpty ? "응답을 생성하지 못했습니다." : fullText
    }

    private func decodeStreamText(_ data: String, decoder: JSONDecoder) throws -> String? {
        let data = Data(data.utf8)
        do {
            return try decoder.decode(ChatCompletionStreamResponse.self, from: data).choices.first?.delta.content
        } catch {
            if let apiError = try? decoder.decode(OpenAIErrorResponse.self, from: data) {
                throw OpenAIError.DecodeFailure("OpenAI chat completions: \(apiError.error.message)")
            }
            throw error
        }
    }

    private struct ChatCompletionRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let messages: [Message]
        let model: String
        let stream = true
    }

    private struct ChatCompletionStreamResponse: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }

            let delta: Delta
        }

        let choices: [Choice]
    }

    private struct OpenAIErrorResponse: Decodable {
        struct APIError: Decodable {
            let message: String
        }

        let error: APIError
    }

}
