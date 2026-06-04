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
        "[SYSTEM_PROMPT]", "[/SYSTEM_PROMPT]",
        "<end_of_turn>", "<start_of_turn>model", "<start_of_turn>user",
        "<start_of_turn>system", "<start_of_turn>", "<bos>",
        "<turn|>", "<|turn>model", "<|turn>user", "<|turn>system", "<|turn>",
        "<eos>", "<|tool_response>"
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
    @Published var modelConfidence: Float = 1.0
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
    @Published var modelLoadError: String?

    // Active download tracking — persists across modal dismiss/re-present
    @Published var activeDownloads: [String: Double] = [:]  // filename -> progress
    var downloadTasks: [String: URLSessionDownloadTask] = [:]
    var downloadObservations: [String: NSKeyValueObservation] = [:]

    // Pending download metadata — maps filename to (modelName, modelUrl) for background session reconnection
    private var pendingDownloadMeta: [String: (name: String, url: String)] = [:]

    func startDownload(modelName: String, modelUrl: String, filename: String) {
        guard let url = URL(string: modelUrl) else { return }
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)

        // Remove any leftover partial file
        try? FileManager.default.removeItem(at: fileURL)

        activeDownloads[filename] = 0.0
        pendingDownloadMeta[filename] = (name: modelName, url: modelUrl)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, error in
            if let error = error as? NSError, error.code == NSURLErrorCancelled {
                Task { @MainActor [weak self] in
                    self?.cleanupDownload(filename: filename)
                }
                return
            }

            if let error = error {
                print("Download error: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.cleanupDownload(filename: filename)
                }
                return
            }

            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                print("Server error")
                Task { @MainActor [weak self] in
                    self?.cleanupDownload(filename: filename)
                }
                return
            }

            do {
                if let temporaryURL = temporaryURL {
                    try FileManager.default.copyItem(at: temporaryURL, to: fileURL)

                    // Validate file is at least 1MB (a real GGUF is always bigger)
                    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let size = attrs[.size] as? Int64 ?? 0
                    if size < 1_000_000 {
                        try FileManager.default.removeItem(at: fileURL)
                        print("Downloaded file too small, likely corrupt — removed")
                        Task { @MainActor [weak self] in
                            self?.cleanupDownload(filename: filename)
                        }
                        return
                    }

                    print("Writing to \(filename) completed (\(size) bytes)")

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.cleanupDownload(filename: filename)
                        self.cacheCleared = false
                        self.registerDownloadedModel(filename: filename, fallbackName: modelName, url: modelUrl)
                    }
                }
            } catch {
                print("File error: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: fileURL)
                Task { @MainActor [weak self] in
                    self?.cleanupDownload(filename: filename)
                }
            }
        }

        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.activeDownloads[filename] = progress.fractionCompleted
            }
        }

        downloadTasks[filename] = task
        downloadObservations[filename] = observation
        task.resume()
    }

    func cancelDownload(filename: String) {
        downloadTasks[filename]?.cancel()
        cleanupDownload(filename: filename)
    }

    private func cleanupDownload(filename: String) {
        downloadTasks.removeValue(forKey: filename)
        downloadObservations.removeValue(forKey: filename)
        activeDownloads.removeValue(forKey: filename)
        pendingDownloadMeta.removeValue(forKey: filename)
    }

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
        self.systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? ""
        let saved = UserDefaults.standard.integer(forKey: "contextSize")
        self.contextSize = saved > 0 ? UInt32(saved) : 4096
        loadModelsFromDisk()
        loadDownloadableModels()
        if downloadedModels.isEmpty {
            downloadDefaultModel()
        }
    }

    private func catalogModel(forFilename filename: String) -> Model? {
        downloadableModels.first { $0.filename == filename }
    }

    private func registerDownloadedModel(filename: String, fallbackName: String, url: String = "") {
        guard !downloadedModels.contains(where: { $0.filename == filename }) else { return }
        if let catalog = catalogModel(forFilename: filename) {
            var entry = catalog
            entry.status = "downloaded"
            downloadedModels.append(entry)
        } else {
            downloadedModels.append(Model(name: fallbackName, url: url, filename: filename, status: "downloaded"))
        }
        undownloadedModels.removeAll { $0.filename == filename }
    }

    private func loadModelsFromDisk() {
        do {
            let documentsURL = getDocumentsDirectory()
            let allURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            let modelURLs = allURLs.filter { $0.pathExtension.lowercased() == "gguf" }
            for modelURL in modelURLs {
                // Skip files under 1MB — likely corrupt or partial
                let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path)
                let size = attrs?[.size] as? Int64 ?? 0
                if size < 1_000_000 {
                    try? FileManager.default.removeItem(at: modelURL)
                    print("Removed corrupt/partial model: \(modelURL.lastPathComponent) (\(size) bytes)")
                    continue
                }
                let fallbackName = modelURL.deletingPathExtension().lastPathComponent
                registerDownloadedModel(filename: modelURL.lastPathComponent, fallbackName: fallbackName)
            }

            if let firstURL = modelURLs.first {
                Task {
                    try? await loadModel(modelUrl: firstURL)
                }
            }
        } catch {
            print("Error loading models from disk: \(error)")
        }
    }

    private func loadDownloadableModels() {
        for model in downloadableModels {
            let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                registerDownloadedModel(filename: model.filename, fallbackName: model.name, url: model.url)
            } else {
                var undownloadedModel = model
                undownloadedModel.status = "download"
                undownloadedModel.rec = canRunModel(model.name)
                if !undownloadedModels.contains(where: { $0.filename == model.filename }) {
                    undownloadedModels.append(undownloadedModel)
                }
            }
        }
    }

    @Published var isDownloadingDefault = false
    @Published var defaultDownloadProgress = 0.0
    private var defaultDownloadObservation: NSKeyValueObservation?

    private func downloadDefaultModel() {
        let model = LlamaState.defaultModel
        guard let url = URL(string: model.url) else { return }
        let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)

        isDownloadingDefault = true

        let task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, error in
            if let error = error {
                print("Default model download error: \(error.localizedDescription)")
                Task { @MainActor in self?.finishDefaultDownload() }
                return
            }

            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                print("Default model download server error")
                Task { @MainActor in self?.finishDefaultDownload() }
                return
            }

            do {
                if let temporaryURL = temporaryURL {
                    try FileManager.default.copyItem(at: temporaryURL, to: fileURL)

                    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let size = attrs[.size] as? Int64 ?? 0
                    if size < 1_000_000 {
                        try FileManager.default.removeItem(at: fileURL)
                        print("Default model download too small, likely corrupt — removed")
                        Task { @MainActor in self?.finishDefaultDownload() }
                        return
                    }

                    print("Default model downloaded: \(model.filename) (\(size) bytes)")

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.finishDefaultDownload()
                        self.registerDownloadedModel(filename: model.filename, fallbackName: model.name, url: model.url)
                        try? await self.loadModel(modelUrl: fileURL)
                    }
                }
            } catch {
                print("Default model save error: \(error.localizedDescription)")
                Task { @MainActor in self?.finishDefaultDownload() }
            }
        }

        defaultDownloadObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                self?.defaultDownloadProgress = progress.fractionCompleted
            }
        }

        task.resume()
    }

    private func finishDefaultDownload() {
        isDownloadingDefault = false
        defaultDownloadProgress = 0.0
        defaultDownloadObservation = nil
    }

    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }

    static let defaultModel = Model(
        name: "Gemma 4 E2B Instruct Q4 (2.9 GiB)",
        url: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf?download=true",
        filename: "gemma-4-E2B-it-Q4_K_M.gguf", status: "download")

    private let downloadableModels: [Model] = [
        LlamaState.defaultModel,

        // ~1–1.3 GiB — fast on 6GB+ phones
        Model(name: "LFM2.5-1.2B Instruct Q8 (1.2 GiB)",
              url: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q8_0.gguf?download=true",
              filename: "LFM2.5-1.2B-Instruct-Q8_0.gguf", status: "download"),

        Model(name: "Gemma 3 1B Q4 (0.8 GiB)",
              url: "https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf?download=true",
              filename: "gemma-3-1b-it-Q4_K_M.gguf", status: "download"),

        // ~2–2.4 GiB — balanced on 8GB+ phones
        Model(name: "Gemma 3 4B Q4 (2.3 GiB)",
              url: "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf?download=true",
              filename: "gemma-3-4b-it-Q4_K_M.gguf", status: "download"),

        Model(name: "Llama 3.2 3B Q4 (1.9 GiB)",
              url: "https://huggingface.co/unsloth/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true",
              filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf", status: "download"),

        Model(name: "Ministral-3B Instruct Q4 (2.0 GiB)",
              url: "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf?download=true",
              filename: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf", status: "download"),

        // ~3–5 GiB — best quality, 8GB+ recommended
        Model(name: "Gemma 4 E2B Instruct Q8 (4.6 GiB)",
              url: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q8_0.gguf?download=true",
              filename: "gemma-4-E2B-it-Q8_0.gguf", status: "download")
    ]

    private func reloadCurrentModel() {
        guard !currentModelName.isEmpty else { return }
        let documentsURL = getDocumentsDirectory()
        let allFiles = (try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)) ?? []
        if let modelURL = allFiles.first(where: { $0.deletingPathExtension().lastPathComponent == currentModelName }) {
            Task { try? await loadModel(modelUrl: modelURL) }
        }
    }

    func loadModel(modelUrl: URL) async throws {
        if isGenerating {
            await stop()
        }
        saveCurrentConversation()

        isLoadingModel = true
        modelLoadProgress = 0.0
        modelLoadError = nil

        await inferenceEngine?.deinitialize()
        inferenceEngine = nil

        let engine = LlamaCppEngine()
        inferenceEngine = engine
        do {
            try await engine.initialize(modelPath: modelUrl.path(), contextSize: contextSize) { [weak self] progress in
                Task { @MainActor in
                    self?.modelLoadProgress = Double(progress)
                }
            }
        } catch {
            isLoadingModel = false
            modelLoadError = error.localizedDescription
            inferenceEngine = nil
            throw error
        }

        isLoadingModel = false
        messages = []
        registerDownloadedModel(
            filename: modelUrl.lastPathComponent,
            fallbackName: modelUrl.deletingPathExtension().lastPathComponent
        )
        currentModelName = modelUrl.deletingPathExtension().lastPathComponent
        print("Loaded model")
    }

    private func chatMessagesForInference() -> [(role: String, content: String)] {
        var chatMessages: [(role: String, content: String)] = []
        if !systemPrompt.isEmpty {
            chatMessages.append((role: "system", content: systemPrompt))
        }
        for msg in messages {
            chatMessages.append((role: msg.isUser ? "user" : "assistant", content: msg.content))
        }
        return chatMessages
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
            let budget = Int(Double(contextSize) * 0.95)
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

            while await !inferenceEngine.isComplete && !isStopped {
                let token: String?
                do {
                    token = try await inferenceEngine.streamToken()
                } catch {
                    await MainActor.run {
                        self.currentResponse = "Error: Inference failed (\(error.localizedDescription))"
                        let errorMessage = ChatMessage(content: self.currentResponse, isUser: false, timestamp: Date())
                        self.messages.append(errorMessage)
                        self.currentResponse = ""
                        self.isThinking = false
                        self.isGenerating = false
                        self.saveCurrentConversation()
                    }
                    return
                }
                if let token {
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
                                // Read entropy for confidence indicator
                                var confidence: Float = 1.0
                                if let cppEngine = inferenceEngine as? LlamaCppEngine {
                                    let avg = await cppEngine.averageEntropy
                                    // Map entropy to 0-1 confidence (lower entropy = higher confidence)
                                    // Typical entropy range: 0-12 bits for 32K vocab
                                    confidence = max(0, min(1, 1.0 - (avg / 12.0)))
                                }
                                await MainActor.run {
                                    if self.isThinking {
                                        self.isThinking = false
                                    }
                                    self.currentResponse = snapshot
                                    self.modelConfidence = confidence
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

            // Keep KV cache for prefix reuse on next turn
            await inferenceEngine.clearGenerationState()

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

            await MainActor.run {
                self.isThinking = false
                self.isGenerating = false
            }

            // Generate title after first exchange (user + assistant = 2 messages)
            if messages.count == 2 {
                await generateTitle(
                    userMessage: text,
                    assistantMessage: savedRaw
                )
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
        "LFM2.5-1.2B Instruct Q8 (1.2 GiB)": 1.3,
        "Gemma 3 1B Q4 (0.8 GiB)": 1.2,
        "Llama 3.2 3B Q4 (1.9 GiB)": 2.2,
        "Gemma 3 4B Q4 (2.3 GiB)": 2.6,
        "Ministral-3B Instruct Q4 (2.0 GiB)": 2.2,
        "Gemma 4 E2B Instruct Q4 (2.9 GiB)": 3.0,
        "Gemma 4 E2B Instruct Q8 (4.6 GiB)": 5.0
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

        let conversationMessages = chatMessagesForInference()

        do {
            await inferenceEngine.clearGenerationState()
            await inferenceEngine.resume()
            try await inferenceEngine.generateNext(messages: titleMessages)

            let titleFilter = SpecialTokenFilter()
            let titleThinkStripper = ThinkTagStripper()
            var titleResult = ""

            while await !inferenceEngine.isComplete {
                if let token = try await inferenceEngine.streamToken() {
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

            // Restore KV cache for the user's conversation
            if !conversationMessages.isEmpty {
                try await inferenceEngine.encodePrompt(messages: conversationMessages)
            } else {
                await inferenceEngine.clearGenerationState()
            }

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
