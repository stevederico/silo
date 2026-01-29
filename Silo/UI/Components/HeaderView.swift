import SwiftUI

struct HeaderView: View {
    let currentModel: String
    let models: [Model]
    let onMenuTap: () -> Void
    let onModelSelect: (Model) -> Void
    let onNewChat: () -> Void
    let onManageModels: () -> Void

    @State private var showModelPicker = false

    private var truncatedModelName: String {
        if currentModel.isEmpty {
            // Only show "No Model" if no models are installed
            return models.isEmpty ? "No Model" : ""
        }
        let capitalized = currentModel.prefix(1).uppercased() + currentModel.dropFirst()
        if capitalized.count > 15 {
            return String(capitalized.prefix(15)) + "..."
        }
        return capitalized
    }

    var body: some View {
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
                    Text(truncatedModelName)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !currentModel.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(currentModel.isEmpty && !models.isEmpty)

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

    var body: some View {
        NavigationView {
            List {
                ForEach(models) { model in
                    Button(action: { onSelect(model) }) {
                        HStack {
                            Text(capitalizedName(model.name))
                                .foregroundColor(.primary)
                            Spacer()
                            if model.name == currentModel {
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
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
