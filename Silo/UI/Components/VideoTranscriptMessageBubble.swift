import SwiftUI

/// User message bubble for an attached video transcript (tap opens the full transcript).
struct VideoTranscriptMessageBubble: View {
    let characterCount: Int
    let thumbnail: UIImage?
    let onTap: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: onTap) {
                HStack(spacing: 10) {
                    thumbnailView
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Video transcript")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("\(characterCount) characters · tap to view")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.systemGray5))
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 20,
                        bottomLeadingRadius: 20,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: 20
                    )
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 280, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray4))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
        }
    }
}