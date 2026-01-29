import SwiftUI

struct ContentView: View {
    @StateObject var llamaState = LlamaState()
    @StateObject var conversationManager = ConversationManager()
    @State private var inputText = ""
    @State private var drawerOffset: CGFloat = 0
    @State private var showSettings = false
    @State private var showManageModels = false
    @FocusState private var isFocused: Bool

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
                    }
                )
                .frame(width: drawerWidth)
                .offset(x: -drawerWidth + drawerOffset)

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
                            try? llamaState.loadModel(modelUrl: fileURL)
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
                        .onTapGesture {
                            isFocused = false
                        }
                    }

                    // Input composer
                    InputComposer(
                        text: $inputText,
                        isGenerating: llamaState.isGenerating,
                        onSend: sendMessage,
                        onStop: stopGeneration,
                        focusState: $isFocused
                    )
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
        }
        .background(Color(.systemBackground))
        .onAppear {
            llamaState.conversationManager = conversationManager
            isFocused = true
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !llamaState.isGenerating else { return }

        // Show manage models if no models installed
        if llamaState.downloadedModels.isEmpty {
            showManageModels = true
            return
        }

        inputText = ""

        Task {
            await llamaState.complete(text: text)
        }
    }

    private func stopGeneration() {
        Task {
            await llamaState.stop()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
