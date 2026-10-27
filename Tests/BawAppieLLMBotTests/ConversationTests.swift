@testable import BawAppieLLMBot
import Foundation
import Testing

@Suite("Conversation memory")
struct ConversationTests {
    let key = ConversationKey(chatID: -100123, threadID: nil)

    @Test("Only groups expire after at least 24 hours without activity",
          arguments: ["group", "supergroup", "private", "channel"], [86_399.0, 86_400.0, 86_401.0])
    func inactivityBoundary(chatType: String, elapsed: TimeInterval) async throws {
        let store = try await ConversationStore.open(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_000_000)
        try await store.recordActivity(for: key, chatType: chatType, at: start)
        try await store.append(user: "이전 질문", assistant: "이전 답변", for: key, at: start)
        try await store.recordActivity(for: key, chatType: chatType, at: start.addingTimeInterval(elapsed))

        let shouldExpire = ["group", "supergroup"].contains(chatType) && elapsed >= 86_400
        #expect(try await store.history(for: key).isEmpty == shouldExpire)
        try await store.close()
    }

    @Test("Messages without saved replies and delivered replies both extend group activity")
    func activityExtendsDeadline() async throws {
        let store = try await ConversationStore.open(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_000_000)
        try await store.recordActivity(for: key, chatType: "group", at: start)
        try await store.append(user: "질문", assistant: "답변", for: key, at: start.addingTimeInterval(60))
        try await store.recordActivity(for: key, chatType: "group", at: start.addingTimeInterval(86_400))
        #expect(try await store.history(for: key).count == 2)
        try await store.recordActivity(for: key, chatType: "group", at: start.addingTimeInterval(172_799))
        #expect(try await store.history(for: key).count == 2)
        // A delayed timestamp must not move the deadline backwards.
        try await store.recordActivity(for: key, chatType: "group", at: start)
        try await store.recordActivity(for: key, chatType: "group", at: start.addingTimeInterval(259_198))
        #expect(try await store.history(for: key).count == 2)
        try await store.recordActivity(for: key, chatType: "group", at: start.addingTimeInterval(345_598))
        #expect(try await store.history(for: key).isEmpty)
        try await store.append(user: "새 질문", assistant: "새 답변", for: key, at: start.addingTimeInterval(345_600))
        #expect(try await store.history(for: key).map(\.content) == ["새 질문", "새 답변"])
        try await store.close()
    }

    @Test("Inactivity survives restarting and expires only the matching room/topic")
    func inactivityPersistenceAndIsolation() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("conversation-\(UUID()).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let store = try await ConversationStore.open(path: path)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let otherRoom = ConversationKey(chatID: -456, threadID: nil)
        let otherTopic = ConversationKey(chatID: key.chatID, threadID: 7)
        for conversation in [key, otherRoom, otherTopic] {
            // Pre-existing history has no activity timestamp: preserve it and start tracking now.
            try await store.append(user: "기존 질문", assistant: "기존 답변", for: conversation, at: start)
            try await store.recordActivity(for: conversation, chatType: "supergroup", at: start)
            #expect(try await store.history(for: conversation).count == 2)
        }
        try await store.close()

        let reopened = try await ConversationStore.open(path: path)
        try await reopened.recordActivity(for: key, chatType: "supergroup", at: start.addingTimeInterval(86_400))
        #expect(try await reopened.history(for: key).isEmpty)
        #expect(try await reopened.history(for: otherRoom).count == 2)
        #expect(try await reopened.history(for: otherTopic).count == 2)
        try await reopened.close()
        let afterExpiry = try await ConversationStore.open(path: path)
        #expect(try await afterExpiry.history(for: key).isEmpty)
        try await afterExpiry.close()
    }

    @Test("History survives reopening, prunes to 20 pairs, and resets only its own room/topic")
    func persistenceAndIsolation() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-\(UUID()).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let store = try await ConversationStore.open(path: path)
        let otherRoom = ConversationKey(chatID: 42, threadID: nil)
        let otherTopic = ConversationKey(chatID: key.chatID, threadID: 7)
        for index in 0..<25 {
            try await store.append(user: "질문 \(index)", assistant: "답변 \(index)", for: key)
        }
        try await store.append(user: "다른 방", assistant: "비밀", for: otherRoom)
        try await store.append(user: "다른 토픽", assistant: "주제", for: otherTopic)
        try await store.close()

        let reopened = try await ConversationStore.open(path: path)
        let history = try await reopened.history(for: key)
        #expect(history.count == 40)
        #expect(history.first == .init(role: .user, content: "질문 5"))
        #expect(history.last == .init(role: .assistant, content: "답변 24"))
        try await reopened.reset(key)
        #expect(try await reopened.history(for: key).isEmpty)
        #expect(try await reopened.history(for: otherRoom).first?.content == "다른 방")
        #expect(try await reopened.history(for: otherTopic).first?.content == "다른 토픽")
        try await reopened.close()
        let afterReset = try await ConversationStore.open(path: path)
        #expect(try await afterReset.history(for: key).isEmpty)
        try await afterReset.close()
    }

    @Test("UTF-8 budget retains a recent suffix of complete pairs")
    func historyBudget() async throws {
        let store = try await ConversationStore.open(path: ":memory:", maxHistoryBytes: 12)
        try await store.append(user: "old", assistant: "old", for: key)
        try await store.append(user: "한글", assistant: "답변", for: key)
        #expect(try await store.history(for: key) == [
            .init(role: .user, content: "한글"), .init(role: .assistant, content: "답변")
        ])
        try await store.append(user: "too long for the budget", assistant: "answer", for: key)
        #expect(try await store.history(for: key).isEmpty)
        try await store.close()
    }

    @Test("SQL parameters preserve quotes, Unicode, and injection-like text")
    func boundParameters() async throws {
        let store = try await ConversationStore.open(path: ":memory:")
        let text = "한글 '); DROP TABLE conversation_turns; --\n🐱"
        try await store.append(user: text, assistant: text, for: key)
        #expect(try await store.history(for: key).map(\.content) == [text, text])
        try await store.close()
    }

    @Test("Overlapping turns read the completed prior turn")
    func concurrentTurns() async throws {
        let store = try await ConversationStore.open(path: ":memory:", maxTurns: 50)
        let queue = ConversationQueue()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    try await queue.withLock(key.storageKey) {
                        let count = try await store.history(for: key).count / 2
                        await Task.yield()
                        try await store.append(user: "\(count)", assistant: "\(count)", for: key)
                    }
                }
            }
            try await group.waitForAll()
        }
        let history = try await store.history(for: key)
        #expect(history.filter { $0.role == .user }.map(\.content) == (0..<30).map(String.init))
        try await store.close()
    }

    @Test("A slow room does not block another room; thrown operations release their lock")
    func independentRoomsAndFailure() async throws {
        let queue = ConversationQueue()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let slow = Task {
            await queue.withLock("room-a") {
                startedContinuation.yield(())
                for await _ in release { break }
            }
        }
        for await _ in started { break }
        await queue.withLock("room-b") { _ = releaseContinuation.yield(()) }
        await slow.value
        enum Expected: Error { case failure }
        do {
            try await queue.withLock("room-a") { throw Expected.failure }
            Issue.record("Expected error")
        } catch Expected.failure { }
        let result = await queue.withLock("room-a") { "released" }
        #expect(result == "released")
    }

    @Test("Responses input preserves roles and chronological history before the current question")
    func requestHistory() throws {
        let history: [ConversationMessage] = [
            .init(role: .user, content: "내 이름은 지훈"),
            .init(role: .assistant, content: "반갑습니다.")
        ]
        let body = try OpenAI(apiKey: "test").replyRequestBody("내 이름은?", history: history, model: "test")
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(json["input"] as? [[String: String]])
        #expect(input.map { $0["role"] } == ["developer", "user", "assistant", "user"])
        #expect(input.dropFirst().map { $0["content"] } == ["내 이름은 지훈", "반갑습니다.", "내 이름은?"])
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.map { $0["type"] as? String } == ["web_search", "function"])
        #expect(tools.last?["name"] as? String == "generate_image")
    }

    @Test("An attached image becomes an input_image content part alongside the caption")
    func imageAttachmentInput() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let attachment = try ImageAttachment(mimeType: "image/PNG", data: png)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.dataURL == "data:image/png;base64,\(png.base64EncodedString())")

        let body = try OpenAI(apiKey: "test").replyRequestBody(
            "이거 뭔지 알려줘", attachments: [attachment], history: [], model: "test"
        )
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 2)
        let parts = try #require(input.last?["content"] as? [[String: Any]])
        #expect(parts.map { $0["type"] as? String } == ["input_text", "input_image"])
        #expect(parts.first?["text"] as? String == "이거 뭔지 알려줘")
        #expect(parts.last?["image_url"] as? String == attachment.dataURL)
        // Text-only turns must stay plain strings so existing history keeps working.
        #expect(input.first?["content"] as? String != nil)
    }

    @Test("Unsupported types and oversized or empty payloads are rejected")
    func imageAttachmentValidation() throws {
        #expect(throws: OpenAIError.self) {
            try ImageAttachment(mimeType: "image/heic", data: Data([0x01]))
        }
        #expect(throws: OpenAIError.self) {
            try ImageAttachment(mimeType: "image/jpeg", data: Data())
        }
        #expect(throws: OpenAIError.self) {
            try ImageAttachment(
                mimeType: "image/jpeg",
                data: Data(repeating: 0, count: ImageAttachment.maxBytes + 1)
            )
        }
    }

    @Test("Web citations become clickable Telegram Markdown links")
    func webCitations() throws {
        let marker = "citeturn0search0"
        let text = "오늘 소식입니다. \(marker)"
        let startIndex = "오늘 소식입니다. ".utf16.count
        let response: [String: Any] = [
            "status": "completed",
            "output": [
                ["type": "web_search_call", "status": "completed"],
                [
                    "type": "message",
                    "status": "completed",
                    "content": [[
                        "type": "output_text",
                        "text": text,
                        "annotations": [[
                            "type": "url_citation",
                            "start_index": startIndex,
                            "end_index": text.utf16.count,
                            "url": "https://example.com/news",
                            "title": "뉴스"
                        ]]
                    ]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)

        let reply = try JSONDecoder().decode(ResponsesResult.self, from: data).reply()
        guard case .text(let rendered) = reply else {
            Issue.record("Expected a text response")
            return
        }
        #expect(rendered == "오늘 소식입니다. [출처](https://example.com/news)")
    }

    @Test("Invalid citation ranges fall back to a deduplicated source list")
    func citationFallback() {
        let citation = WebCitation(
            type: "url_citation",
            startIndex: 100,
            endIndex: 110,
            url: "https://example.com/news",
            title: "뉴스 [원문]"
        )

        #expect(renderCitations(in: "답변", citations: [citation, citation]) ==
            "답변\n\n### 출처\n- [뉴스 \\[원문\\]](https://example.com/news)")
    }

    @Test("Only the reset command clears memory")
    func resetCommand() {
        #expect(isResetCommand(" /reset\n"))
        #expect(!isResetCommand("Explain /reset"))
        #expect(!isResetCommand("/reset later"))
    }

    @Test("The magic string clears memory anywhere in the message")
    func magicStringReset() {
        #expect(shouldResetContext(contextResetTrigger))
        #expect(shouldResetContext("지금 \(contextResetTrigger) 부탁해"))
        #expect(shouldResetContext("bawappie_magic_string_trigger_context_reset"))
        #expect(shouldResetContext(" /reset\n"))
        #expect(!shouldResetContext("BAWAPPIE_MAGIC_STRING"))
        #expect(!shouldResetContext("현재 매직 스트링이 뭔지 알려줘"))
    }
}
