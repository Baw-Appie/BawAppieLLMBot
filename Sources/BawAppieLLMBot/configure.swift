import Vapor

/// configures your application
func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // register routes
    let conversations = try await ConversationStore.open(
        path: Environment.get("CONVERSATION_DB_PATH") ?? (app.environment == .testing ? ":memory:" : "db.sqlite")
    )
    app.lifecycle.use(ConversationStoreLifecycle(store: conversations))
    try routes(app, conversations: conversations)
}

private struct ConversationStoreLifecycle: LifecycleHandler {
    let store: ConversationStore

    func shutdownAsync(_ application: Application) async {
        do { try await store.close() }
        catch { application.logger.report(error: error) }
    }
}
