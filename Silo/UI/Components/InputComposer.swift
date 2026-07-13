import SwiftUI

struct InputComposer: View {
    @Binding var text: String
    let isGenerating: Bool
    let isListening: Bool
    var inputsDisabled: Bool = false
    let onSend: () -> Void
    let onStop: () -> Void
    let onVideoImport: () -> Void
    let onVoiceToggle: () -> Void
    let onHoldVoiceStart: () -> Void
    let onHoldVoiceEnd: () -> Void
    var focusState: FocusState<Bool>.Binding

    private let holdToTalkDelay: Duration = .milliseconds(450)
    @State private var holdEngaged = false
    @State private var holdTask: Task<Void, Never>?

    private var canHoldToTalk: Bool {
        !inputsDisabled && !isGenerating && !isListening
    }

    private var holdToTalkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard canHoldToTalk, !holdEngaged, holdTask == nil else { return }
                holdTask = Task { @MainActor in
                    try? await Task.sleep(for: holdToTalkDelay)
                    guard !Task.isCancelled else { return }
                    holdEngaged = true
                    focusState.wrappedValue = false
                    onHoldVoiceStart()
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                guard holdEngaged else { return }
                holdEngaged = false
                onHoldVoiceEnd()
            }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button(action: onVideoImport) {
                    Label("Video transcript", systemImage: "film")
                }
                .disabled(isGenerating || isListening || inputsDisabled)

                Button(action: onVoiceToggle) {
                    if isListening {
                        Label("Stop & send", systemImage: "mic.fill")
                    } else {
                        Label("Voice input", systemImage: "mic")
                    }
                }
                .disabled(isGenerating || inputsDisabled)
            } label: {
                Image(systemName: isListening ? "mic.fill" : "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isListening ? .red : .primary)
                    .frame(width: 32, height: 32)
            }
            .disabled(inputsDisabled && !isListening)

            TextField(
                inputsDisabled ? String(localized: "Waiting for model…") : (isListening ? String(localized: "Listening…") : String(localized: "Ask anything")),
                text: $text,
                axis: .vertical
            )
                .lineLimit(1...6)
                .frame(minHeight: 32)
                .focused(focusState)
                .disabled(inputsDisabled)
                .submitLabel(.send)
                .simultaneousGesture(holdToTalkGesture)
                .onSubmit {
                    if !text.isEmpty && !isGenerating {
                        onSend()
                    }
                }

            Button(action: {
                if isGenerating {
                    onStop()
                } else {
                    onSend()
                }
            }) {
                Image(systemName: isGenerating ? "square.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 32, height: 32)
                    .background(text.isEmpty && !isGenerating ? Color.gray : Color.white)
                    .clipShape(Circle())
            }
            .disabled(text.isEmpty && !isGenerating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(18)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}