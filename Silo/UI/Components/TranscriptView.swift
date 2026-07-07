import SwiftUI

struct TranscriptView: View {
    let transcript: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    @State private var showTimestamps = true

    private var displayTranscript: String {
        guard !showTimestamps else { return transcript }
        return transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripTimestampPrefix(from: String($0)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a leading `[MM:SS]` or `[HH:MM:SS]` prefix; leaves the line unchanged if none.
    private func stripTimestampPrefix(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              let close = trimmed.firstIndex(of: "]"),
              close > trimmed.startIndex
        else { return line }

        let bracketContent = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        let isTimestamp = bracketContent.allSatisfy { $0.isNumber || $0 == ":" }
        guard isTimestamp else { return line }

        var rest = trimmed[trimmed.index(after: close)...]
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    private var wordCount: Int {
        displayTranscript.split { $0.isWhitespace || $0.isNewline }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(displayTranscript)
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
                    Button {
                        showTimestamps.toggle()
                    } label: {
                        Image(systemName: showTimestamps ? "clock.fill" : "clock")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: displayTranscript) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = displayTranscript
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("\(wordCount) words · \(displayTranscript.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
    }
}