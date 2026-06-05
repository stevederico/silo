import SwiftUI

struct TranscriptionProgressBanner: View {
    let progress: Double
    let message: String
    let modelSuspended: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "waveform")
                Text(modelSuspended ? "Transcribing (model unloaded)" : "Transcribing…")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .font(.caption)
            }
            ProgressView(value: progress)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

struct TranscriptionErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Transcription failed")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .font(.caption)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.red.opacity(0.12))
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

struct TranscriptAttachmentBanner: View {
    let characterCount: Int
    let onViewTranscript: () -> Void

    var body: some View {
        Button(action: onViewTranscript) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video transcript attached")
                        .font(.subheadline.weight(.medium))
                    Text("\(characterCount) characters · tap to view")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}