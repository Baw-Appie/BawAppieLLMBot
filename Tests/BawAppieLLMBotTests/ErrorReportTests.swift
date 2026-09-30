@testable import BawAppieLLMBot
import Foundation
import Testing

@Suite("OpenAI error reporting")
struct ErrorReportTests {
    private func reply(from response: [String: Any]) throws -> OpenAIReply {
        let data = try JSONSerialization.data(withJSONObject: response)
        return try JSONDecoder().decode(ResponsesResult.self, from: data).reply()
    }

    @Test("A failed response surfaces OpenAI's message and code")
    func failedResponse() throws {
        do {
            _ = try reply(from: [
                "status": "failed",
                "output": [],
                "error": ["message": "Rate limit reached", "code": "rate_limit_exceeded"]
            ])
            Issue.record("Expected a failure")
        } catch let error as OpenAIError {
            #expect(error.message == "OpenAI responses: Rate limit reached [rate_limit_exceeded]")
        }
    }

    @Test("An incomplete response surfaces the stop reason")
    func incompleteResponse() throws {
        do {
            _ = try reply(from: [
                "status": "incomplete",
                "output": [],
                "incomplete_details": ["reason": "max_output_tokens"]
            ])
            Issue.record("Expected a failure")
        } catch let error as OpenAIError {
            #expect(error.message == "OpenAI responses: incomplete: max_output_tokens")
        }
    }

    @Test("An unexpected status is reported verbatim")
    func unexpectedStatus() throws {
        do {
            _ = try reply(from: ["status": "queued", "output": []])
            Issue.record("Expected a failure")
        } catch let error as OpenAIError {
            #expect(error.message == "OpenAI responses: status queued")
        }
    }

    @Test("errorReport renders the upstream text in a fenced block")
    func reportFormatting() {
        let report = errorReport(OpenAIError.RequestFailure("OpenAI responses: bad `model`"))
        #expect(report == "요청을 처리하지 못했습니다.\n\n```\nOpenAI responses: bad 'model'\n```")
    }

    @Test("errorReport describes errors without a localized message")
    func reportFallback() {
        enum Sample: Error { case boom }
        #expect(errorReport(Sample.boom).contains("boom"))
        #expect(errorReport(TelegramAPIError.RequestFailure("Telegram sendPhoto: too big"))
            .contains("Telegram sendPhoto: too big"))
    }
}
