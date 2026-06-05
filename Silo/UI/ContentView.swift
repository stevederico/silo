import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject var llamaState = LlamaState()
    @StateObject var conversationManager = ConversationManager()
    @State private var inputText = ""
    @State private var drawerOffset: CGFloat = 0
    @State private var showSettings = false
    @State private var showManageModels = false
    @State private var showVideoPicker = false
    @State private var videoPickerItem: PhotosPickerItem?
    @State private var showTranscript = false
    @State private var videoImportError: String?
    @StateObject private var jobManager = TranscriptionJobManager()
    @StateObject private var voiceSession = VoiceSession()
    @FocusState private var isFocused: Bool
    @State private var voiceErrorMessage: String?

    private let drawerWidth: CGFloat = 300

    private var isDrawerOpen: Bool {
        drawerOffset > drawerWidth / 2
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Drawer
                DrawerView(
                    llamaState: llamaState,
                    conversationManager: conversationManager,
                    showSettings: $showSettings,
                    onClose: {
                        drawerOffset = 0
                    },
                    onNewChat: {
                        Task {
                            await llamaState.clear()
                        }
                        withAnimation(.easeOut(duration: 0.25)) {
                            drawerOffset = 0
                        }
                    },
                    onSelectConversation: { summary in
                        llamaState.loadConversation(id: summary.id)
                        withAnimation(.easeOut(duration: 0.25)) {
                            drawerOffset = 0
                        }
                    },
                    onDeleteConversation: { summary in
                        if summary.id == llamaState.currentConversation?.id {
                            Task {
                                await llamaState.clear()
                            }
                        }
                        conversationManager.delete(summary.id)
                    }
                )
                .frame(width: drawerWidth)
                .offset(x: -drawerWidth + drawerOffset)
                .zIndex(drawerOffset > 0 ? 1 : -1)

                // Main chat view
                VStack(spacing: 0) {
                    // Header
                    HeaderView(
                        currentModel: llamaState.currentModelName,
                        models: llamaState.downloadedModels,
                        isLoadingModel: llamaState.isLoadingModel,
                        isDownloading: llamaState.isDownloadingDefault,
                        isGenerating: llamaState.isGenerating,
                        downloadProgress: llamaState.defaultDownloadProgress,
                        modelLoadProgress: llamaState.modelLoadProgress,
                        onMenuTap: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                drawerOffset = drawerOffset > 0 ? 0 : drawerWidth
                            }
                        },
                        onModelSelect: { model in
                            let fileURL = llamaState.getDocumentsDirectory().appendingPathComponent(model.filename)
                            Task { try? await llamaState.loadModel(modelUrl: fileURL) }
                        },
                        onNewChat: {
                            Task {
                                await llamaState.clear()
                            }
                        },
                        onManageModels: {
                            showManageModels = true
                        }
                    )

                    if let modelError = llamaState.modelLoadError, !llamaState.isModelLoaded, !llamaState.isLoadingModel {
                        Text(modelError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }

                    if jobManager.isRunning {
                        TranscriptionProgressBanner(
                            progress: jobManager.progress,
                            message: jobManager.statusMessage,
                            modelSuspended: llamaState.modelSuspendedForSpeech,
                            onCancel: { jobManager.cancel() }
                        )
                    } else if let transcriptionError = jobManager.failureMessage {
                        TranscriptionErrorBanner(
                            message: transcriptionError,
                            onDismiss: { jobManager.clearFailure() }
                        )
                    } else if llamaState.transcriptCharacterCount > 0 {
                        TranscriptAttachmentBanner(
                            characterCount: llamaState.transcriptCharacterCount,
                            onViewTranscript: { showTranscript = true }
                        )
                    }

                    // Chat area
                    if llamaState.messages.isEmpty && !llamaState.isGenerating {
                        Spacer()
                        EmptyStateView()
                        Spacer()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(llamaState.messages) { message in
                                        MessageBubble(message: message)
                                            .id(message.id)
                                    }

                                    if llamaState.isGenerating && llamaState.isThinking && llamaState.currentResponse.isEmpty {
                                        ThinkingIndicator()
                                            .id("thinking")
                                    }

                                    if llamaState.isGenerating && !llamaState.currentResponse.isEmpty {
                                        StreamingBubble(content: llamaState.currentResponse)
                                            .id("streaming")
                                    }
                                }
                                .padding()
                                .padding(.bottom, 60)
                            }
                            .onChange(of: llamaState.messages.count) { _, _ in
                                if let lastMessage = llamaState.messages.last {
                                    withAnimation {
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                            .onChange(of: llamaState.currentResponse) { _, _ in
                                if llamaState.isGenerating {
                                    withAnimation {
                                        proxy.scrollTo("streaming", anchor: .bottom)
                                    }
                                }
                            }
                            // Fix 5: Scroll to thinking indicator
                            .onChange(of: llamaState.isThinking) { _, newValue in
                                if newValue {
                                    withAnimation {
                                        proxy.scrollTo("thinking", anchor: .bottom)
                                    }
                                }
                            }
                            // Fix 8: Scroll to bottom on conversation load
                            .onChange(of: llamaState.currentConversation?.id) { _, _ in
                                if let lastMessage = llamaState.messages.last {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        withAnimation {
                                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                        }
                                    }
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .onTapGesture {
                            isFocused = false
                        }
                    }

                    // Input composer
                    InputComposer(
                        text: $inputText,
                        isGenerating: llamaState.isGenerating,
                        isListening: voiceSession.isListening,
                        inputsDisabled: llamaState.modelSuspendedForSpeech || llamaState.speechSynthesizer.isSpeaking,
                        onSend: { Task { await submitMessage() } },
                        onStop: stopGeneration,
                        onVideoImport: { showVideoPicker = true },
                        onVoiceToggle: { Task { await handleVoiceToggle() } },
                        onHoldVoiceStart: { Task { await startVoiceInput() } },
                        onHoldVoiceEnd: { Task { await submitMessage() } },
                        focusState: $isFocused
                    )
                    if let voiceErrorMessage {
                        Text(voiceErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)
                    }
                    if let videoImportError {
                        Text(videoImportError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(x: drawerOffset)
                .overlay(
                    Color.black
                        .opacity(Double(drawerOffset / drawerWidth) * 0.3)
                        .allowsHitTesting(drawerOffset > 0)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.25)) {
                                drawerOffset = 0
                            }
                        }
                )
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            // Ignore gestures starting in bottom 80pt (Settings area)
                            guard value.startLocation.y < geometry.size.height - 80 else { return }
                            let translation = value.translation.width
                            if drawerOffset == 0 {
                                drawerOffset = min(max(0, translation), drawerWidth)
                            } else {
                                drawerOffset = min(max(0, drawerWidth + translation), drawerWidth)
                            }
                        }
                        .onEnded { value in
                            // Ignore gestures starting in bottom 80pt (Settings area)
                            guard value.startLocation.y < geometry.size.height - 80 else { return }
                            let velocity = value.predictedEndTranslation.width - value.translation.width
                            withAnimation(.easeOut(duration: 0.25)) {
                                if velocity > 100 || (drawerOffset > drawerWidth / 2 && velocity > -100) {
                                    drawerOffset = drawerWidth
                                } else {
                                    drawerOffset = 0
                                }
                            }
                        }
                )
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(llamaState: llamaState)
            }
            .sheet(isPresented: $showManageModels) {
                ManageModelsView(llamaState: llamaState)
            }
            .photosPicker(
                isPresented: $showVideoPicker,
                selection: $videoPickerItem,
                matching: .videos
            )
            .sheet(isPresented: $showTranscript) {
                if let text = llamaState.resolvedTranscriptText() {
                    TranscriptView(transcript: text, title: "Transcript")
                }
            }
        }
        .background(Color(.systemBackground))
        .onAppear {
            llamaState.conversationManager = conversationManager
            jobManager.llamaState = llamaState
            isFocused = true
            Task {
                if !llamaState.isModelLoaded, !llamaState.downloadedModels.isEmpty {
                    _ = await llamaState.ensureModelLoaded()
                }
            }
        }
        .onChange(of: voiceSession.partialTranscript) { _, newValue in
            guard voiceSession.isListening else { return }
            if !newValue.isEmpty {
                inputText = newValue
            }
        }
        .onChange(of: voiceSession.isListening) { _, isListening in
            if isListening {
                inputText = ""
                voiceErrorMessage = nil
            }
        }
        .onChange(of: voiceSession.errorMessage) { _, message in
            voiceErrorMessage = message
        }
        .onChange(of: videoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await handlePickedVideo(newItem) }
        }
        .onChange(of: jobManager.failureMessage) { _, message in
            videoImportError = message
        }
    }

    @MainActor
    private func handlePickedVideo(_ item: PhotosPickerItem) async {
        videoPickerItem = nil
        videoImportError = nil
        do {
            guard let movie = try await item.loadTransferable(type: ImportedVideoFile.self) else {
                videoImportError = "Could not load video from Photos."
                return
            }
            _ = try await jobManager.startJob(mediaURL: movie.url, llamaState: llamaState)
        } catch {
            videoImportError = error.localizedDescription
        }
    }

    @MainActor
    private func submitMessage() async {
        guard !llamaState.isGenerating else { return }

        if llamaState.modelSuspendedForSpeech {
            voiceErrorMessage = "Model is reloading after transcription. Wait a moment."
            return
        }

        if voiceSession.isListening {
            let spoken = await voiceSession.stopListening()
            if !spoken.isEmpty {
                inputText = spoken
            }
        }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            voiceErrorMessage = "No speech detected. Try again."
            return
        }

        voiceErrorMessage = nil

        if llamaState.downloadedModels.isEmpty {
            showManageModels = true
            return
        }

        if !llamaState.isModelLoaded {
            let loaded = await llamaState.ensureModelLoaded()
            if !loaded {
                voiceErrorMessage = llamaState.modelLoadError ?? "Could not load model."
                return
            }
        }

        let messageToSend = text
        inputText = ""
        await llamaState.complete(text: messageToSend)
    }

    private func stopGeneration() {
        Task {
            await llamaState.stop()
        }
    }

    private func startVoiceInput() async {
        guard !voiceSession.isListening else { return }
        if llamaState.speechSynthesizer.isSpeaking {
            llamaState.speechSynthesizer.stop()
        }
        guard !llamaState.modelSuspendedForSpeech else { return }

        isFocused = false
        voiceErrorMessage = nil
        do {
            try await voiceSession.startListening()
        } catch {
            voiceErrorMessage = error.localizedDescription
        }
    }

    private func handleVoiceToggle() async {
        if llamaState.speechSynthesizer.isSpeaking {
            llamaState.speechSynthesizer.stop()
            return
        }
        if llamaState.modelSuspendedForSpeech { return }

        if voiceSession.isListening {
            let spoken = await voiceSession.stopListening()
            if !spoken.isEmpty {
                inputText = spoken
            }
            await submitMessage()
            return
        }
        await startVoiceInput()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
