import SwiftUI

struct DrawerView: View {
    @ObservedObject var llamaState: LlamaState
    @ObservedObject var conversationManager: ConversationManager
    @Binding var showSettings: Bool
    let onClose: () -> Void
    let onNewChat: () -> Void
    let onSelectConversation: (ConversationSummary) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(alignment: .center, spacing: 4) {
                    Image(colorScheme == .dark ? "icon-white" : "icon-black")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .foregroundColor(.primary)
                    Text("Silo")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Button(action: onNewChat) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .frame(height: 52)

                // Conversations list
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(conversationManager.conversations) { conversation in
                            ConversationRow(
                                title: conversation.displayTitle,
                                date: conversation.relativeDate,
                                isSelected: conversation.id == conversationManager.currentConversationId,
                                action: { onSelectConversation(conversation) }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }

                Spacer()

                Divider()

                // Settings at bottom
                MenuRow(icon: "gear", title: "Settings") {
                    onClose()
                    showSettings = true
                }
                .padding(.vertical, 8)
            }
            .background(Color(.systemBackground))

            // Right border
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)
        }
    }
}

struct ConversationRow: View {
    let title: String
    let date: String
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color(.systemGray5) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct MenuRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.primary)
                    .frame(width: 24)
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Acknowledgement Link Component

struct AcknowledgementLink: View {
    let title: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var llamaState: LlamaState
    @Environment(\.dismiss) private var dismiss

    @State private var showManageModels = false
    @State private var showSystemPromptEditor = false

    var body: some View {
        NavigationView {
            List {
                // MARK: - Models Section
                Section {
                    Button(action: { showManageModels = true }) {
                        HStack {
                            Label("Manage Models", systemImage: "cube.box")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("\(llamaState.downloadedModels.count)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color(.systemGray5))
                                .cornerRadius(6)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - System Prompt Section
                Section {
                    Button(action: { showSystemPromptEditor = true }) {
                        HStack {
                            Label("System Prompt", systemImage: "text.alignleft")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("\(llamaState.systemPrompt.count) chars")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color(.systemGray5))
                                .cornerRadius(6)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - Context Size Section
                Section {
                    Picker(selection: $llamaState.contextSize, label:
                        Label("Context Size", systemImage: "text.word.spacing")
                            .foregroundColor(.primary)
                    ) {
                        Text("2048").tag(UInt32(2048))
                        Text("4096").tag(UInt32(4096))
                        Text("8192").tag(UInt32(8192))
                        Text("16384").tag(UInt32(16384))
                    }
                } footer: {
                    Text("Larger context allows longer conversations but uses more memory. Model will reload on change.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // MARK: - Acknowledgements Section
                Section {
                    DisclosureGroup {
                        AcknowledgementLink(
                            title: "Llama.cpp (MIT License)",
                            url: "https://github.com/ggerganov/llama.cpp/blob/master/LICENSE"
                        )
                        AcknowledgementLink(
                            title: "Meta Llama (Llama 3 Community License)",
                            url: "https://www.llama.com/llama3/license/"
                        )
                        AcknowledgementLink(
                            title: "Phi-3.5-mini (MIT License)",
                            url: "https://huggingface.co/microsoft/Phi-3.5-mini-instruct/blob/main/LICENSE"
                        )
                        AcknowledgementLink(
                            title: "Smol2 (Apache 2.0 License)",
                            url: "https://huggingface.co/HuggingFaceTB/SmolLM2-360M-Instruct/tree/main"
                        )
                    } label: {
                        Label("Open Source Licenses", systemImage: "doc.text")
                            .foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle("Settings")
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
        .sheet(isPresented: $showManageModels) {
            ManageModelsView(llamaState: llamaState)
        }
        .sheet(isPresented: $showSystemPromptEditor) {
            SystemPromptEditorView(llamaState: llamaState)
        }
    }
}
