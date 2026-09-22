@testable import BawAppieLLMBot
import Foundation
import Testing

@Suite("Conversation memory")
struct ConversationTests {
    let key = ConversationKey(chatID: -100123, threadID: nil)

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
    }

    @Test("Only the reset command clears memory")
    func resetCommand() {
        #expect(isResetCommand(" /reset\n"))
        #expect(!isResetCommand("Explain /reset"))
        #expect(!isResetCommand("/reset later"))
    }
}
