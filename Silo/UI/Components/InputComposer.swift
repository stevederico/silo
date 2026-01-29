import SwiftUI

struct InputComposer: View {
    @Binding var text: String
    let isGenerating: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    var focusState: FocusState<Bool>.Binding

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask anything", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .frame(minHeight: 32)
                .focused(focusState)
                .submitLabel(.send)
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
