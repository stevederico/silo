import SwiftUI

struct DownloadButton: View {
    @ObservedObject private var llamaState: LlamaState
    private var modelName: String
    private var modelUrl: String
    private var filename: String

    @State private var status: String

    @State private var downloadTask: URLSessionDownloadTask?
    @State private var progress = 0.0
    @State private var observation: NSKeyValueObservation?

    private static func getFileURL(filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
    }

    private func checkFileExistenceAndUpdateStatus() {
    }

    init(llamaState: LlamaState, modelName: String, modelUrl: String, filename: String) {
        self.llamaState = llamaState
        self.modelName = modelName
        self.modelUrl = modelUrl
        self.filename = filename

        let fileURL = DownloadButton.getFileURL(filename: filename)
        status = FileManager.default.fileExists(atPath: fileURL.path) ? "downloaded" : "download"
    }

    private func download() {
        status = "downloading"
        print("Downloading model \(modelName) from \(modelUrl)")
        guard let url = URL(string: modelUrl) else { return }
        let fileURL = DownloadButton.getFileURL(filename: filename)

        let capturedModelName = modelName
        let capturedModelUrl = modelUrl
        let capturedFilename = filename

        downloadTask = URLSession.shared.downloadTask(with: url) { [weak llamaState] temporaryURL, response, error in
            if let error = error {
                print("Error: \(error.localizedDescription)")
                return
            }

            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                print("Server error!")
                return
            }

            do {
                if let temporaryURL = temporaryURL {
                    try FileManager.default.copyItem(at: temporaryURL, to: fileURL)
                    print("Writing to \(capturedFilename) completed")

                    Task { @MainActor in
                        llamaState?.cacheCleared = false
                        let model = Model(name: capturedModelName, url: capturedModelUrl, filename: capturedFilename, status: "downloaded")
                        llamaState?.downloadedModels.append(model)
                    }
                }
            } catch let err {
                print("Error: \(err.localizedDescription)")
            }
        }

        observation = downloadTask?.progress.observe(\.fractionCompleted) { progress, _ in
            self.progress = progress.fractionCompleted
        }

        downloadTask?.resume()
    }

    private var displayName: String {
        // Extract name without size, e.g. "SmolLM2-360M Q8 (0.4 GiB)" -> "SmolLM2-360M Q8"
        var name = modelName
        if let range = modelName.range(of: " (") {
            name = String(modelName[..<range.lowerBound])
        }
        // Capitalize first letter
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private var modelSize: String {
        // Extract size from name, e.g. "SmolLM2-360M Q8 (0.4 GiB)" -> "0.4 GiB"
        if let start = modelName.range(of: "("),
           let end = modelName.range(of: ")") {
            return String(modelName[start.upperBound..<end.lowerBound])
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                if !modelSize.isEmpty {
                    Text(modelSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if status == "downloading" {
                Button(action: {
                    downloadTask?.cancel()
                    status = "download"
                }) {
                    ZStack {
                        Circle()
                            .stroke(Color(.systemGray4), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.primary, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(progress * 100))")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 28, height: 28)
                }
            } else if status == "downloaded" {
                Button(action: {
                    let fileURL = DownloadButton.getFileURL(filename: filename)
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        download()
                        return
                    }
                    do {
                        try llamaState.loadModel(modelUrl: fileURL)
                    } catch let err {
                        print("Error: \(err.localizedDescription)")
                    }
                }) {
                    Text("Load")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .cornerRadius(14)
                }
            } else {
                Button(action: download) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 28, height: 28)
                        .background(Color.white)
                        .clipShape(Circle())
                }
            }
        }
        .onDisappear() {
            downloadTask?.cancel()
        }
        .onChange(of: llamaState.cacheCleared) {
            if llamaState.cacheCleared {
                downloadTask?.cancel()
                let fileURL = DownloadButton.getFileURL(filename: filename)
                status = FileManager.default.fileExists(atPath: fileURL.path) ? "downloaded" : "download"
            }
        }
    }
}

// #Preview {
//    DownloadButton(
//        llamaState: LlamaState(),
//        modelName: "TheBloke / TinyLlama-1.1B-1T-OpenOrca-GGUF (Q4_0)",
//        modelUrl: "https://huggingface.co/TheBloke/TinyLlama-1.1B-1T-OpenOrca-GGUF/resolve/main/tinyllama-1.1b-1t-openorca.Q4_0.gguf?download=true",
//        filename: "tinyllama-1.1b-1t-openorca.Q4_0.gguf"
//    )
// }
