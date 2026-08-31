import Vapor

func requiredEnvironment(_ name: String) throws -> String {
    guard let value = Environment.get(name), !value.isEmpty else {
        throw Abort(.internalServerError, reason: "Missing environment variable: \(name)")
    }
    return value
}
