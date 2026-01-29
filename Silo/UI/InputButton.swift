import SwiftUI

struct InputButton: View {
    @ObservedObject var llamaState: LlamaState
    @State private var inputLink: String = ""
    @State private var status: String = "download"
    @State private var filename: String = ""

    @State private var downloadTask: URLSessionDownloadTask?
    @State private var progress = 0.0
    @State private var observation: NSKeyValueObservation?

    private static func extractModelInfo(from link: String) -> (modelName: String, filename: String)? {
        guard let url = URL(string: link),
              let lastPathComponent = url.lastPathComponent.components(separatedBy: ".").first,
              let modelName = lastPathComponent.components(separatedBy: "-").dropLast().joined(separator: "-").removingPercentEncoding,
              let filename = lastPathComponent.removingPercentEncoding else {
            return nil
        }

        return (modelName, filename)
    }

    private static func getFileURL(filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
    }

    private func download() {
        guard let extractedInfo = InputButton.extractModelInfo(from: inputLink) else {
            // Handle invalid link or extraction failure
            return
        }

        let (modelName, filename) = extractedInfo
        self.filename = filename  // Set the state variable

        status = "downloading"
        print("Downloading model \(modelName) from \(inputLink)")
        guard let url = URL(string: inputLink) else { return }
        let fileURL = InputButton.getFileURL(filename: filename)

        let capturedModelName = modelName
        let capturedFilename = filename
        let capturedInputLink = inputLink

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
                        let model = Model(name: capturedModelName, url: capturedInputLink, filename: capturedFilename, status: "downloaded")
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

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("Hugging Face model URL", text: $inputLink)
                .textFieldStyle(.plain)

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
            } else if !inputLink.isEmpty {
                Button(action: {
                    if status == "downloaded" {
                        let fileURL = InputButton.getFileURL(filename: self.filename)
                        if !FileManager.default.fileExists(atPath: fileURL.path) {
                            download()
                            return
                        }
                        do {
                            try llamaState.loadModel(modelUrl: fileURL)
                        } catch let err {
                            print("Error: \(err.localizedDescription)")
                        }
                    } else {
                        download()
                    }
                }) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 28, height: 28)
                        .background(Color.white)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray5))
        .cornerRadius(12)
        .onDisappear() {
            downloadTask?.cancel()
        }
        .onChange(of: llamaState.cacheCleared) {
            if llamaState.cacheCleared {
                downloadTask?.cancel()
                let fileURL = InputButton.getFileURL(filename: self.filename)
                status = FileManager.default.fileExists(atPath: fileURL.path) ? "downloaded" : "download"
            }
        }
    }
}
