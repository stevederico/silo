import Foundation

struct Model: Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var filename: String
    var status: String?
    var rec: Bool?
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let content: String
    let isUser: Bool
    let timestamp: Date

    init(id: UUID = UUID(), content: String, isUser: Bool, timestamp: Date) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
    }
}

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "New Chat", messages: [ChatMessage] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        if let firstUserMessage = messages.first(where: { $0.isUser }) {
            let content = firstUserMessage.content
            return content.count > 40 ? String(content.prefix(40)) + "..." : content
        }
        return title
    }

    var relativeDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(updatedAt) { return "Today" }
        if calendar.isDateInYesterday(updatedAt) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: updatedAt)
    }
}

@MainActor
class LlamaState: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var currentResponse = ""
    @Published var isGenerating = false
    @Published var systemPrompt = "You are a brutally concise assistant. Respond with only essential information. No pleasantries, no fluff, no rambling. Your response should be under 50 words. "
    @Published var cacheCleared = false
    @Published var currentModelName = ""
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []
    @Published var currentConversation: Conversation?

    private var inferenceEngine: InferenceEngine?
    var conversationManager: ConversationManager?

    init() {
        loadModelsFromDisk()
        loadDownloadableModels()
    }

    private func loadModelsFromDisk() {
        do {
            let documentsURL = getDocumentsDirectory()
            let allURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            let modelURLs = allURLs.filter { $0.pathExtension.lowercased() == "gguf" }
            for modelURL in modelURLs {
                let modelName = modelURL.deletingPathExtension().lastPathComponent
                downloadedModels.append(Model(name: modelName, url: "", filename: modelURL.lastPathComponent, status: "downloaded"))
            }

            if modelURLs.count > 0 {
                do {
                    try loadModel(modelUrl: modelURLs[0])
                } catch {
                    print("Error loading model")
                }
            } else {
                downloadDefaultModel()
            }
        } catch {
            print("Error loading models from disk: \(error)")
        }
    }

    private func loadDownloadableModels() {
        for model in downloadableModels {
            let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {

            } else {
                var undownloadedModel = model
                undownloadedModel.status = "download"
                undownloadedModel.rec = canRunModel(model.name)
                undownloadedModels.append(undownloadedModel)
            }
        }
    }

    @Published var isDownloadingDefault = false
    @Published var defaultDownloadProgress = 0.0

    private func downloadDefaultModel() {
        let model = LlamaState.defaultModel
        guard let url = URL(string: model.url) else { return }
        let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)

        isDownloadingDefault = true

        let task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, error in
            if let error = error {
                print("Default model download error: \(error.localizedDescription)")
                Task { @MainActor in self?.isDownloadingDefault = false }
                return
            }

            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                print("Default model download server error")
                Task { @MainActor in self?.isDownloadingDefault = false }
                return
            }

            do {
                if let temporaryURL = temporaryURL {
                    try FileManager.default.copyItem(at: temporaryURL, to: fileURL)
                    print("Default model downloaded: \(model.filename)")

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isDownloadingDefault = false
                        self.downloadedModels.append(Model(name: model.name, url: model.url, filename: model.filename, status: "downloaded"))
                        self.undownloadedModels.removeAll { $0.filename == model.filename }
                        try? self.loadModel(modelUrl: fileURL)
                    }
                }
            } catch {
                print("Default model save error: \(error.localizedDescription)")
                Task { @MainActor in self?.isDownloadingDefault = false }
            }
        }

        task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                self?.defaultDownloadProgress = progress.fractionCompleted
            }
        }

        task.resume()
    }

    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }

    static let defaultModel = Model(
        name: "SmolLM3-3B Q4 (1.9 GiB)",
        url: "https://huggingface.co/ggml-org/SmolLM3-3B-GGUF/resolve/main/SmolLM3-Q4_K_M.gguf?download=true",
        filename: "SmolLM3-Q4_K_M.gguf", status: "download")

    private let downloadableModels: [Model] = [
        LlamaState.defaultModel,

        Model(name: "LFM2.5-1.2B Instruct Q8 (1.3 GiB)",
              url: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q8_0.gguf?download=true",
              filename: "LFM2.5-1.2B-Instruct-Q8_0.gguf", status: "download"),

        Model(name: "LFM2.5-1.2B Thinking Q8 (1.3 GiB)",
              url: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q8_0.gguf?download=true",
              filename: "LFM2.5-1.2B-Thinking-Q8_0.gguf", status: "download"),

        Model(name: "Ministral-3B Instruct Q4 (2.2 GiB)",
              url: "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf?download=true",
              filename: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf", status: "download"),

        Model(name: "Ministral-3B Reasoning Q4 (2.2 GiB)",
              url: "https://huggingface.co/mistralai/Ministral-3-3B-Reasoning-2512-GGUF/resolve/main/Ministral-3-3B-Reasoning-2512-Q4_K_M.gguf?download=true",
              filename: "Ministral-3-3B-Reasoning-2512-Q4_K_M.gguf", status: "download")
    ]

    func loadModel(modelUrl: URL?) throws {
        if let modelUrl {
            let engine = LlamaCppEngine()

            Task {
                do {
                    await inferenceEngine?.deinitialize()
                    inferenceEngine = engine
                    try await engine.initialize(modelPath: modelUrl.path())

                    await MainActor.run {
                        self.messages = []
                        self.updateDownloadedModels(modelName: modelUrl.lastPathComponent, status: "downloaded")
                        let modelName = modelUrl.deletingPathExtension().lastPathComponent
                        self.currentModelName = modelName
                        print("Loaded model")
                    }
                } catch {
                    await MainActor.run {
                        print("Error loading model: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func updateDownloadedModels(modelName: String, status: String) {
        undownloadedModels.removeAll { $0.name == modelName }
    }

    func restoreToUndownloaded(filename: String) {
        // Check if this model is from the predefined downloadable models
        if let model = downloadableModels.first(where: { $0.filename == filename }) {
            // Only add back if not already in undownloadedModels
            if !undownloadedModels.contains(where: { $0.filename == filename }) {
                var restoredModel = model
                restoredModel.status = "download"
                restoredModel.rec = canRunModel(model.name)
                undownloadedModels.append(restoredModel)
            }
        }
    }

    func complete(text: String) async {
        guard let inferenceEngine else {
            return
        }

        await inferenceEngine.resume()

        let userMessage = ChatMessage(content: text, isUser: true, timestamp: Date())
        messages.append(userMessage)

        currentResponse = ""
        isGenerating = true

        do {
            try await inferenceEngine.generateNext(prompt: text, systemPrompt: systemPrompt)

            while await !inferenceEngine.isComplete {
                if let token = try? await inferenceEngine.streamToken() {
                    await MainActor.run {
                        self.currentResponse += token
                    }
                }
            }

            await inferenceEngine.clear()

            await MainActor.run {
                let aiMessage = ChatMessage(content: self.currentResponse, isUser: false, timestamp: Date())
                self.messages.append(aiMessage)
                self.currentResponse = ""
                self.isGenerating = false
                self.saveCurrentConversation()
            }
        } catch {
            await MainActor.run {
                self.currentResponse = "Error: \(error.localizedDescription)"
                let errorMessage = ChatMessage(content: self.currentResponse, isUser: false, timestamp: Date())
                self.messages.append(errorMessage)
                self.currentResponse = ""
                self.isGenerating = false
                self.saveCurrentConversation()
            }
        }
    }

    func clear() async {
        guard let inferenceEngine else {
            return
        }

        saveCurrentConversation()
        await inferenceEngine.clear()
        messages = []
        currentResponse = ""
        currentConversation = conversationManager?.createNew()
    }

    func stop() async {
        guard let inferenceEngine else {
            return
        }

        await inferenceEngine.stop()

        if !currentResponse.isEmpty {
            let aiMessage = ChatMessage(content: currentResponse, isUser: false, timestamp: Date())
            messages.append(aiMessage)
            currentResponse = ""
        }
        isGenerating = false
    }

    func getTotalRAMInGiB() -> Double {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        return Double(totalMemory) / (1024 * 1024 * 1024)
    }

    let modelRequirements: [String: Double] = [
        "LFM2.5-1.2B Instruct Q8 (1.3 GiB)": 1.3,
        "LFM2.5-1.2B Thinking Q8 (1.3 GiB)": 1.3,
        "SmolLM3-3B Q4 (1.9 GiB)": 1.9,
        "Ministral-3B Instruct Q4 (2.2 GiB)": 2.2,
        "Ministral-3B Reasoning Q4 (2.2 GiB)": 2.2
    ]

    func canRunModel(_ modelName: String) -> Bool {
        guard let requiredRAM = modelRequirements[modelName] else {
            return true
        }
        let totalRAM = getTotalRAMInGiB()
        return totalRAM >= requiredRAM
    }

    // MARK: - Conversation Management

    func saveCurrentConversation() {
        guard !messages.isEmpty else { return }

        if var conversation = currentConversation {
            conversation.messages = messages
            conversation.updatedAt = Date()
            conversationManager?.save(conversation)
            currentConversation = conversation
        } else {
            var newConversation = Conversation(messages: messages)
            newConversation.updatedAt = Date()
            conversationManager?.save(newConversation)
            currentConversation = newConversation
            conversationManager?.currentConversationId = newConversation.id
        }
    }

    func loadConversation(_ conversation: Conversation) {
        saveCurrentConversation()
        messages = conversation.messages
        currentConversation = conversation
        conversationManager?.currentConversationId = conversation.id
    }

    func startNewConversation() async {
        await clear()
    }
}
