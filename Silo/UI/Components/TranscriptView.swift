import SwiftUI

struct TranscriptView: View {
    let transcript: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    private var wordCount: Int {
        transcript.split { $0.isWhitespace || $0.isNewline }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(transcript)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: transcript) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = transcript
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("\(wordCount) words · \(transcript.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }
}