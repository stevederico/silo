import SwiftUI

struct SystemPromptEditorView: View {
    @ObservedObject var llamaState: LlamaState
    @Environment(\.dismiss) private var dismiss

    @State private var editedPrompt: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextEditor(text: $editedPrompt)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGray6))

                Divider()

                HStack {
                    Spacer()
                    Text("\(editedPrompt.count) characters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
            }
            .navigationTitle("System Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        llamaState.systemPrompt = editedPrompt
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            editedPrompt = llamaState.systemPrompt
        }
    }
}
