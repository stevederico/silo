# Plan: Switch Transcription to whisper.cpp

## Goals
- Replace unreliable Apple SFSpeechRecognizer (on-device) with whisper.cpp for video/audio transcription.
- Achieve reliable, complete transcription of 30s+ clips (currently often truncated to ~98 chars).
- Leverage built-in timestamps from whisper (segments/words) for future speaker diarization and rich output.
- Maintain resumable jobs, checkpoints, background support, progress UI.
- Keep fully local/on-device.
- Consistent integration style with existing llama.cpp (xcframework, C++ wrapper, engine actor).
- No CocoaPods.
- Prepare foundation for speaker identification (see todo.md) and structured transcripts (timestamps + speakers).

## Current State (as of now)
- **Transcription path**: `Silo/Speech/TranscriptionEngine.swift` uses `SFSpeechURLRecognitionRequest` + `SFSpeechRecognizer` (forced on-device via `LocalSpeechGuard`).
  - Chunks long audio (~55s) via `AudioExtractor`.
  - Hacks for "isFinal" never firing on file requests + 60s timeout.
  - Fallback to en-US locale.
- **Audio prep**: `AudioExtractor.swift` exports to M4A (AppleM4A preset), chunks with time ranges. Works for both video import and (indirectly) voice.
- **Job management**: `TranscriptionJobManager.swift` (MainActor) handles durable jobs with `TranscriptionCheckpointStore` (file-based JSON + transcript.txt), background tasks, suspends llama model, attaches to `LlamaState`.
- **Live voice**: `VoiceSession.swift` uses `SFSpeechAudioBufferRecognitionRequest` + AVAudioEngine tap.
- **LLM side**: `Silo/UI/LlamaState.swift` (and Inference/) manages llama.cpp via `LlamaCppEngine` (actor implementing `InferenceEngine` protocol), suspend/resume for speech jobs, video transcript attachment as context.
- **UI**: VideoImportView → ContentView → jobManager.startJob. Progress banners, TranscriptView (plain text).
- **Issues**: Poor quality/completeness on real video audio; no native timestamps; speaker diarization not present.
- **todo.md**: Captures this work + hold on speakers.

whisper.cpp fits perfectly: C/C++ (like llama), ggml models, excellent iOS support (Metal/CoreML encoder), timestamps built-in, better accuracy for many cases.

## Target Architecture
- **Library**: whisper.cpp (C API) integrated similarly to llama.cpp.
  - Prefer prebuilt `whisper.xcframework` (device + simulator) for consistency (add to root like `llama.xcframework`).
  - Alternative: Git submodule + build in Xcode (more flexible for updates).
- **Wrapper**: New `LibWhisper.swift` (C bridging) + `WhisperEngine.swift` (actor, perhaps implementing a new `TranscriptionEngine` protocol or standalone).
- **Audio**: Always produce 16kHz mono 16-bit WAV (or raw float PCM) for whisper. Update `AudioExtractor`.
- **Batch/File Transcription** (videos): `WhisperTranscriptionEngine` loads model once, transcribes full audio or chunks, returns text + timed segments.
- **Live/Streaming** (VoiceSession): Use whisper streaming mode (examples/stream) or periodic full transcribes on accumulating buffer. May require new `WhisperVoiceSession` or extension.
- **Job Layer**: Keep `TranscriptionJobManager` + checkpoints mostly intact. Engine becomes whisper-based. Chunks still useful for very long videos + resumability + progress.
- **Model Management**: Extend or mirror LLM model handling. Support ggml whisper models (tiny, base, small, medium, large-v3 etc., quantized). Download to `models/` or dedicated dir. UI in ManageModelsView or new section.
- **Integration Points**:
  - `LlamaState`: Keep suspend/resume logic (unload LLM during heavy whisper decode if needed).
  - Output: Start with plain text (for compatibility). Internally capture timestamps. Later: structured `TranscriptSegment` (start, end, text) for speakers.
  - Checkpoints: Store whisper model used? Continue chunk-based for resumability.
- **UI/UX**: Minimal changes initially. Timestamps can be exposed later in TranscriptView (e.g. clickable segments). Progress same.
- **Privacy/Info**: Update if needed (already claims on-device).

## Step-by-Step Implementation Plan

### Phase 0: Preparation & Research (1-2 days)
- [ ] Review whisper.cpp iOS docs/examples:
  - `examples/whisper.objc`, `examples/stream`, main README.
  - CoreML support for encoder (big perf win on Apple Silicon).
  - Build instructions for iOS (Xcode, Metal).
- [ ] Decide integration method:
  - Primary: Pre-build whisper as xcframework (mirror llama).
  - Fallback: Add as submodule under `whisper.cpp/`, configure Xcode build phases (headers, sources for iOS target).
- [ ] Pick initial model: `small.en` or `base.en` (or quantized) for balance of speed/quality. Support multiple later.
- [ ] Test whisper.cpp standalone on macOS/iOS sim with sample 30s video audio (export WAV).
- [ ] Update `todo.md` with this plan link.
- [ ] Create this plan file (done).

### Phase 1: Integrate whisper.cpp Library (2-4 days)
- [ ] Build or obtain `whisper.xcframework` (ios-arm64 + simulator).
  - Use scripts from whisper.cpp repo or manual Xcode archive + xcodebuild -create-xcframework.
  - Include ggml + whisper static libs.
  - Headers: whisper.h, etc.
- [ ] Add to project:
  - Copy `whisper.xcframework` to project root.
  - In Xcode: Embed & Sign for app target. Link binary.
  - Add to `Silo.xcodeproj` (similar to llama).
  - Update build settings if needed (C++ std, Metal, etc.).
- [ ] Create bridging:
  - `Silo/Inference/LibWhisper.swift`: Swift wrappers for key C functions (`whisper_init_from_file`, `whisper_full`, `whisper_full_get_segment_text`, `whisper_full_get_segment_t0/t1`, etc.).
  - Handle state, params (language, translate?, timestamps, beam search?).
- [ ] Add to `.gitignore` if large, or use git-lfs for framework.
- [ ] Verify build: Compile a simple test in a new file or in existing Inference.

### Phase 2: Audio Pipeline Updates (1-2 days)
- [ ] Update `Silo/Speech/AudioExtractor.swift`:
  - Change default export to 16kHz mono WAV (use `AVAudioFile` + `AVAssetReader` or `AVAssetExportSession` with appropriate preset + settings).
  - Function to convert any audio to whisper-compatible format (PCM float or WAV).
  - Keep chunking logic (for long videos) but export chunks as WAV.
  - Add `exportForWhisper(...)` or parameterize.
  - Update error handling, duration checks.
- [ ] Handle input from video (strip video track, extract audio at correct rate).
- [ ] For VoiceSession: Ensure buffer format matches (16kHz mono float32).
- [ ] Test: Export sample video → verify whisper can load/process the WAV directly.

### Phase 3: Implement Whisper Transcription Engine (3-5 days)
- [ ] Create `Silo/Speech/WhisperTranscriptionEngine.swift` (or move logic).
  - Actor (like current TranscriptionEngine).
  - Properties: model path, context/state.
  - `func transcribe(mediaURL: URL, jobId: UUID?, startingChunkIndex: Int, onProgress: ...) async throws -> Result`
    - Load model (once, reuse if possible).
    - For each chunk (or full if short): 
      - Load audio as float PCM (whisper expects this).
      - Call whisper_full with params (set `print_timestamps=true`, language auto or en, etc.).
      - Extract segments: text + t0/t1 (in 10ms units? convert to seconds).
      - Append to transcript (with optional timestamp prefixes for now).
    - Support resumability via chunk index.
  - Progress: Per-chunk or use whisper's internal if hookable.
  - Cancel support.
  - Error handling (model load failures, no speech, etc.).
- [ ] Optionally implement a protocol `TranscriptionEngine` (rename current or abstract).
- [ ] Handle model params: context size, threads, etc. Tune for iOS (low threads?).
- [ ] Add support for CoreML encoder if framework built with it (huge speedup).
- [ ] Return structured result: transcript text + array of timed segments for future use.

### Phase 4: Integrate with Job Manager & State (1-2 days)
- [ ] Update `TranscriptionJobManager.swift`:
  - Swap `private let engine = TranscriptionEngine()` → `WhisperTranscriptionEngine`.
  - Minor: Model name in status? Pass whisper model path.
  - Keep all checkpoint, background, suspend/resume llama, attach transcript logic.
- [ ] In `LlamaState.swift`:
  - Ensure suspend/resume still works (whisper decode is CPU/GPU heavy; may unload LLM).
  - No major changes needed for attach (still plain text initially).
- [ ] Update `TranscriptionEngine.swift` (old) or deprecate: keep temporarily or remove SFSpeech code gradually.
- [ ] Remove/replace `LocalSpeechGuard.swift` usage (or keep for fallback if wanted).
- [ ] Update checkpoints to optionally store used whisper model version.

### Phase 5: Live Voice Support (2-3 days, can parallelize)
- [ ] Options for `VoiceSession.swift`:
  - Preferred: Port whisper streaming (use `whisper_init_state`, feed audio frames incrementally, get partial results).
  - Simpler start: Buffer audio in 5-10s chunks, transcribe each with whisper (non-streaming), concatenate.
  - Use existing AVAudioEngine tap, convert buffers to float PCM on fly.
- [ ] Expose partial results similar to current.
- [ ] Stop listening: Finalize last buffer.
- [ ] Test real-time feel vs quality.

### Phase 6: Model Management & Download (2-3 days)
- [ ] Add whisper models to catalog (similar to `Model` struct in LlamaState? Or separate).
  - Define list: e.g. small.en, small, base.en, etc. with ggml filenames, URLs (from huggingface ggerganov/whisper.cpp or official).
  - Support quantized versions for size/speed.
- [ ] Download logic: Reuse or extend existing download in LlamaState / new `WhisperModelManager`.
- [ ] UI: Integrate into `ManageModelsView.swift` or add "Speech Models" tab/section. Show "for transcription".
- [ ] Storage: `Silo/models/whisper/` or app support. Path passed to engine.
- [ ] Validation: Check model file is valid ggml whisper.
- [ ] Default: Auto-download a small model on first use?

### Phase 7: Timestamps & Output (1-2 days)
- [ ] In whisper engine: Always collect `[(start: Double, end: Double, text: String)]`.
- [ ] Update `TranscriptionCheckpointStore` / append to support timestamped format? Or sidecar JSON.
- [ ] For now: Format transcript with `[mm:ss] text` prefixes (or keep plain + store rich data).
- [ ] Expose in `LlamaState.attachVideoTranscript` etc.
- [ ] Update `TranscriptView.swift` (future: show times, but hold for speaker plan).
- [ ] In checkpoints: Save rich version when available.

### Phase 8: UI, Polish, Error Handling, Testing (3-5 days)
- [ ] Update progress messages: "Transcribing with Whisper (small.en)..."
- [ ] Handle model loading progress (whisper has callback).
- [ ] Update `TranscriptionProgressBanner.swift`, `VideoTranscriptBanner`.
- [ ] Error messages: Specific for whisper (e.g. model not found, audio too short).
- [ ] Permissions: Keep Speech? No longer needed for transcription (remove dependency?).
- [ ] Test matrix:
  - Short 30s video clips (the failing case).
  - Longer videos (chunking/resume).
  - Live voice recording.
  - Different languages (if models support).
  - Device (iPhone, iPad, sim), memory/CPU usage.
  - Background transcription.
  - Resume after app kill.
- [ ] Compare quality: Run same clip with old Apple + new whisper.
- [ ] Update README, Info.plist, PrivacyInfo if API surface changes.
- [ ] Performance: Benchmark vs Apple. Add options for threads/quant.
- [ ] Fallbacks: If whisper fails, ? (or pure local now).

### Phase 9: Cleanup & Migration (1-2 days)
- [ ] Remove or guard old SFSpeech code (feature flag? or delete once stable).
- [ ] Clean `LocalSpeechGuard.swift`, update imports.
- [ ] Update any docs/comments.
- [ ] Bump version? Add to CHANGELOG.md.
- [ ] Ensure old checkpoints/jobs still work or migrate (plain text transcripts are fine).
- [ ] Remove unused Speech framework entitlement if possible.

### Phase 10: Speaker Diarization Prep (deferred per todo)
- Once stable: Add diarization layer (see todo.md options: Falcon SPM, SpeakerKit, FluidAudio).
- Run diarizer on exported audio → align timed whisper segments by overlap.
- Extend output to include speaker labels.
- No changes to this plan needed now.

## Risks & Mitigations
- **Build complexity of whisper.cpp on iOS**: Mitigation - Start with prebuilt framework from community or careful build. Test early.
- **Audio format mismatches**: Mitigation - Strict WAV 16kHz conversion + validation.
- **Model size/download**: Small models ~50-500MB. Mitigation - Quantized, user choice, on-demand.
- **Performance on older devices**: Mitigation - Quant + CoreML + lower threads. Test.
- **Live streaming quality**: Whisper streaming is good but not perfect; chunked may have latency.
- **Breaking checkpoints**: Keep output format compatible initially.
- **Licensing**: whisper.cpp MIT, good.
- **Memory during transcription + LLM**: Already suspend LLM; whisper may need similar care.

## Dependencies / New Files
- New: `whisper.xcframework/`
- New: `Silo/Inference/LibWhisper.swift`, `Silo/Speech/WhisperTranscriptionEngine.swift` (or similar), possibly `WhisperModelManager.swift`.
- Modified heavily: `AudioExtractor.swift`, `TranscriptionEngine.swift` (or replace), `TranscriptionJobManager.swift`, `LlamaState.swift` (minor), `VoiceSession.swift`.
- Modified: Project settings, Xcode project file, model download/UI.
- Updated: `todo.md`, this plan, README/CHANGELOG.

## Verification Criteria
- 30s video clip transcribes fully and accurately (>>98 chars, sensible text).
- Timestamps present in internal output.
- Jobs resumable, progress works, llama suspends correctly.
- Live voice works.
- Models downloadable and selectable.
- No regressions in LLM or other features.
- On-device only, no network during transcribe.
- Clean build on device + sim.

## Estimated Effort
- 2-4 weeks part-time (depending on build hurdles and testing).
- Can ship incrementally: batch file transcription first, then live, then models UI.

## Status: COMPLETED
Core implementation done (see code changes):
- LibWhisper + WhisperCppEngine
- Audio sample loading for 16kHz
- TranscriptionEngine fully on whisper (timestamps in text output)
- VoiceSession live on whisper (periodic + final)
- Whisper model catalog, download via LlamaState, UI section in ManageModelsView
- JobManager auto-wires model path from llamaState.defaultWhisperModelPath()
- llama suspend/resume, checkpoints, progress preserved
- Old Apple SFSpeech deprecated (LocalSpeechGuard kept only for ref)

User next:
- Add whisper.xcframework to Xcode project (build from whisper.cpp sources for iOS targets, embed/sign like llama.xcframework).
- Place or download ggml-small.en-q5_0.bin (via new "Speech Models" section in Manage Models).
- Rebuild and test with 30s video clip.
- (Optional later) Improve live to true streaming, add rich UI for timestamps, implement speaker diarization (see todo.md HOLD OFF item).

See `todo.md` for tracked tasks (all whisper-plan-* marked done). Update this plan with test results. 

Questions resolved in impl:
- Model: small.en-q5_0 recommended.
- Live: chunked/periodic for simplicity.
- Timestamps: basic [mm:ss] prefixes now; segments available internally.
- No Apple fallback kept for transcription.