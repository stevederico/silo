import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    let isStreaming: Bool
    let streamingContent: String

    init(message: ChatMessage, isStreaming: Bool = false, streamingContent: String = "") {
        self.message = message
        self.isStreaming = isStreaming
        self.streamingContent = streamingContent
    }

    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
                Text(isStreaming ? streamingContent : message.displayContent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 20,
                            bottomLeadingRadius: 20,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 20
                        )
                    )
                    .frame(maxWidth: 280, alignment: .trailing)
            } else {
                Text(isStreaming ? streamingContent : message.displayContent)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct StreamingBubble: View {
    let content: String

    var body: some View {
        HStack {
            Text(content.isEmpty ? " " : content)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ThinkingIndicator: View {
    @State private var dotCount = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            Text("Thinking")
                .foregroundColor(.secondary)
                .font(.subheadline)
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 5, height: 5)
                        .opacity(index <= dotCount ? 1.0 : 0.3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 3
        }
    }
}
