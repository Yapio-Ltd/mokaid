#!/usr/bin/env node
/** Read-only audio QA. No gain, fades, resampling, remixing, ASR or network calls. */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const thresholds = { quietIntegratedLUFS: -45, undetectableSamplePeakDBFS: -90, joinWarningDB: 6, joinExtremeDB: 12, truePeakWarningDBTP: -1 };
function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return fallback;
  if (!process.argv[i + 1] || process.argv[i + 1].startsWith('--')) throw new Error(`Missing --${name} value.`);
  return process.argv[i + 1];
}
function run(command, args, binary = false) {
  const result = spawnSync(command, args, { encoding: binary ? undefined : 'utf8', maxBuffer: 128 * 1024 * 1024, timeout: 120_000 });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status}): ${String(result.stderr).slice(-3000)}`);
  return result;
}
function round(value, digits = 3) { return Number.isFinite(value) ? Number(value.toFixed(digits)) : null; }
function db(amplitude) { return amplitude > 0 ? round(20 * Math.log10(amplitude)) : null; }
function summaryNumber(text, expression) {
  const match = text.match(expression);
  if (!match) throw new Error(`Missing ebur128 measurement: ${expression}`);
  return round(Number(match[1]));
}
function measurePCM(buffer, channels, sampleRate, edgeSeconds, binSeconds) {
  const frameCount = Math.floor(buffer.length / (4 * channels));
  if (!frameCount) throw new Error('Audio stream decoded to no PCM samples.');
  function segment(start, end) {
    const count = end - start;
    let energy = 0;
    let peak = 0;
    let samplesAtOrAboveFullScale = 0;
    const channelEnergy = Array(channels).fill(0);
    const channelPeak = Array(channels).fill(0);
    for (let frame = start; frame < end; frame++) {
      for (let channel = 0; channel < channels; channel++) {
        const value = buffer.readFloatLE((frame * channels + channel) * 4);
        if (!Number.isFinite(value)) throw new Error('Non-finite sample in decoded PCM.');
        const magnitude = Math.abs(value);
        energy += value * value;
        channelEnergy[channel] += value * value;
        peak = Math.max(peak, magnitude);
        channelPeak[channel] = Math.max(channelPeak[channel], magnitude);
        if (magnitude >= 1) samplesAtOrAboveFullScale++;
      }
    }
    return {
      startSeconds: round(start / sampleRate), endSeconds: round(end / sampleRate),
      rmsDBFS: db(Math.sqrt(energy / (count * channels))), samplePeakDBFS: db(peak),
      perChannelRmsDBFS: channelEnergy.map(value => db(Math.sqrt(value / count))),
      perChannelSamplePeakDBFS: channelPeak.map(db), samplesAtOrAboveFullScale,
    };
  }
  const edgeFrames = Math.min(frameCount, Math.round(edgeSeconds * sampleRate));
  const binFrames = Math.max(1, Math.round(binSeconds * sampleRate));
  function envelope(from, to) {
    const bins = [];
    for (let start = from; start < to; start += binFrames) bins.push(segment(start, Math.min(start + binFrames, to)));
    return bins;
  }
  return {
    decodedDurationSeconds: round(frameCount / sampleRate), decodedFrames: frameCount,
    whole: segment(0, frameCount),
    start: { aggregate: segment(0, edgeFrames), bins: envelope(0, edgeFrames) },
    end: { aggregate: segment(frameCount - edgeFrames, frameCount), bins: envelope(frameCount - edgeFrames, frameCount) },
  };
}

export function analyzeAudio({ manifestPath, outputPath, edgeSeconds = 1, binSeconds = 0.1 }) {
  if (!(edgeSeconds > 0 && binSeconds > 0 && binSeconds <= edgeSeconds)) throw new Error('Require 0 < bin-seconds <= edge-seconds.');
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  if (!Array.isArray(manifest.clips)) throw new Error('Manifest must have a clips array.');
  const ffmpegVersion = run('ffmpeg', ['-version']).stdout.split('\n')[0];
  const report = {
    version: 1, createdAt: new Date().toISOString(), manifestPath, ffmpegVersion,
    method: {
      loudness: 'ffmpeg -map 0:a:0 -vn -sn -dn -af ebur128=peak=true -f null -; full original take, no gain/filter before measurement',
      envelope: 'Original decoded sample rate/channels, pcm_f32le; RMS combines channel energy and also records each channel. No normalization, fades, resampling or remixing.',
      edgeSeconds, binSeconds, thresholds,
      negativeInfinity: 'null for logarithmic quantities denotes digital silence/non-finite dB, not zero dB.',
      limitations: [
        'Objective signal measurements only; no listening or semantic sound verification was performed.',
        'Short takes provide limited LRA statistics; no assertion of programme compliance.',
        'Join alerts compare original source envelopes. Intentional dynamics and existing edge fades can explain differences. Final retimed montage must be measured separately.',
        'True peak is reported as dBTP although ffmpeg labels its summary dBFS. Only the first audio stream is measured.',
      ],
    },
    clips: [], joins: [], alerts: [],
  };
  for (const [position, clip] of manifest.clips.entries()) {
    const path = clip.localPath ? (isAbsolute(clip.localPath) ? clip.localPath : resolve(dirname(manifestPath), clip.localPath)) : null;
    const entry = { index: clip.index ?? position + 1, id: clip.id, sourcePath: path, manifestStatus: clip.status, outputDuration: clip.outputDuration };
    report.clips.push(entry);
    if (!path || !existsSync(path)) { entry.status = 'unavailable'; continue; }
    try {
      const before = statSync(path);
      const metadata = JSON.parse(run('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', path]).stdout);
      const streams = metadata.streams.filter(stream => stream.codec_type === 'audio');
      if (!streams.length) {
        entry.status = 'no-audio-stream';
        report.alerts.push({ severity: 'error', clip: entry.index, code: 'missing-audio-stream' });
        continue;
      }
      const audio = streams[0];
      entry.audio = { streamCount: streams.length, measuredStreamIndex: audio.index, codec: audio.codec_name, channels: audio.channels, sampleRate: Number(audio.sample_rate), durationSeconds: Number(audio.duration ?? metadata.format.duration) };
      const result = run('ffmpeg', ['-hide_banner', '-nostats', '-nostdin', '-i', path, '-map', '0:a:0', '-vn', '-sn', '-dn', '-af', 'ebur128=peak=true', '-f', 'null', '-']);
      const summary = result.stderr.slice(result.stderr.lastIndexOf('Summary:'));
      entry.loudness = {
        integratedLUFS: summaryNumber(summary, /Integrated loudness:\s*I:\s*([-+\d.]+|[-+]?inf)\s+LUFS/),
        rangeLU: summaryNumber(summary, /Loudness range:\s*LRA:\s*([-+\d.]+|[-+]?inf)\s+LU/),
        truePeakDBTP: summaryNumber(summary, /True peak:\s*Peak:\s*([-+\d.]+|[-+]?inf)\s+dBFS/),
      };
      const pcm = run('ffmpeg', ['-v', 'error', '-nostdin', '-i', path, '-map', '0:a:0', '-vn', '-sn', '-dn', '-c:a', 'pcm_f32le', '-f', 'f32le', 'pipe:1'], true).stdout;
      entry.envelope = measurePCM(pcm, audio.channels, Number(audio.sample_rate), edgeSeconds, binSeconds);
      const after = statSync(path);
      if (before.size !== after.size || before.mtimeMs !== after.mtimeMs) throw new Error('Source changed while being measured; rerun after generation finishes.');
      entry.sourceSizeBytes = after.size;
      entry.sourceMtime = after.mtime.toISOString();
      entry.status = 'measured';
      const peak = entry.envelope.whole.samplePeakDBFS;
      const hasSignal = peak !== null && peak > thresholds.undetectableSamplePeakDBFS;
      entry.signalDetected = hasSignal;
      if (!hasSignal) report.alerts.push({ severity: 'error', clip: entry.index, code: 'no-detectable-programme-signal', samplePeakDBFS: peak });
      else if (entry.loudness.integratedLUFS <= thresholds.quietIntegratedLUFS) report.alerts.push({ severity: 'warning', clip: entry.index, code: 'very-quiet-source', integratedLUFS: entry.loudness.integratedLUFS });
      if (entry.envelope.whole.samplesAtOrAboveFullScale > 0 || (entry.loudness.truePeakDBTP !== null && entry.loudness.truePeakDBTP >= 0)) report.alerts.push({ severity: 'error', clip: entry.index, code: 'full-scale-or-intersample-overload', truePeakDBTP: entry.loudness.truePeakDBTP, samplesAtOrAboveFullScale: entry.envelope.whole.samplesAtOrAboveFullScale });
      else if (entry.loudness.truePeakDBTP !== null && entry.loudness.truePeakDBTP > thresholds.truePeakWarningDBTP) report.alerts.push({ severity: 'warning', clip: entry.index, code: 'low-true-peak-headroom', truePeakDBTP: entry.loudness.truePeakDBTP });
    } catch (error) {
      entry.status = 'measurement-error';
      entry.error = error.message;
      report.alerts.push({ severity: 'error', clip: entry.index, code: 'measurement-error', detail: error.message });
    }
  }
  for (let i = 1; i < report.clips.length; i++) {
    const previous = report.clips[i - 1];
    const next = report.clips[i];
    if (previous.status !== 'measured' || next.status !== 'measured') continue;
    const before = previous.envelope.end.aggregate.rmsDBFS;
    const after = next.envelope.start.aggregate.rmsDBFS;
    const join = {
      from: previous.index, to: next.index,
      tailRmsDBFS: before, headRmsDBFS: after,
      edgeRmsDeltaDB: before !== null && after !== null ? round(after - before) : null,
      integratedDeltaLU: previous.loudness.integratedLUFS !== null && next.loudness.integratedLUFS !== null ? round(next.loudness.integratedLUFS - previous.loudness.integratedLUFS) : null,
      interpretation: 'Positive difference means the incoming source is louder. This is a review candidate, not proof of an audible fault.',
    };
    report.joins.push(join);
    for (const [metric, value] of [['edgeRmsDeltaDB', join.edgeRmsDeltaDB], ['integratedDeltaLU', join.integratedDeltaLU]]) {
      if (value !== null && Math.abs(value) >= thresholds.joinWarningDB) report.alerts.push({
        severity: Math.abs(value) >= thresholds.joinExtremeDB ? 'high' : 'warning',
        code: 'source-level-discontinuity', from: previous.index, to: next.index, metric, delta: value,
      });
    }
  }
  report.summary = {
    measuredClips: report.clips.filter(clip => clip.status === 'measured').length,
    unavailableClips: report.clips.filter(clip => clip.status === 'unavailable').map(clip => clip.index),
    errorClips: report.clips.filter(clip => ['measurement-error', 'no-audio-stream'].includes(clip.status)).map(clip => clip.index),
    sourcesWithDetectedSignal: report.clips.filter(clip => clip.signalDetected).length,
    overloadAlertCount: report.alerts.filter(alert => alert.code === 'full-scale-or-intersample-overload').length,
    alertCount: report.alerts.length,
  };
  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ report: outputPath, summary: report.summary, levels: report.clips.map(({ index, id, status, loudness }) => ({ index, id, status, ...loudness })), alerts: report.alerts }, null, 2));
  return report;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  analyzeAudio({
    manifestPath: resolve(arg('manifest', join(here, '../production-manifest.json'))),
    outputPath: resolve(arg('out', join(here, 'review/audio-review.json'))),
    edgeSeconds: Number(arg('edge-seconds', 1)), binSeconds: Number(arg('bin-seconds', 0.1)),
  });
}
