#!/usr/bin/env python3
"""Optional, offline ASR review of original takes. Never asserts a human listen."""

import argparse
from collections import Counter
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
from datetime import datetime, timezone


SCENES = ["cafe", "approach", "portal", "office", "collaboration", "life", "execution", "return", "completed"]
VAD = {"threshold": 0.6, "min_speech_duration_ms": 250, "min_silence_duration_ms": 300, "speech_pad_ms": 150}
LIMITS = {"avg_logprob_min": -0.6, "no_speech_prob_max": 0.35, "compression_ratio_max": 2.4, "language_probability_min": 0.7, "word_probability_min": 0.65, "min_words": 2}


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=120, check=False)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stderr[-2500:]}")
    return result


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for data in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def finite(value):
    value = float(value)
    return round(value, 6) if math.isfinite(value) else None


def levels(source):
    # Measure the same mono/16 kHz decoding used for ASR, before adding gain.
    result = run(["ffmpeg", "-hide_banner", "-nostats", "-nostdin", "-i", str(source), "-map", "0:a:0", "-vn", "-sn", "-dn", "-af", "aformat=sample_rates=16000:channel_layouts=mono,volumedetect", "-f", "null", "-"])
    measured = {}
    for name in ("mean_volume", "max_volume"):
        matches = re.findall(rf"{name}:\s*([-+\d.]+|[-+]?inf)\s*dB", result.stderr)
        if not matches:
            raise RuntimeError(f"ffmpeg did not report {name}")
        measured[name] = finite(matches[-1])
    return measured


def technical_gain(measured):
    mean, peak = measured["mean_volume"], measured["max_volume"]
    if mean is None or peak is None or mean >= -35:
        return 0.0
    # Fixed gain preserves the source envelope; no compression/limiter/loudnorm.
    # Only a disposable analysis copy is affected, never the source/montage.
    return round(max(0.0, min(18.0, -25.0 - mean, -3.0 - peak)), 2)


def assess_segment(segment, language_probability):
    words = [{"start": finite(word.start), "end": finite(word.end), "word": word.word, "probability": finite(word.probability)} for word in (segment.words or [])]
    word_count = len(re.findall(r"\b[^\W_]+(?:['’][^\W_]+)*\b", segment.text, flags=re.UNICODE))
    probabilities = [word["probability"] for word in words if word["probability"] is not None]
    mean_probability = sum(probabilities) / len(probabilities) if probabilities else None
    result = {
        "start": finite(segment.start), "end": finite(segment.end), "text": segment.text.strip(),
        "avg_logprob": finite(segment.avg_logprob), "no_speech_prob": finite(segment.no_speech_prob),
        "compression_ratio": finite(segment.compression_ratio), "temperature": finite(segment.temperature),
        "word_count": word_count, "mean_word_probability": finite(mean_probability) if mean_probability is not None else None,
        "words": words, "review_reasons": [],
    }
    tests = [
        (result["avg_logprob"] is not None and result["avg_logprob"] >= LIMITS["avg_logprob_min"], "low_average_log_probability"),
        (result["no_speech_prob"] is not None and result["no_speech_prob"] <= LIMITS["no_speech_prob_max"], "high_no_speech_probability"),
        (result["compression_ratio"] is not None and result["compression_ratio"] <= LIMITS["compression_ratio_max"], "repetitive_or_compressed_text"),
        (language_probability is not None and language_probability >= LIMITS["language_probability_min"], "uncertain_language"),
        (word_count >= LIMITS["min_words"], "too_few_words_for_reliable_intelligibility"),
        (mean_probability is not None and mean_probability >= LIMITS["word_probability_min"], "low_word_confidence"),
    ]
    result["review_reasons"] = [reason for passes, reason in tests if not passes]
    result["classification"] = "speech_candidate_requires_review" if not result["review_reasons"] else "uncertain_possible_hallucination"
    return result


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=here.parent / "production-manifest.json")
    parser.add_argument("--out", type=Path, default=here / "review" / "speech-review.json")
    parser.add_argument("--model-dir", type=Path, required=True, help="Existing local faster-whisper/CTranslate2 model directory; downloads prohibited.")
    parser.add_argument("--device", choices=["cpu", "cuda"], default="cpu")
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--cpu-threads", type=int, default=2)
    parser.add_argument("--keep-analysis", action="store_true", help="Keep technically level-adjusted mono WAVs beside the report for optional manual review.")
    args = parser.parse_args()
    args.manifest, args.out, args.model_dir = args.manifest.resolve(), args.out.resolve(), args.model_dir.resolve()
    required_model_files = ["model.bin", "config.json", "tokenizer.json"]
    if not args.model_dir.is_dir() or any(not (args.model_dir / name).is_file() for name in required_model_files):
        parser.error("--model-dir must contain existing model.bin, config.json and tokenizer.json. No model will be downloaded.")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    # Import lazily: --help and syntax checks cannot initialize/download a model.
    from faster_whisper import WhisperModel

    manifest = json.loads(args.manifest.read_text())
    supplied = {int(clip.get("index", i + 1)): clip for i, clip in enumerate(manifest.get("clips", []))}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "version": 1, "createdAt": datetime.now(timezone.utc).isoformat(), "manifest": str(args.manifest),
        "label": "AUTOMATIC TRANSCRIPTION REVIEW — NOT A HUMAN LISTEN",
        "method": {
            "model_dir": str(args.model_dir), "local_files_only": True, "device": args.device, "compute_type": args.compute_type,
            "faster_whisper_version": importlib.metadata.version("faster-whisper"), "python_version": platform.python_version(),
            "ffmpeg_version": run(["ffmpeg", "-version"]).stdout.splitlines()[0],
            "model_config_sha256": sha256(args.model_dir / "config.json") if (args.model_dir / "config.json").exists() else None,
            "model_sha256": sha256(args.model_dir / "model.bin"),
            "tokenizer_sha256": sha256(args.model_dir / "tokenizer.json"),
            "model_bytes": (args.model_dir / "model.bin").stat().st_size,
            "vad": VAD, "confidence_thresholds": LIMITS, "language": "automatic; no forced language or contextual prompt",
            "decoding": {"beam_size": 5, "temperature": 0, "condition_on_previous_text": False, "word_timestamps": True},
            "analysis_copy": "16 kHz mono PCM WAV; fixed gain only when mean below -35 dBFS, target -25 dBFS, maximum +18 dB and -3 dBFS peak ceiling. Source files untouched.",
            "limitations": [
                "Speech candidates require manual listening; automated scores do not prove intelligibility, voice-over or dialogue.",
                "Room tone, music and amplified noise can produce hallucinated words; uncertain segments are retained, never presented as verified speech.",
                "VAD and confidence filters can miss quiet/short speech. No detected speech is not a guarantee of absence.",
                "Short source clips can yield uncertain language probability; report such results as inconclusive.",
            ],
        }, "clips": [],
    }
    model = WhisperModel(str(args.model_dir), device=args.device, compute_type=args.compute_type, cpu_threads=args.cpu_threads, num_workers=1, local_files_only=True)

    def save():
        args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    with tempfile.TemporaryDirectory(prefix="mokaid-speech-") as temporary:
        analysis_dir = args.out.parent / "speech-analysis" if args.keep_analysis else Path(temporary)
        analysis_dir.mkdir(parents=True, exist_ok=True)
        for index, scene in enumerate(SCENES, 1):
            clip = supplied.get(index, {})
            local = clip.get("localPath")
            source = (args.manifest.parent / local).resolve() if local else None
            entry = {"index": index, "id": clip.get("id", scene), "source": str(source) if source else None, "segments": []}
            report["clips"].append(entry)
            if not source or not source.is_file():
                entry["verdict"] = "unavailable_local_source"
                save()
                continue
            try:
                original_stat = source.stat()
                metadata = json.loads(run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(source)]).stdout)
                if not any(stream.get("codec_type") == "audio" for stream in metadata.get("streams", [])):
                    entry["verdict"] = "no_audio_stream"
                    save()
                    continue
                entry["source_sha256"] = sha256(source)
                entry["analysis_levels_before_gain_dbfs"] = levels(source)
                gain = technical_gain(entry["analysis_levels_before_gain_dbfs"])
                entry["analysis_gain_db"] = gain
                wav = analysis_dir / f"{index:02d}.wav"
                run(["ffmpeg", "-v", "error", "-nostdin", "-y", "-i", str(source), "-map", "0:a:0", "-vn", "-sn", "-dn", "-af", f"aformat=sample_rates=16000:channel_layouts=mono,volume={gain}dB", "-c:a", "pcm_s16le", str(wav)])
                entry["analysis_wav_sha256"] = sha256(wav)
                if args.keep_analysis:
                    entry["analysis_wav"] = str(wav)
                segments, info = model.transcribe(
                    str(wav), task="transcribe", language=None, beam_size=5, temperature=0,
                    condition_on_previous_text=False, initial_prompt=None, word_timestamps=True,
                    vad_filter=True, vad_parameters=VAD, no_speech_threshold=0.6,
                    compression_ratio_threshold=2.4, log_prob_threshold=-1.0,
                    hallucination_silence_threshold=1.0,
                )
                entry["language"] = info.language
                entry["language_probability"] = finite(info.language_probability)
                entry["duration_seconds"] = finite(info.duration)
                entry["duration_after_vad_seconds"] = finite(info.duration_after_vad)
                entry["segments"] = [assess_segment(segment, entry["language_probability"]) for segment in segments]
                if any(segment["classification"] == "speech_candidate_requires_review" for segment in entry["segments"]):
                    entry["verdict"] = "speech_candidate_requires_review"
                elif entry["segments"]:
                    entry["verdict"] = "inconclusive_low_confidence"
                else:
                    mean = entry["analysis_levels_before_gain_dbfs"]["mean_volume"]
                    if mean is None or mean + gain < -40:
                        entry["verdict"] = "inconclusive_low_signal"
                    elif entry["duration_after_vad_seconds"] and (entry["language_probability"] is None or entry["language_probability"] < LIMITS["language_probability_min"]):
                        entry["verdict"] = "inconclusive_uncertain_language"
                    else:
                        entry["verdict"] = "no_speech_detected_automatically"
                if source.stat().st_mtime_ns != original_stat.st_mtime_ns or source.stat().st_size != original_stat.st_size:
                    raise RuntimeError("Source changed while being analyzed; rerun after generation completes.")
                if not args.keep_analysis:
                    wav.unlink(missing_ok=True)
            except Exception as error:
                entry["verdict"] = "inconclusive_analysis_error"
                entry["error"] = str(error)
            save()
    # Identical phrases in several unrelated takes merit skepticism, not deletion.
    phrase_clips = {}
    for clip in report["clips"]:
        for segment in clip["segments"]:
            phrase = re.sub(r"[^\w]+", " ", segment["text"].lower()).strip()
            if phrase:
                phrase_clips.setdefault(phrase, set()).add(clip["index"])
    for clip in report["clips"]:
        for segment in clip["segments"]:
            phrase = re.sub(r"[^\w]+", " ", segment["text"].lower()).strip()
            if len(phrase_clips.get(phrase, set())) >= 3:
                segment["review_reasons"].append("identical_phrase_across_three_or_more_takes")
                segment["classification"] = "uncertain_possible_hallucination"
        if clip["verdict"] != "inconclusive_analysis_error" and clip["segments"] and not any(segment["classification"] == "speech_candidate_requires_review" for segment in clip["segments"]):
            clip["verdict"] = "inconclusive_low_confidence"
    report["summary"] = dict(Counter(clip["verdict"] for clip in report["clips"]))
    save()
    print(json.dumps({"label": report["label"], "report": str(args.out), "summary": report["summary"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
