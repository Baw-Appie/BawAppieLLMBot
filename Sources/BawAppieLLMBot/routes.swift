import Vapor

func routes(_ app: Application, conversations: ConversationStore) throws {
    try app.register(collection: TelegramRouteController(conversations: conversations))

    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }
}
