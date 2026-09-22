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

    func generateImage(_ prompt: String, model: String, httpClient: HTTPClient) async throws -> Data {
        var request = HTTPClientRequest(url: "\(apiUrl)/v1/images/generations")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(try JSONEncoder().encode(ImageGenerationRequest(model: model, prompt: prompt)))

        let response = try await httpClient.execute(request, timeout: .seconds(180))
        guard response.status == .ok else {
            var body = try await response.body.collect(upTo: 1_048_576)
            let bytes = body.readBytes(length: body.readableBytes) ?? []
            let apiError = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(bytes))
            throw OpenAIError.RequestFailure(
                "OpenAI image generation: \(apiError?.error.message ?? "HTTP \(response.status.code)")"
            )
        }

        // Allow for Base64 overhead while keeping the response bounded.
        var body = try await response.body.collect(upTo: 16 * 1_024 * 1_024)
        let bytes = body.readBytes(length: body.readableBytes) ?? []
        return try JSONDecoder().decode(ImageGenerationResponse.self, from: Data(bytes)).imageData()
    }
    
    func generateReply(
        _ userText: String,
        model: String,
        httpClient: HTTPClient,
        onPartialText: ((String) async -> Void)? = nil,
    ) async throws -> OpenAIReply {
        let body = try JSONEncoder().encode(ResponsesRequest(
            input: [
                .init(
                    role: "developer",
                    content: "You are BawAppieLLMBot, a helpful Telegram assistant. " +
                        "Answer kindly and politely in Korean using Telegram Rich Markdown, which follows " +
                        "GitHub Flavored Markdown. Use headings, lists, tables, blockquotes, fenced code blocks, " +
                        "and LaTeX formulas when useful. Use tables only when they make structured information clearer. " +
                        "When the user asks you to draw or generate an image (for example, '고양이 그려줘'), " +
                        "call generate_image with a self-contained prompt preserving their requested details. " +
                        "No special command is needed. Do not call it for questions about images, requests for " +
                        "drawing instructions or code, quoted examples, or requests not to generate an image. " +
                        "If the subject is unclear, ask a short clarification. Generate at most one image."
                ),
                .init(role: "user", content: userText)
            ],
            model: model
        ))
        var request = HTTPClientRequest(url: "\(apiUrl)/v1/responses")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Accept", value: "text/event-stream")
        request.body = .bytes(body)

        let response = try await httpClient.execute(request, timeout: .seconds(180))
        guard response.status == .ok else {
            var errorBody = try await response.body.collect(upTo: 1_048_576)
            let bytes = errorBody.readBytes(length: errorBody.readableBytes) ?? []
            let apiError = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(bytes))
            let reason = apiError?.error.message ?? "OpenAI API request failed (\(response.status.code))"
            throw OpenAIError.RequestFailure("OpenAI responses: \(reason)")
        }

        var partialText = ""
        var hasToolCall = false
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
                    let event = try decodeStreamEvent(data, decoder: decoder)
                    switch event.type {
                    case "response.output_text.delta", "response.refusal.delta":
                        if let delta = event.delta {
                            partialText += delta
                            if !hasToolCall { await onPartialText?(partialText) }
                        }
                    case "response.output_item.added":
                        if event.item?.type == "function_call" { hasToolCall = true }
                    case "response.completed":
                        guard let completed = event.response else {
                            throw OpenAIError.DecodeFailure("OpenAI responses: missing completed response")
                        }
                        return try completed.reply()
                    case "response.failed", "response.incomplete", "error":
                        let reason = event.response?.error?.message ?? event.message
                            ?? event.response?.incompleteDetails?.reason ?? event.type
                        throw OpenAIError.RequestFailure("OpenAI responses: \(reason)")
                    default:
                        break
                    }
                } else if line.hasPrefix("data:") {
                    var data = line.dropFirst(5)
                    if data.first == " " { data = data.dropFirst() }
                    eventData.append(String(data))
                }
            }

            pending.discardReadBytes()
        }

        throw OpenAIError.DecodeFailure("OpenAI responses: stream ended before response.completed")
    }

    private func decodeStreamEvent(_ data: String, decoder: JSONDecoder) throws -> ResponsesStreamEvent {
        let data = Data(data.utf8)
        do {
            return try decoder.decode(ResponsesStreamEvent.self, from: data)
        } catch {
            if let apiError = try? decoder.decode(OpenAIErrorResponse.self, from: data) {
                throw OpenAIError.DecodeFailure("OpenAI responses: \(apiError.error.message)")
            }
            throw error
        }
    }

    private struct ResponsesRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let input: [Message]
        let model: String
        let stream = true
        let store = false
        let tools = [ImageGenerationTool()]
        let parallelToolCalls = false

        enum CodingKeys: String, CodingKey {
            case input, model, stream, store, tools
            case parallelToolCalls = "parallel_tool_calls"
        }
    }

    private struct OpenAIErrorResponse: Decodable {
        struct APIError: Decodable {
            let message: String
        }

        let error: APIError
    }

}

private struct ImageGenerationRequest: Encodable {
    let model: String
    let prompt: String
    let n = 1
    let size = "1024x1024"
    let quality = "medium"
    let outputFormat = "jpeg"

    enum CodingKeys: String, CodingKey {
        case model, prompt, n, size, quality
        case outputFormat = "output_format"
    }
}

private struct ImageGenerationResponse: Decodable {
    struct Image: Decodable {
        let base64: String?

        enum CodingKeys: String, CodingKey {
            case base64 = "b64_json"
        }
    }

    let data: [Image]

    func imageData() throws -> Data {
        guard let base64 = data.first?.base64,
              let image = Data(base64Encoded: base64), !image.isEmpty else {
            throw OpenAIError.DecodeFailure("OpenAI image generation returned no valid image")
        }
        guard image.count <= 10_000_000 else {
            throw OpenAIError.DecodeFailure("Generated image exceeds Telegram's 10 MB photo limit")
        }
        return image
    }
}

enum OpenAIReply {
    case text(String)
    case image(prompt: String)
}

private struct ImageGenerationTool: Encodable {
    let type = "function"
    let name = "generate_image"
    let description = "Generate an image when the user asks to draw or create a picture."
    let strict = true
    let parameters = Parameters()

    struct Parameters: Encodable {
        let type = "object"
        let properties = ["prompt": Property()]
        let required = ["prompt"]
        let additionalProperties = false
    }

    struct Property: Encodable {
        let type = "string"
        let description = "A complete description of the image the user wants, including style and details."
    }
}

private struct ResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    let item: ResponsesOutputItem?
    let response: ResponsesResult?
    let message: String?
}

private struct ResponsesOutputItem: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String?
        let refusal: String?
    }

    let type: String
    let status: String?
    let name: String?
    let arguments: String?
    let content: [Content]?
}

private struct ResponsesResult: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    struct IncompleteDetails: Decodable {
        let reason: String
    }

    let status: String
    let output: [ResponsesOutputItem]
    let error: APIError?
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case status, output, error
        case incompleteDetails = "incomplete_details"
    }

    func reply() throws -> OpenAIReply {
        guard status == "completed", error == nil else {
            throw OpenAIError.RequestFailure("OpenAI responses: \(error?.message ?? status)")
        }
        let toolCalls = output.filter { $0.type == "function_call" }
        if let call = toolCalls.first {
            guard toolCalls.count == 1, call.name == "generate_image",
                  call.status == nil || call.status == "completed",
                  let arguments = call.arguments, arguments.utf8.count <= 128_000 else {
                throw OpenAIError.DecodeFailure("OpenAI responses: invalid image tool call")
            }
            struct Arguments: Decodable { let prompt: String }
            let prompt = try JSONDecoder().decode(Arguments.self, from: Data(arguments.utf8))
                .prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty, prompt.count <= 32_000 else {
                throw OpenAIError.DecodeFailure("Invalid image prompt")
            }
            return .image(prompt: prompt)
        }

        let text = output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
            .compactMap { content -> String? in
                switch content.type {
                case "output_text": return content.text
                case "refusal": return content.refusal
                default: return nil
                }
            }.joined(separator: "\n")
        return .text(text.isEmpty ? "응답을 생성하지 못했습니다." : text)
    }
}
