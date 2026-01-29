import Foundation

@MainActor
class ConversationManager: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentConversationId: UUID?

    private let fileManager = FileManager.default

    private var conversationsDirectory: URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("conversations")
    }

    init() {
        createConversationsDirectoryIfNeeded()
        loadConversations()
    }

    private func createConversationsDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: conversationsDirectory.path) {
            try? fileManager.createDirectory(at: conversationsDirectory, withIntermediateDirectories: true)
        }
    }

    func loadConversations() {
        guard let files = try? fileManager.contentsOfDirectory(at: conversationsDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        let decoder = JSONDecoder()
        var loaded: [Conversation] = []

        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let conversation = try? decoder.decode(Conversation.self, from: data) {
                loaded.append(conversation)
            }
        }

        // Sort by most recently updated
        conversations = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversation: Conversation) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        let fileURL = conversationsDirectory.appendingPathComponent("\(conversation.id.uuidString).json")

        if let data = try? encoder.encode(conversation) {
            try? data.write(to: fileURL)
        }

        // Update in-memory list
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }

        // Re-sort by most recent
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    func delete(_ conversation: Conversation) {
        let fileURL = conversationsDirectory.appendingPathComponent("\(conversation.id.uuidString).json")
        try? fileManager.removeItem(at: fileURL)
        conversations.removeAll { $0.id == conversation.id }

        if currentConversationId == conversation.id {
            currentConversationId = nil
        }
    }

    func createNew() -> Conversation {
        let conversation = Conversation()
        currentConversationId = conversation.id
        return conversation
    }

    func conversation(for id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }
}
