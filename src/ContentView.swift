import SwiftUI

struct ContentView: View {
    @StateObject var llamaState = LlamaState()
    @State private var multiLineText = ""
    @State private var showingHelp = false    // To track if Help Sheet should be shown
    @FocusState private var isFocused: Bool
    @State private var isSendVisible = true
    
    var body: some View {
        NavigationView {
            
            VStack {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(llamaState.messageLog)
                        .font(.system(size: 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                       
                }.onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                
                HStack {
                    TextEditor(text: $multiLineText)
                        .frame(height: 24)
                        .padding()
                        .font(.system(size: 18))
                        .focused($isFocused)
                        .onAppear {
                            isFocused = true
                        }
                    
                    if isSendVisible {
                        Button(action: {
                            sendText()
                        }) {
                            Image(systemName: "arrow.up").foregroundColor(.primary)
                        }.cornerRadius(20.0).padding(.trailing, 12)
                    } else {
                        Button(action: {
                            stopTapped()
                        }) {
                            Image(systemName: "stop.circle.fill")
                        }.cornerRadius(20.0).padding(.trailing, 12)
                    }
                    
                }.overlay(
                    RoundedRectangle(cornerRadius: 40) // Border with rounded corners
                        .stroke(Color.gray, lineWidth: 0.5)
                )
                .buttonStyle(.bordered)
                .padding()
                
                
            }
            .navigationBarTitle(llamaState.currentModelName, displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        // Action for the left button
                        Task {
                            await llamaState.clear()
                        }
                    }) {
                        Image(systemName: "trash").foregroundColor(.primary) // Adapts to light/dark mode

                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        // Action for the left button
                    }) {
                        NavigationLink(destination: DrawerView(llamaState: llamaState)) {
                            Image(systemName: "gear").foregroundColor(.primary) // Adapts to light/dark mode

                        }
                    }
                }
            }
            
        }
    }
    
    func stopTapped(){
        Task {
            await llamaState.stop()
            multiLineText = ""
        }
    }
    
    func sendText() {
        let textToComplete = multiLineText // Preserve the original text
        isFocused = false
        Task {
            isSendVisible = false
            multiLineText = "" // Clear after capturing

            await llamaState.complete(text: textToComplete) // Pass the preserved text
            
            isSendVisible = true // Ensure visibility is restored only after completion
        }
    }

    
    struct DrawerView: View {
        
        @ObservedObject var llamaState: LlamaState
        @State private var showingHelp = false
        func delete(at offsets: IndexSet) {
            offsets.forEach { offset in
                let model = llamaState.downloadedModels[offset]
                let fileURL = getDocumentsDirectory().appendingPathComponent(model.filename)
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    print("Error deleting file: \(error)")
                }
            }
            
            // Remove models from downloadedModels array
            llamaState.downloadedModels.remove(atOffsets: offsets)
        }
        
        func getDocumentsDirectory() -> URL {
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            return paths[0]
        }
        var body: some View {
            List {
                
                Section(header: Text("System Prompt")) {
                    TextEditor(text: $llamaState.systemPrompt)
                        .frame(minHeight: 100) // Adjust height as needed
                }
               
                Section(header: Text("Downloaded Models")) {
                    ForEach(llamaState.downloadedModels) { model in
                        DownloadButton(llamaState: llamaState, modelName: model.name, modelUrl: model.url, filename: model.filename)
                    }
                    .onDelete(perform: delete)
                }
                Section(header: Text("Models For Download")) {
                    ForEach(llamaState.undownloadedModels) { model in
                        if (model.rec! == true) {
                            DownloadButton(llamaState: llamaState, modelName: model.name, modelUrl: model.url, filename: model.filename)
                        }
                    
                    }
                }
                Section(header: Text("Hugging Face")) {
                    HStack {
                        InputButton(llamaState: llamaState)
                    }
                    VStack(alignment: .leading) {
                                       VStack(alignment: .leading) {
                                           Text("1. Make sure the model is in GGUF format")
                                           Text("2. Copy the download link of the model")
                                           Text("3. Paste URL box above, tap Download")
                                       }
                                       Spacer()
                                      }
                }
                Section(header: Text("Acknowledgements")) {
                    Link("Llama.cpp (MIT License)", destination: URL(string: "https://github.com/ggerganov/llama.cpp/blob/master/LICENSE")!)
                    Link("Meta Llama (Llama 3 Community License)", destination: URL(string: "https://www.llama.com/llama3/license/")!)
                    Link("Phi-3.5-mini (MIT License)", destination: URL(string: "https://huggingface.co/microsoft/Phi-3.5-mini-instruct/blob/main/LICENSE")!)
                    Link("Smol2 (Apache 2.0 License)", destination: URL(string: "https://huggingface.co/HuggingFaceTB/SmolLM2-360M-Instruct/tree/main")!)
                }

                
                
            }
            .listStyle(GroupedListStyle())
            .navigationBarTitle("Settings", displayMode: .inline)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
