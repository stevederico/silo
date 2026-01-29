import SwiftUI

struct ManageModelsView: View {
    @ObservedObject var llamaState: LlamaState
    @Environment(\.dismiss) private var dismiss

    func deleteModel(at offsets: IndexSet) {
        for index in offsets {
            let model = llamaState.downloadedModels[index]
            let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)
            do {
                try FileManager.default.removeItem(at: fileURL)
                llamaState.downloadedModels.remove(at: index)
                llamaState.restoreToUndownloaded(filename: model.filename)
            } catch {
                print("Error deleting file: \(error)")
            }
        }
    }

    func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var body: some View {
        NavigationView {
            List {
                // MARK: - Download Section
                Section {
                    InputButton(llamaState: llamaState)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                // MARK: - Downloaded Models Section
                if !llamaState.downloadedModels.isEmpty {
                    Section {
                        ForEach(Array(llamaState.downloadedModels.enumerated()), id: \.element.id) { index, model in
                                    ModelListRow(
                                model: model,
                                isDownloaded: true,
                                isActive: model.filename.replacingOccurrences(of: ".gguf", with: "") == llamaState.currentModelName
                                    || model.name == llamaState.currentModelName
                            ) {
                                deleteModel(at: IndexSet(integer: index))
                            }
                        }
                    } header: {
                        Text("Downloaded Models")
                    }
                }

                // MARK: - Recommended Models Section
                Section {
                    let recommendedModels = llamaState.undownloadedModels.filter { $0.rec == true }
                    ForEach(recommendedModels, id: \.id) { model in
                        DownloadButton(
                            llamaState: llamaState,
                            modelName: model.name,
                            modelUrl: model.url,
                            filename: model.filename
                        )
                    }
                } header: {
                    Text("Recommended Models")
                }
            }
            .navigationTitle("Manage Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                }
            }
        }
    }
}

// MARK: - Helper Components

struct ModelListRow: View {
    let model: Model
    let isDownloaded: Bool
    var isActive: Bool = false
    var onDelete: (() -> Void)?

    private var displayName: String {
        // Extract name without size, e.g. "SmolLM2-360M Q8 (0.4 GiB)" -> "SmolLM2-360M Q8"
        var name = model.name
        if let range = name.range(of: " (") {
            name = String(name[..<range.lowerBound])
        }
        // Capitalize first letter
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private var modelSize: String {
        // Extract size from name, e.g. "SmolLM2-360M Q8 (0.4 GiB)" -> "0.4 GiB"
        if let start = model.name.range(of: "("),
           let end = model.name.range(of: ")") {
            return String(model.name[start.upperBound..<end.lowerBound])
        }
        // For downloaded models, get file size from disk
        if isDownloaded {
            return getFileSize()
        }
        return ""
    }

    private func getFileSize() -> String {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL.appendingPathComponent(model.filename)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int64 {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
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
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if !modelSize.isEmpty {
                        Text(modelSize)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if isActive {
                        Text("Active")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                }
            }

            Spacer()

            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.primary)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
    }
}
