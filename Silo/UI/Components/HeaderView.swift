import SwiftUI

struct HeaderView: View {
    let currentModel: String
    let models: [Model]
    var isLoadingModel: Bool = false
    var isDownloading: Bool = false
    var isGenerating: Bool = false
    var downloadProgress: Double = 0.0
    var modelLoadProgress: Double = 0.0
    let onMenuTap: () -> Void
    let onModelSelect: (Model) -> Void
    let onNewChat: () -> Void
    let onManageModels: () -> Void

    @State private var showModelPicker = false

    private var headerTitle: String {
        if isDownloading {
            let pct = Int(downloadProgress * 100)
            return pct > 0 ? "Downloading \(pct)%" : "Connecting..."
        }
        if isLoadingModel { return "Loading..." }
        return truncatedModelName
    }

    private var truncatedModelName: String {
        if currentModel.isEmpty {
            return models.isEmpty ? "No Model" : ""
        }
        return Self.parseModelDisplayName(currentModel)
    }

    /// Parse a GGUF filename into a clean display name.
    /// "gemma-4-E2B-it-Q4_K_M" -> "Gemma 4"
    /// "gemma-4-E2B-it-qat-UD-Q4_K_XL" -> "Gemma 4"
    /// "SmolLM3-3B-Q4_K_M" -> "SmolLM3"
    /// "LFM2.5-1.2B-Instruct-Q8_0" -> "LFM2.5"
    /// "Ministral-3B-Instruct-Q4_K_M" -> "Ministral"
    static func parseModelDisplayName(_ filename: String) -> String {
        // Quantization suffixes to strip
        let quantPatterns = [
            "-Q[0-9]+_K_[A-Z]+", "-Q[0-9]+_[0-9]+", "-Q[0-9]+",
            "-F[0-9]+", "-IQ[0-9]+_[A-Z]+"
        ]
        var name = filename
        for pattern in quantPatterns {
            if let range = name.range(of: pattern, options: .regularExpression) {
                name = String(name[..<range.lowerBound])
            }
        }

        // Strip common suffixes that aren't part of the model identity
        let stripSuffixes = ["-it", "-Instruct", "-instruct", "-Reasoning", "-reasoning", "-Thinking", "-thinking", "-Chat", "-chat"]
        for suffix in stripSuffixes {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
        }

        // Strip size labels (e.g. -3B, -1.2B, -E2B, -7B, -4.6B)
        if let range = name.range(of: "-[0-9A-E.]*B$", options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }

        // Strip QAT / Unsloth Dynamic markers (QAT models, UD quants) for clean display
        let extraClean = ["-qat", "-QAT", "-UD", "-XL", "qat", "QAT", "UD", "XL"]
        for token in extraClean {
            name = name.replacingOccurrences(of: token, with: "")
        }

        // Replace hyphens with spaces
        name = name.replacingOccurrences(of: "-", with: " ")

        // Collapse multiple spaces
        while name.contains("  ") {
            name = name.replacingOccurrences(of: "  ", with: " ")
        }

        // Capitalize first letter
        if let first = name.first {
            name = first.uppercased() + name.dropFirst()
        }

        return name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onMenuTap) {
                    Image(systemName: "equal")
                        .font(.system(size: 20))
                        .foregroundColor(.primary)
                }
                .frame(width: 44, height: 44)

                Spacer()

                Button(action: { showModelPicker = true }) {
                    HStack(spacing: 4) {
                        Text(headerTitle)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if !currentModel.isEmpty && !isLoadingModel && !isDownloading {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .disabled((currentModel.isEmpty && !models.isEmpty) || isGenerating || isLoadingModel || isDownloading)

                Spacer()

                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                }
                .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 8)
            .frame(height: 52)

            if isDownloading {
                ProgressView(value: downloadProgress)
                    .progressViewStyle(.linear)
                    .tint(.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 4)
            }
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                models: models,
                currentModel: currentModel,
                onSelect: { model in
                    showModelPicker = false
                    onModelSelect(model)
                },
                onManageModels: onManageModels
            )
            .presentationDetents([.medium])
        }
    }
}

struct ModelPickerSheet: View {
    let models: [Model]
    let currentModel: String
    let onSelect: (Model) -> Void
    let onManageModels: () -> Void

    @Environment(\.dismiss) private var dismiss

    private func capitalizedName(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    private func isActiveModel(_ model: Model) -> Bool {
        let stem = model.filename.replacingOccurrences(of: ".gguf", with: "")
        return stem == currentModel || model.name == currentModel
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(models) { model in
                    Button(action: { onSelect(model) }) {
                        HStack {
                            Text(capitalizedName(model.name))
                                .foregroundColor(.primary)
                            Spacer()
                            if isActiveModel(model) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }

                Button(action: {
                    dismiss()
                    onManageModels()
                }) {
                    HStack {
                        Label("Manage Models", systemImage: "cube.box")
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
    }
}
