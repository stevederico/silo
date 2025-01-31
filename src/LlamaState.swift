import Foundation

struct Model: Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var filename: String
    var status: String?
    var rec: Bool?
}

@MainActor
class LlamaState: ObservableObject {

    @Published var messageLog = ""
    @Published var systemPrompt = "You are a brutally concise assistant. Respond with only essential information. No pleasantries, no fluff, no rambling. Your response should be under 50 words. "
    @Published var cacheCleared = false
    @Published var currentModelName = ""
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []

    private var llamaContext: LlamaContext?

    init() {
        loadModelsFromDisk()
        loadDownloadableModels()
    }

    private func loadModelsFromDisk() {
        do {
            let documentsURL = getDocumentsDirectory()
            let modelURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            for modelURL in modelURLs {
                let modelName = modelURL.deletingPathExtension().lastPathComponent
                downloadedModels.append(Model(name: modelName, url: "", filename: modelURL.lastPathComponent, status: "downloaded"))
            }
            
            if modelURLs.count > 0 {
                do {
                    try loadModel(modelUrl: modelURLs[0])
                } catch {
                    messageLog += "Error!\n"
                }
            } else {
                messageLog += "Go to settings and download a model.\n"
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

    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    
    private let downloadableModels: [Model] = [
        
        Model(name: "SmolLM2-360M-Instruct Q8_0 (0.386 GiB)",url: "https://huggingface.co/HuggingFaceTB/SmolLM2-360M-Instruct-GGUF/resolve/main/smollm2-360m-instruct-q8_0.gguf?download=true",filename: "smollm2-360m-instruct-q8_0.gguf", status: "download"),
        
        Model(name: "llama-3.2-1b-instruct Q8_0 (1.3 GiB)",url: "https://huggingface.co/hugging-quants/Llama-3.2-1B-Instruct-Q8_0-GGUF/resolve/main/llama-3.2-1b-instruct-q8_0.gguf?download=true",filename: "llama-3.2-1b-instruct-q8_0.gguf", status: "download"),
        
        Model(name: "Llama-3.2-3B-Instruct Q4_K_L (2.11 GiB)",url: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_L.gguf?download=true",filename: "Llama-3.2-3B-Instruct-Q4_K_L.gguf", status: "download"),
        
        Model(name: "Phi-3.5-mini-4k-instruct Q4_K_M (2.4 GiB)",url: "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf?download=true",filename: "Phi-3-mini-4k-instruct-q4.gguf", status: "download")
    ]
    
    func loadModel(modelUrl: URL?) throws {
        if let modelUrl {
            llamaContext = try LlamaContext.create_context(path: modelUrl.path())
            messageLog = ""
            updateDownloadedModels(modelName: modelUrl.lastPathComponent, status: "downloaded")
            let modelName = modelUrl.deletingPathExtension().lastPathComponent
            currentModelName  = modelName
        }
    }

    private func updateDownloadedModels(modelName: String, status: String) {
        undownloadedModels.removeAll { $0.name == modelName }
    }

    func complete(text: String) async {
        guard let llamaContext else {
            return
        }
        await llamaContext.resume()
        let final_prompt = systemPrompt + text
        messageLog += "\(text)\n\n"
        
        await llamaContext.completion_init(text: final_prompt)
    
        while await !llamaContext.is_done {
            let result = await llamaContext.completion_loop()
            await MainActor.run {
                self.messageLog += "\(result)"
            }
        }
        await llamaContext.clear()

        await MainActor.run {
            self.messageLog += """
                \n\n
                """
        }
    }

    func clear() async {
        guard let llamaContext else {
            return
        }

        await llamaContext.clear()
        messageLog = ""
    }
    
    func stop() async {
        guard let llamaContext else {
            return
        }

        await llamaContext.stop()
    }
    
//    func cloop() async {
//        guard let llamaContext else {
//            return
//        }
//        await llamaContext.completion_loop()
//    }
    

    // Function to get total RAM in GiB (Allowed API)
    func getTotalRAMInGiB() -> Double {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        return Double(totalMemory) / (1024 * 1024 * 1024) // Convert to GiB
    }

    // Model RAM requirements (GiB)
    let modelRequirements: [String: Double] = [
        "SmolLM2-360M-Instruct Q8_0 (0.386 GiB)": 0.386,
        "llama-3.2-1b-instruct Q8_0 (1.3 GiB)": 1.3,
        "Llama-3.2-3B-Instruct Q4_K_L (2.11 GiB)": 2.11,
        "Phi-3.5-mini-4k-instruct Q4_K_M (2.4 GiB)": 2.4
    ]

    // Function to check if a specific model can run
    func canRunModel(_ modelName: String) -> Bool {
        guard let requiredRAM = modelRequirements[modelName] else {
            return false
        }
        
        let totalRAM = getTotalRAMInGiB()
        return totalRAM >= requiredRAM
    }

  

}
