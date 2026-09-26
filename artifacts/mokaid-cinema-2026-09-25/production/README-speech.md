# Optional offline speech check

`check-speech.py` checks the nine original takes listed in `../production-manifest.json` for unexpected intelligible-speech **candidates**. Its output is automatic transcription, never a claim of listening or proof of dialogue. The script has not been run with a model.

Requires Python 3, ffmpeg/ffprobe, `faster-whisper`, and an **already installed** CTranslate2 Whisper model directory containing `model.bin`, `config.json` and `tokenizer.json`. No model download, API request or paid generation is performed; offline mode is enforced and `local_files_only=True` is set. Missing local takes are reported and never fetched. Use a multilingual model; the script does not force English or supply story text as a prompt.

```sh
python3 check-speech.py --help
python3 check-speech.py --model-dir /absolute/path/to/existing-whisper-model
```

Optional arguments: `--manifest PATH`, `--out PATH`, `--device cpu|cuda`, `--compute-type int8`, `--cpu-threads 2`, and `--keep-analysis`. Defaults write `review/speech-review.json`; CPU/int8 avoids depending on a GPU. In the Higgsfield sandbox, copy the production manifest, its locally referenced clips, and this script before running. Pass an existing sandbox model path; never assume the desktop path exists there.

The script extracts temporary mono/16 kHz PCM analysis WAVs. If their mean level is below −35 dBFS, a fixed gain targets −25 dBFS, capped at +18 dB and a −3 dBFS peak ceiling. This is an analysis-only level adjustment: original files, their envelopes and the film mix are untouched. `--keep-analysis` preserves copies for optional review; otherwise they are removed.

VAD suppresses likely non-speech. Each emitted segment retains its timestamps, text, `avg_logprob`, `no_speech_prob`, compression ratio and word probabilities. Low-confidence, very short, uncertain-language and repeatedly hallucinated-looking phrases remain in the JSON and produce an **inconclusive** verdict. Stronger candidates still require listening by a reviewer. `no_speech_detected_automatically` cannot guarantee absence of quiet/short speech. Read the report's model/version, gain, threshold and source-hash records when reproducing a result.
