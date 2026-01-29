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

    var displayContent: String {
        guard !isUser else { return content }
        // Strip <think>...</think> blocks for display
        var result = content
        while let startRange = result.range(of: "<think>") {
            if let endRange = result.range(of: "</think>", range: startRange.upperBound..<result.endIndex) {
                result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            } else {
                // Unclosed think block — remove from <think> to end
                result.removeSubrange(startRange.lowerBound..<result.endIndex)
            }
        }
        // Trim leading whitespace/newlines left after stripping
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Special Token Filter

class SpecialTokenFilter {
    private static let specialTokens: [String] = [
        "<|im_end|>", "<|im_start|>assistant", "<|im_start|>user",
        "<|im_start|>system", "<|im_start|>", "<|endoftext|>",
        "<|end_of_text|>", "</s>", "<s>", "[INST]", "[/INST]",
        "[SYSTEM_PROMPT]", "[/SYSTEM_PROMPT]"
    ]

    private static let maxTokenLength: Int = {
        specialTokens.map(\.count).max() ?? 15
    }()

    private var buffer = ""

    func process(_ input: String) -> String {
        buffer += input
        var output = ""

        while !buffer.isEmpty {
            // Check if buffer matches any special token exactly
            var matched = false
            for token in Self.specialTokens {
                if buffer.hasPrefix(token) {
                    // Remove matched special token
                    buffer.removeFirst(token.count)
                    matched = true
                    break
                }
            }
            if matched { continue }

            // Check if buffer could be the start of a special token
            let couldBePrefix = Self.specialTokens.contains { token in
                token.hasPrefix(buffer) && buffer.count < token.count
            }

            if couldBePrefix {
                // Hold back — might be partial special token
                break
            }

            // Safe to emit the first character
            output.append(buffer.removeFirst())
        }

        return output
    }

    func flush() -> String {
        // On completion, emit whatever is left — it wasn't a special token
        let remaining = buffer
        buffer = ""
        // But still strip any complete special tokens in the remaining
        var result = remaining
        for token in Self.specialTokens {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result
    }

    func reset() {
        buffer = ""
    }
}

// MARK: - Think Tag Stripper

class ThinkTagStripper {
    private enum State {
        case lookingForOpen   // Haven't seen <think> yet
        case insideThink      // Between <think> and </think>
        case passThrough      // After </think>, emit everything
    }

    private var state: State = .lookingForOpen
    private var buffer = ""

    var isInsideThink: Bool {
        state == .insideThink || state == .lookingForOpen
    }

    func process(_ input: String) -> String {
        buffer += input

        guard !buffer.isEmpty else { return "" }

        switch state {
        case .lookingForOpen:
            // Check if buffer contains <think>
            if let range = buffer.range(of: "<think>") {
                let before = String(buffer[buffer.startIndex..<range.lowerBound])
                buffer = String(buffer[range.upperBound...])
                state = .insideThink
                return before
            }
            // Check if any suffix of buffer is a prefix of "<think>"
            let holdBack = suffixPrefixOverlap(buffer, "<think>")
            if holdBack > 0 {
                let safe = String(buffer.dropLast(holdBack))
                buffer = String(buffer.suffix(holdBack))
                return safe
            }
            // No chance of <think>, pass through
            let out = buffer
            buffer = ""
            state = .passThrough
            return out

        case .insideThink:
            // Look for </think>
            if let range = buffer.range(of: "</think>") {
                buffer = String(buffer[range.upperBound...])
                state = .passThrough
                let out = buffer
                buffer = ""
                return out
            }
            // Check if any suffix could be start of "</think>"
            let hold = suffixPrefixOverlap(buffer, "</think>")
            if hold > 0 {
                buffer = String(buffer.suffix(hold))
            } else {
                buffer = ""
            }
            return ""

        case .passThrough:
            let out = buffer
            buffer = ""
            return out
        }
    }

    func flush() -> String {
        switch state {
        case .lookingForOpen:
            // Never found <think>, emit everything
            let out = buffer
            buffer = ""
            return out
        case .insideThink:
            // Unclosed think block — discard
            buffer = ""
            return ""
        case .passThrough:
            let out = buffer
            buffer = ""
            return out
        }
    }

    func reset() {
        state = .lookingForOpen
        buffer = ""
    }

    /// Returns the length of the longest suffix of `text` that is a prefix of `tag`.
    private func suffixPrefixOverlap(_ text: String, _ tag: String) -> Int {
        let maxCheck = min(text.count, tag.count - 1)
        guard maxCheck > 0 else { return 0 }
        for len in stride(from: maxCheck, through: 1, by: -1) {
            if tag.hasPrefix(String(text.suffix(len))) {
                return len
            }
        }
        return 0
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
        if title != "New Chat" && !title.isEmpty {
            return title
        }
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
    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }
    }
    @Published var cacheCleared = false
    @Published var contextTruncated = false
    @Published var isThinking = false
    @Published var contextSize: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(contextSize), forKey: "contextSize")
            reloadCurrentModel()
        }
    }
    @Published var isLoadingModel = false
    @Published var modelLoadProgress = 0.0
    @Published var currentModelName = ""
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []
    @Published var currentConversation: Conversation?

    private var inferenceEngine: InferenceEngine?
    var conversationManager: ConversationManager?

    // Streaming state promoted to instance vars for stop() access
    private var isStopped = false
    private var rawResponse = ""
    private var rawResponseParts: [String] = []
    private var displayParts: [String] = []
    private var displayPartsSinceLastFlush = 0
    private var tokenFilter = SpecialTokenFilter()
    private var thinkStripper = ThinkTagStripper()

    init() {
        self.systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt")
            ?? "You are a brutally concise assistant. Respond with only essential information. No pleasantries, no fluff, no rambling. Your response should be under 50 words. "
        let saved = UserDefaults.standard.integer(forKey: "contextSize")
        self.contextSize = saved > 0 ? UInt32(saved) : 4096
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

    private func reloadCurrentModel() {
        guard !currentModelName.isEmpty else { return }
        let documentsURL = getDocumentsDirectory()
        let allFiles = (try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)) ?? []
        if let modelURL = allFiles.first(where: { $0.deletingPathExtension().lastPathComponent == currentModelName }) {
            try? loadModel(modelUrl: modelURL)
        }
    }

    func loadModel(modelUrl: URL?) throws {
        if let modelUrl {
            Task {
                do {
                    // Stop any active generation before switching models
                    if isGenerating {
                        await stop()
                    }
                    // Save current conversation before clearing
                    saveCurrentConversation()

                    self.isLoadingModel = true
                    self.modelLoadProgress = 0.0

                    // Fully release the old engine before allocating a new one
                    // to avoid two models coexisting in RAM → OOM
                    await inferenceEngine?.deinitialize()
                    inferenceEngine = nil

                    let engine = LlamaCppEngine()
                    inferenceEngine = engine
                    try await engine.initialize(modelPath: modelUrl.path(), contextSize: self.contextSize) { [weak self] progress in
                        DispatchQueue.main.async {
                            self?.modelLoadProgress = Double(progress)
                        }
                    }

                    await MainActor.run {
                        self.isLoadingModel = false
                        self.messages = []
                        self.updateDownloadedModels(modelName: modelUrl.lastPathComponent, status: "downloaded")
                        let modelName = modelUrl.deletingPathExtension().lastPathComponent
                        self.currentModelName = modelName
                        print("Loaded model")
                    }
                } catch {
                    await MainActor.run {
                        self.isLoadingModel = false
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
        guard !isGenerating else { return }
        guard let inferenceEngine else {
            return
        }

        isGenerating = true
        isStopped = false
        rawResponse = ""
        rawResponseParts = []
        displayParts = []
        displayPartsSinceLastFlush = 0
        tokenFilter.reset()
        thinkStripper.reset()
        await inferenceEngine.resume()

        let userMessage = ChatMessage(content: text, isUser: true, timestamp: Date())
        messages.append(userMessage)

        currentResponse = ""
        contextTruncated = false
        isThinking = true

        do {
            // Build full conversation history for multi-turn
            var chatMessages: [(role: String, content: String)] = []
            if !systemPrompt.isEmpty {
                chatMessages.append((role: "system", content: systemPrompt))
            }
            for msg in messages {
                chatMessages.append((role: msg.isUser ? "user" : "assistant", content: msg.content))
            }

            // Context overflow handling
            let budget = Int(Double(contextSize) * 0.75)
            var currentTokenCount = (try? await inferenceEngine.countTokens(for: chatMessages)) ?? 0
            var trimmed = false
            while currentTokenCount > budget && chatMessages.count > 1 {
                // Remove oldest non-system message
                let removeIndex = (chatMessages.first?.role == "system") ? 1 : 0
                if removeIndex >= chatMessages.count { break }
                chatMessages.remove(at: removeIndex)
                trimmed = true
                currentTokenCount = (try? await inferenceEngine.countTokens(for: chatMessages)) ?? 0
            }
            // If still over budget with system + last user, drop system
            if currentTokenCount > budget, chatMessages.count > 1, chatMessages.first?.role == "system" {
                chatMessages.removeFirst()
            }
            if trimmed {
                contextTruncated = true
                print("Context truncated: \(chatMessages.count) messages remaining")
            }

            // Fix 4: Guard empty chatMessages after trimming
            guard !chatMessages.isEmpty else {
                await MainActor.run {
                    self.currentResponse = "Error: Context too large, no messages fit within budget."
                    let errorMessage = ChatMessage(content: self.currentResponse, isUser: false, timestamp: Date())
                    self.messages.append(errorMessage)
                    self.currentResponse = ""
                    self.isThinking = false
                    self.isGenerating = false
                    self.saveCurrentConversation()
                }
                return
            }

            try await inferenceEngine.generateNext(messages: chatMessages)

            while await !inferenceEngine.isComplete {
                if let token = try? await inferenceEngine.streamToken() {
                    rawResponseParts.append(token)
                    let filtered = tokenFilter.process(token)
                    if !filtered.isEmpty {
                        let display = thinkStripper.process(filtered)
                        if !display.isEmpty {
                            displayParts.append(display)
                            displayPartsSinceLastFlush += 1
                            // First token: update immediately to clear isThinking
                            // After that: batch every 10 tokens to avoid per-token String copies
                            let needsImmediateUpdate = self.isThinking
                            if needsImmediateUpdate || displayPartsSinceLastFlush >= 10 {
                                let snapshot = displayParts.joined()
                                displayPartsSinceLastFlush = 0
                                await MainActor.run {
                                    if self.isThinking {
                                        self.isThinking = false
                                    }
                                    self.currentResponse = snapshot
                                }
                            }
                        }
                    }
                }
            }

            // If stopped, stop() already saved the message — skip flush/append
            if isStopped { return }

            // Flush remaining buffered content
            let filterFlush = tokenFilter.flush()
            rawResponseParts.append(filterFlush)
            let displayFlush = thinkStripper.process(filterFlush) + thinkStripper.flush()
            if !displayFlush.isEmpty {
                displayParts.append(displayFlush)
            }

            await inferenceEngine.clear()

            rawResponse = rawResponseParts.joined()
            let savedRaw = rawResponse
            let finalDisplay = displayParts.joined()

            await MainActor.run {
                self.currentResponse = finalDisplay
                // Store raw content (with think tags) for accurate multi-turn history
                let aiMessage = ChatMessage(content: savedRaw, isUser: false, timestamp: Date())
                self.messages.append(aiMessage)
                self.currentResponse = ""
                self.saveCurrentConversation()
            }

            // Fix 11: Reset isThinking before generateTitle so it doesn't persist
            await MainActor.run {
                self.isThinking = false
            }

            // Generate title after first exchange (user + assistant = 2 messages)
            if messages.count == 2 {
                await generateTitle(
                    userMessage: text,
                    assistantMessage: savedRaw
                )
            }

            await MainActor.run {
                self.isGenerating = false
            }
        } catch {
            await MainActor.run {
                self.currentResponse = "Error: \(error.localizedDescription)"
                let errorMessage = ChatMessage(content: self.currentResponse, isUser: false, timestamp: Date())
                self.messages.append(errorMessage)
                self.currentResponse = ""
                self.isThinking = false
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

        isStopped = true
        await inferenceEngine.stop()

        // Flush filter/stripper buffers before saving
        let filterFlush = tokenFilter.flush()
        rawResponseParts.append(filterFlush)
        let displayFlush = thinkStripper.process(filterFlush) + thinkStripper.flush()
        if !displayFlush.isEmpty {
            displayParts.append(displayFlush)
        }

        rawResponse = rawResponseParts.joined()
        currentResponse = displayParts.joined()

        // Save raw content for accurate multi-turn history (fall back to display if empty)
        let contentToSave = rawResponse.isEmpty ? currentResponse : rawResponse
        if !contentToSave.isEmpty {
            let aiMessage = ChatMessage(content: contentToSave, isUser: false, timestamp: Date())
            messages.append(aiMessage)
            currentResponse = ""
        }
        isThinking = false
        isGenerating = false
        saveCurrentConversation()
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

    // MARK: - Title Generation

    private func generateTitle(userMessage: String, assistantMessage: String) async {
        guard let inferenceEngine else { return }

        let titleMessages: [(role: String, content: String)] = [
            (role: "system", content: "Generate a 3-5 word title for this conversation. Reply with ONLY the title, nothing else."),
            (role: "user", content: userMessage),
            (role: "assistant", content: String(assistantMessage.prefix(200))),
            (role: "user", content: "Generate a short title for this conversation.")
        ]

        do {
            await inferenceEngine.clear()
            await inferenceEngine.resume()
            try await inferenceEngine.generateNext(messages: titleMessages)

            let titleFilter = SpecialTokenFilter()
            let titleThinkStripper = ThinkTagStripper()
            var titleResult = ""

            while await !inferenceEngine.isComplete {
                if let token = try? await inferenceEngine.streamToken() {
                    let filtered = titleFilter.process(token)
                    if !filtered.isEmpty {
                        let display = titleThinkStripper.process(filtered)
                        titleResult += display
                    }
                    // Cap at 60 chars
                    if titleResult.count >= 60 { break }
                }
            }

            // Fix 3: Stop engine if we broke out early, before clearing
            await inferenceEngine.stop()

            // Flush
            let flush = titleFilter.flush()
            titleResult += titleThinkStripper.process(flush) + titleThinkStripper.flush()
            await inferenceEngine.clear()

            // Clean up the title
            var title = titleResult
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\n", with: " ")

            if title.count > 60 {
                title = String(title.prefix(60))
            }

            // Fallback if empty or garbage
            if title.isEmpty || title.count < 2 {
                title = String(userMessage.prefix(40))
            }

            await MainActor.run {
                if var conversation = self.currentConversation {
                    conversation.title = title
                    self.currentConversation = conversation
                    self.conversationManager?.save(conversation)
                }
            }
        } catch {
            // Fallback: use truncated user message
            let fallback = String(userMessage.prefix(40))
            await MainActor.run {
                if var conversation = self.currentConversation {
                    conversation.title = fallback
                    self.currentConversation = conversation
                    self.conversationManager?.save(conversation)
                }
            }
        }
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

    func loadConversation(id: UUID) {
        saveCurrentConversation()
        guard let conversation = conversationManager?.loadFullConversation(id: id) else { return }
        messages = conversation.messages
        currentConversation = conversation
        conversationManager?.currentConversationId = conversation.id
    }

    func startNewConversation() async {
        await clear()
    }
}
