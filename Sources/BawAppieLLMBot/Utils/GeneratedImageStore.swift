import Foundation

/// Short-lived, unguessable URLs used by Telegram to fetch guest reply images.
actor GeneratedImageStore {
    enum StoreError: Error {
        case invalidWebhookURL
        case imageTooLarge
        case capacityExceeded
    }

    private struct Entry {
        let data: Data
        let expiresAt: Date
    }

    private let lifetime: TimeInterval = 600
    private let maxBytes = 32_000_000
    private var entries: [String: Entry] = [:]

    static func baseURL(webhookURL: String) throws -> URL {
        guard var components = URLComponents(string: webhookURL),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.path.hasSuffix("/telegram/webhook") else {
            throw StoreError.invalidWebhookURL
        }
        components.path = String(components.path.dropLast("webhook".count)) + "images"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw StoreError.invalidWebhookURL }
        return url
    }

    func insert(_ data: Data) throws -> String {
        let now = Date()
        removeExpired(now: now)
        guard !data.isEmpty, data.count <= 5_000_000 else { throw StoreError.imageTooLarge }
        guard entries.values.reduce(0, { $0 + $1.data.count }) + data.count <= maxBytes else {
            throw StoreError.capacityExceeded
        }
        let id = UUID().uuidString + ".jpg"
        entries[id] = Entry(data: data, expiresAt: now.addingTimeInterval(lifetime))
        return id
    }

    func image(for id: String) -> Data? {
        removeExpired(now: Date())
        return entries[id]?.data
    }

    func remove(_ id: String) {
        entries[id] = nil
    }

    private func removeExpired(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }
}
