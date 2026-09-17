# Local desktop voice

The desktop package includes **Whisper base q5_1** multilingual recognition and
**Kokoro 82M int8 v1.0** speech synthesis. Native helpers run locally as isolated,
short-lived child processes; users do not install Python, Homebrew, an inference
server, or command-line tools. The current macOS arm64 bundle is approximately
275 MiB, including both models and native engines. No language model is added:
mission reasoning still uses the authenticated Moked orchestration backend.

## Model decision, checked 17 September 2026

- [Whisper GGML model card](https://huggingface.co/ggerganov/whisper.cpp): base
  q5_1 weighs 57 MiB and retains multilingual recognition. It is a useful default
  for short desktop dictation. Small q5_1 is 181 MiB and offers an upgrade path
  when recognition accuracy matters more than package size. Proper nouns and
  noisy or underrepresented languages remain less reliable with base.
- [Kokoro model card](https://huggingface.co/hexgrad/Kokoro-82M): 82M parameters,
  Apache-2.0 weights. The native quantized package avoids a PyTorch runtime.
  [Upstream voices](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md)
  and [sherpa native engine](https://github.com/k2-fsa/sherpa-onnx) determine
  supported speech languages. The integration uses Kokoro for English, French,
  Spanish, Italian, Portuguese, Hindi, and Mandarin; an installed system voice
  is used for other languages, including Hebrew/Japanese when available. There
  is no claim that one small TTS model covers every language.
- [Qwen3-TTS 0.6B](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base) has broader
  controls but adds substantially more parameters and runtime complexity. It
  was not selected for a lightweight, continuously available desktop companion.

## Build and packaging

`MOKAID_BUNDLE_LOCAL_VOICE=ON` is the default. `mokaid_bundle_voice(target)` builds
a native `whisper-cli` from a pinned source archive, downloads the matching
sherpa native runtime and model package, verifies SHA256 before extraction, and
copies the result into `Contents/Resources/voice` on macOS or `voice` next to the
Windows executable. The build cache is `voice-downloads`; only build time needs
network access. `MOKAID_BUNDLE_LOCAL_VOICE=OFF` is for constrained development or
unit-test builds: microphone dictation will explicitly show unavailable.

Required Qt modules: Core, Multimedia, TextToSpeech, Concurrent. macOS requires
`NSMicrophoneUsageDescription`, `com.apple.security.device.audio-input`, the
Darwin multimedia plugin and speechdarwin TTS plugin. The release signing pass
must sign the nested native helpers and their dylibs before signing the outer
app. Runtime integrity verification hashes models/data only, since codesigning
changes executable bytes. The pinned archive checksum verifies native engines
before packaging; the OS verifies signatures after distribution.

Whisper compiles with portable CPU settings, no CUDA/Metal runtime and no newer
Accelerate BLAS API, preserving the app's macOS 13 deployment target. The
prebuilt sherpa macOS arm64 helper advertises a macOS 11 deployment minimum.
Windows x64 and macOS x64 runtime archives are pinned; this change was exercised
on macOS arm64, so release smoke tests on other platforms remain necessary.

The bundle includes model and engine license notices. sherpa's separate helper
includes eSpeak NG phonemization (GPL-3.0); preserve its license and corresponding
source availability when distributing the helper. Engine sources and build
recipe: [sherpa-onnx v1.13.8](https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8),
[eSpeak NG 1.52.0](https://github.com/espeak-ng/espeak-ng/tree/1.52.0), and
[Whisper v1.9.4](https://github.com/ggml-org/whisper.cpp/tree/v1.9.4).

## QObject contract

Include `<mokaid/voice/voice_controller.hpp>` and expose
`mokaid::desktop::VoiceController` to QML. Its properties are `state`, `error`,
`transcript`, `language`, `ready`, `progress` (0–1), `level` (0–1), and
`modelDescription`. Properties share the `changed()` signal.

- `setup()` verifies the shipped runtime outside the UI thread. It runs
  automatically on construction and never opens the microphone.
- `startListening()` requests OS microphone permission only after the user asks
  to speak, stops playback, and captures bounded PCM locally.
- `stopListening()` converts audio in a worker and starts recognition. It emits
  `transcribed(text, language)` with an ISO language code. Send both values to
  the orchestrator so its reply follows the spoken language; do not turn on
  Whisper's translation option.
- `speak(text, language)` reads an explicit response locally. It uses Kokoro for
  its mapped languages and installed system voices otherwise. Missing voices
  produce an actionable error and leave the written response accessible.
- `cancel()` stops microphone, inference and playback, clears pending text and
  temporary audio. Invoke it on sign-out, workspace change and window teardown.

States: `unavailable`, `preparing`, `ready`, `listening`, `transcribing`,
`synthesizing`, `speaking`, `error`. No fake transcript or spoken reply is emitted
on failure. Permission is requested in response to a microphone action, and
there is no background/continuous listening.

Recording is bounded to 90 seconds and 32 MiB. Audio conversion rejects invalid
formats; silent capture is rejected before ASR to reduce silence hallucinations.
Native inference has a 120-second watchdog and cancellation kills its process.
Microphone PCM is in memory; inference WAV/JSON use a private auto-removing
session directory. Audio never leaves the desktop. The *transcript* is sent to
the normal backend only when the UI submits it as a conversation message.
TTS text is passed as a QProcess argument, so it is briefly visible to local
process inspection; it is never sent through a shell or logged by Moked. Helper
stdout/stderr are drained without storing them.

## Verification

`desktop-local-voice-contracts` checks audio conversion, silence/short-input
handling, Unicode and language parsing, missing/tampered assets, traversal
rejection, and visible setup failure without accessing a microphone.
`desktop-voice-provision-contracts` checks pinned hashes, verified download-cache
reuse and safe archive extraction. To exercise the actual bundled models:

```sh
python3 apps/desktop/voice/tests/roundtrip.py apps/desktop/build/macos-debug/voice-runtime
```

The roundtrip synthesizes French with Kokoro and verifies that Whisper detects
French and recognizes key words, without network or microphone. The first
measured sentence produced 5.34 seconds of audio in 3.73 seconds of synthesis;
latency depends on hardware and sentence length. Physical microphone permission,
real acoustic accuracy, output-device playback and Windows/macOS x64 packaging
need device-level smoke testing.
