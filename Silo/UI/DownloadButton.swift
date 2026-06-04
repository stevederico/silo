import SwiftUI

struct DownloadButton: View {
    @ObservedObject private var llamaState: LlamaState
    private var modelName: String
    private var modelUrl: String
    private var filename: String

    private static func getFileURL(filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
    }

    init(llamaState: LlamaState, modelName: String, modelUrl: String, filename: String) {
        self.llamaState = llamaState
        self.modelName = modelName
        self.modelUrl = modelUrl
        self.filename = filename
    }

    private var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: DownloadButton.getFileURL(filename: filename).path)
    }

    private var isDownloading: Bool {
        llamaState.activeDownloads[filename] != nil
    }

    private var progress: Double {
        llamaState.activeDownloads[filename] ?? 0.0
    }

    private var displayName: String {
        var name = modelName
        if let range = modelName.range(of: " (") {
            name = String(modelName[..<range.lowerBound])
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private var modelSize: String {
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

            if isDownloading {
                Button(action: {
                    llamaState.cancelDownload(filename: filename)
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
            } else if isDownloaded {
                Button(action: {
                    let fileURL = DownloadButton.getFileURL(filename: filename)
                    if !FileManager.default.fileExists(atPath: fileURL.path) {
                        llamaState.startDownload(modelName: modelName, modelUrl: modelUrl, filename: filename)
                        return
                    }
                    Task {
                        do {
                            try await llamaState.loadModel(modelUrl: fileURL)
                        } catch {
                            print("Error: \(error.localizedDescription)")
                        }
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
                Button(action: {
                    llamaState.startDownload(modelName: modelName, modelUrl: modelUrl, filename: filename)
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
        .onChange(of: llamaState.cacheCleared) {
            if llamaState.cacheCleared {
                llamaState.cancelDownload(filename: filename)
            }
        }
    }
}
