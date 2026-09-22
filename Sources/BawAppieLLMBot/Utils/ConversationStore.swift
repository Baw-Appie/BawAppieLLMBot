import Foundation
import SQLiteNIO

struct ConversationKey: Hashable, Sendable {
    let chatID: Int64
    let threadID: Int?

    var storageKey: String { "\(chatID):\(threadID ?? 0)" }
}

struct ConversationMessage: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let content: String
}

/// Serializes whole asynchronous operations, including across suspension points.
/// An actor alone would allow another turn to read history while a reply is pending.
actor ConversationQueue {
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<T: Sendable>(
        _ key: String,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        if waiters[key] == nil {
            waiters[key] = []
        } else {
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        }
        defer {
            if var pending = waiters[key], !pending.isEmpty {
                let next = pending.removeFirst()
                waiters[key] = pending
                next.resume()
            } else {
                waiters.removeValue(forKey: key)
            }
        }
        return try await operation()
    }
}

/// SQLiteNIO runs disk operations on its thread pool, outside Vapor's event loops.
final class ConversationStore: Sendable {
    private let connection: SQLiteConnection
    private let databaseQueue = ConversationQueue()
    let maxTurns: Int
    let maxHistoryBytes: Int

    private init(connection: SQLiteConnection, maxTurns: Int, maxHistoryBytes: Int) {
        self.connection = connection
        self.maxTurns = maxTurns
        self.maxHistoryBytes = maxHistoryBytes
    }

    static func open(path: String, maxTurns: Int = 20, maxHistoryBytes: Int = 64_000) async throws -> ConversationStore {
        guard maxTurns > 0, maxHistoryBytes > 0 else {
            throw ConfigurationError.invalidLimits
        }
        let connection = try await SQLiteConnection.open(
            storage: path == ":memory:" ? .memory : .file(path: path)
        ).get()
        do {
            _ = try await connection.query("PRAGMA busy_timeout = 5000").get()
            _ = try await connection.query("PRAGMA journal_mode = WAL").get()
            _ = try await connection.query("""
                CREATE TABLE IF NOT EXISTS conversation_turns (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_key TEXT NOT NULL,
                    user_text TEXT NOT NULL,
                    assistant_text TEXT NOT NULL
                )
                """).get()
            _ = try await connection.query("""
                CREATE INDEX IF NOT EXISTS conversation_turns_key_id
                ON conversation_turns (conversation_key, id)
                """).get()
            return ConversationStore(connection: connection, maxTurns: maxTurns, maxHistoryBytes: maxHistoryBytes)
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    func history(for key: ConversationKey) async throws -> [ConversationMessage] {
        try await databaseQueue.withLock("database") {
            let rows = try await self.connection.query("""
                SELECT user_text, assistant_text FROM conversation_turns
                WHERE conversation_key = ? ORDER BY id DESC LIMIT ?
                """, [.text(key.storageKey), .integer(.init(self.maxTurns))]).get()
            var turns: [[ConversationMessage]] = []
            var byteCount = 0
            for row in rows {
                guard let user = row.column("user_text")?.string,
                      let assistant = row.column("assistant_text")?.string else { continue }
                let size = user.utf8.count + assistant.utf8.count
                guard byteCount + size <= self.maxHistoryBytes else { break }
                byteCount += size
                turns.append([.init(role: .user, content: user), .init(role: .assistant, content: assistant)])
            }
            return turns.reversed().flatMap { $0 }
        }
    }

    /// Save only a successfully delivered question/answer pair, then prune atomically.
    func append(user: String, assistant: String, for key: ConversationKey) async throws {
        try await databaseQueue.withLock("database") {
            _ = try await self.connection.query("BEGIN IMMEDIATE").get()
            do {
                _ = try await self.connection.query("""
                    INSERT INTO conversation_turns (conversation_key, user_text, assistant_text)
                    VALUES (?, ?, ?)
                    """, [.text(key.storageKey), .text(user), .text(assistant)]).get()
                _ = try await self.connection.query("""
                    DELETE FROM conversation_turns WHERE conversation_key = ? AND id NOT IN (
                        SELECT id FROM conversation_turns WHERE conversation_key = ? ORDER BY id DESC LIMIT ?
                    )
                    """, [.text(key.storageKey), .text(key.storageKey), .integer(.init(self.maxTurns))]).get()
                _ = try await self.connection.query("COMMIT").get()
            } catch {
                _ = try? await self.connection.query("ROLLBACK").get()
                throw error
            }
        }
    }

    func reset(_ key: ConversationKey) async throws {
        try await databaseQueue.withLock("database") {
            _ = try await self.connection.query(
                "DELETE FROM conversation_turns WHERE conversation_key = ?", [.text(key.storageKey)]
            ).get()
        }
    }

    func close() async throws {
        try await databaseQueue.withLock("database") { try await self.connection.close().get() }
    }

    enum ConfigurationError: Error { case invalidLimits }
}
