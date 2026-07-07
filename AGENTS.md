# Silo

## Project Overview
Private on-device AI chat for iOS — llama.cpp + Metal GPU, GGUF models, zero network. Shipping on the App Store. No accounts, no telemetry, works fully offline.

## Architecture
- `Silo/SiloApp.swift` — app entry
- `Silo/UI/` — SwiftUI chat interface, `ConversationManager`, `LlamaState` (inference state), download/load buttons
- `Silo/Speech/` — transcription pipeline (whisper.cpp): `TranscriptionEngine`, `TranscriptionJobManager`, `VoiceSession`, `AudioExtractor`, plus TTS via `SpeechSynthesizerService`
- `llama.xcframework` / `whisper.xcframework` — prebuilt inference engines (do NOT delete)

## Build
```bash
cd /tmp && git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp && ./build-xcframework.sh
cp -R build-apple/llama.xcframework <path-to-silo>/
open Silo.xcodeproj
```
Build and run on iPhone or simulator, iOS 18.2+.

## Key Patterns
- **Actor-isolated inference** — one model loaded at a time, thread-safe. All llama.cpp calls go through the actor; don't call the C API off it.
- Metal GPU acceleration with BF16 compute on supported hardware.
- Models: Gemma 4 E2B (Q4 QAT default), Ministral 3B, LFM 2.5, or any user-supplied GGUF from a Hugging Face URL.
- Conversation history stored locally only, never uploaded.

## Don't
- Don't add network requests for inference — on-device is the entire product promise (privacy, offline, uncensored).
- Don't remove `llama.xcframework` / `whisper.xcframework` — they're the engines.
- Don't add analytics, tracking, or accounts.
