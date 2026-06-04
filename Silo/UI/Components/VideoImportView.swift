import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct VideoImportView: View {
    @ObservedObject var transcriptionService: VideoTranscriptionService
    @Environment(\.dismiss) private var dismiss

    let onTranscriptReady: (String) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Import an interview video. Transcription runs on your device only — nothing is uploaded.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if transcriptionService.isTranscribing {
                    ProgressView(value: transcriptionService.progress)
                        .padding(.horizontal)
                    Text(transcriptionService.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel) {
                        transcriptionService.cancel()
                    }
                } else {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Choose from Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Video transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(transcriptionService.isTranscribing)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie, .audio, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await transcribe(url: url) }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .onChange(of: pickerItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadFromPhotos(newItem) }
            }
        }
    }

    private func loadFromPhotos(_ item: PhotosPickerItem) async {
        errorMessage = nil
        do {
            guard let movie = try await item.loadTransferable(type: VideoFile.self) else {
                errorMessage = "Could not load video from Photos."
                return
            }
            await transcribe(url: movie.url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func transcribe(url: URL) async {
        errorMessage = nil
        do {
            let transcript = try await transcriptionService.transcribe(mediaURL: url)
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "No speech detected in this file."
                return
            }
            onTranscriptReady(transcript)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Transfers video data into a temp file for AVFoundation + Speech.
private struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("silo-import-\(UUID().uuidString).mov")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}