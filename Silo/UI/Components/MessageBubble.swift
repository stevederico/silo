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
                Text(isStreaming ? streamingContent : message.content)
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
                Text(isStreaming ? streamingContent : message.content)
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
