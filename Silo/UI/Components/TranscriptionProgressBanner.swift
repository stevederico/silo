import SwiftUI
import UIKit

struct TranscriptionProgressBanner: View {
    let progress: Double
    let message: String
    let modelSuspended: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "waveform")
                Text(modelSuspended ? String(localized: "Transcribing (model unloaded)") : String(localized: "Transcribing…"))
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
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss")
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

/// Sticky banner from video pick until the user taps ✕.
struct VideoTranscriptBanner: View {
    enum Phase: Equatable {
        case preparing
        case transcribing(progress: Double, message: String, modelSuspended: Bool)
        case ready(characterCount: Int)
        case failed(message: String)
    }

    let phase: Phase
    var thumbnail: UIImage?
    let onViewTranscript: () -> Void
    let onDismiss: () -> Void
    let onCancelTranscription: (() -> Void)?

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onViewTranscript) {
                HStack(spacing: 8) {
                    leadingVisual
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .transcribing(let progress, _, _) = phase {
                            ProgressView(value: progress)
                        }
                    }
                    Spacer(minLength: 0)
                    if case .ready = phase {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!canViewTranscript)

            VStack(spacing: 8) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss video transcript")

                if let onCancelTranscription {
                    Button("Cancel", action: onCancelTranscription)
                        .font(.caption2)
                }
            }
        }
        .padding(12)
        .background(isFailed ? Color.red.opacity(0.12) : Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if let thumbnail, !isFailed {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(isFailed ? .red : .primary)
                .frame(width: 44, height: 44)
        }
    }

    private var iconName: String {
        switch phase {
        case .preparing, .transcribing: "waveform"
        case .ready: "doc.text"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        switch phase {
        case .preparing:
            return String(localized: "Video transcript")
        case .transcribing(_, _, let suspended):
            return suspended ? String(localized: "Transcribing (model unloaded)") : String(localized: "Transcribing video…")
        case .ready:
            return String(localized: "Video transcript attached")
        case .failed:
            return String(localized: "Transcription failed")
        }
    }

    private var subtitle: String {
        switch phase {
        case .preparing:
            return String(localized: "Preparing…")
        case .transcribing(_, let message, _):
            return message.isEmpty ? String(localized: "Starting…") : message
        case .ready(let count):
            return String(localized: "\(count) characters · tap to view")
        case .failed(let message):
            return message
        }
    }

    private var canViewTranscript: Bool {
        if case .ready = phase { return true }
        return false
    }
}

struct TranscriptAttachmentBanner: View {
    let characterCount: Int
    let onViewTranscript: () -> Void

    var body: some View {
        VideoTranscriptBanner(
            phase: .ready(characterCount: characterCount),
            thumbnail: nil,
            onViewTranscript: onViewTranscript,
            onDismiss: {},
            onCancelTranscription: nil
        )
    }
}