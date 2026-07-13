import SwiftUI

/// Presents the transcript sheet without blocking the main thread on large on-disk files.
struct TranscriptSheetLoader: View {
    @ObservedObject var llamaState: LlamaState
    @Environment(\.dismiss) private var dismiss

    @State private var transcript: String?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let transcript {
                TranscriptView(transcript: transcript, title: String(localized: "Transcript"))
            } else if loadFailed {
                NavigationStack {
                    ContentUnavailableView(
                        "Transcript unavailable",
                        systemImage: "doc.text",
                        description: Text("Could not load the transcript file.")
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { dismiss() } label: { Image(systemName: "xmark") }
                                .accessibilityLabel("Close")
                        }
                    }
                }
            } else {
                NavigationStack {
                    ProgressView("Loading transcript…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { dismiss() } label: { Image(systemName: "xmark") }
                                    .accessibilityLabel("Close")
                            }
                        }
                }
            }
        }
        .task(id: llamaState.currentConversation?.id) {
            transcript = nil
            loadFailed = false
            let text = await llamaState.loadResolvedTranscriptText()
            if let text, !text.isEmpty {
                transcript = text
            } else {
                loadFailed = true
            }
        }
    }
}