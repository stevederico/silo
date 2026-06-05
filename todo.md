# Silo Todo

## Local Speech / Transcription (feature/local-speech-video-voice)

- [ ] Fix unreliable transcription for ~30s video/audio clips
  - Current: Apple's SFSpeech (in `Silo/Speech/TranscriptionEngine.swift`, `AudioExtractor.swift`, etc.) often returns very short output (~98 chars) and misses a lot of content.
  - Audio export is M4A; on-device forced; chunking + timeout hacks in place.
  - Goal: Reliable, high-quality local transcription with timestamps.

- [x] Add whisper.cpp for transcription (aligns with existing llama.cpp integration via xcframework)
  - **See detailed plan: `plan-whisper-cpp-integration.md`** (marked COMPLETED)
  - Use similar pattern: `LlamaCppEngine` / `LibLlama.swift` style.
  - Provides built-in accurate segment + word timestamps (basic [mm:ss] in current output).
  - Handles full clips without truncation issues.
  - Integrated for video import / voice features.
  - Model management + UI added (small.en-q5_0 recommended).
  - Tracked internally as whisper-plan-* tasks (all completed).
  - **User action needed**: Add whisper.xcframework + download model to test.

- [ ] Speaker identification / diarization (HOLD OFF)
  - Requirements: Identify distinct speakers with consistent labels (e.g. "Speaker 1", "Speaker 2") + accurate start/end timestamps per segment/utterance.
  - Use case: Multi-speaker video clips, meetings, interviews. Output structured transcripts (not just plain text).
  - Fully local / on-device only.
  - No CocoaPods (use SPM or manual xcframework like llama.cpp).
  - Transcription base will likely be whisper.cpp (for timestamps).
  - Options considered (research done):
    - Picovoice Falcon (via SPM: https://github.com/Picovoice/falcon.git) + whisper.cpp merge (strong pairing, C API).
    - SpeakerKit (argmaxinc via SPM in https://github.com/argmaxinc/argmax-oss-swift) — pure Swift + Core ML (Pyannote).
    - FluidAudio (via SPM: https://github.com/FluidInference/FluidAudio.git) — Swift/Core ML diarization + VAD.
    - whisper.cpp tinydiarize (`-tdrz` / small.en-tdrz model) — only basic speaker *turn* detection (`[SPEAKER_TURN]` markers), **not** full labeled speakers.
  - Post-processing needed: Time-overlap alignment between diarizer segments and whisper timed output.
  - Future: Structured output (JSON/array of {speaker, start, end, text}), nice UI rendering in TranscriptView.
  - Status: Hold off for now. Revisit after core transcription (whisper.cpp) is solid.

- [ ] Improve AudioExtractor for better compatibility
  - Prefer 16kHz mono WAV (linear PCM) export instead of (or in addition to) M4A.
  - Helps both Apple Speech (current) and future whisper.cpp / diarizers.

- [ ] Update transcript storage/output
  - Current: Plain string in checkpoints and `TranscriptView`.
  - Future: Support rich format with speakers + timestamps when diarization is added.

## Notes
- Existing llama.cpp integration (xcframework + engines) is a good model for adding whisper.cpp.
- Speech code already suspends llama model during transcription jobs (`LlamaState.suspendModelForSpeech()`).
- Keep everything fully local/on-device where possible.
- Revisit this todo after basic reliable transcription is working.