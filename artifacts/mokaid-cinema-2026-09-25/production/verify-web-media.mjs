#!/usr/bin/env node
// Verify the encoded deliverable, rather than just the encoder command.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
const [file, report] = process.argv.slice(2);
if (!file) throw new Error('Usage: node verify-web-media.mjs film.mp4 [report.json]');
const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-show_frames', '-show_entries', 'frame=key_frame,pict_type,best_effort_timestamp_time,pkt_duration_time', '-of', 'json', file], { encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 }));
const bytes = readFileSync(file);
const atoms = [];
for (let offset = 0; offset + 8 <= bytes.length;) {
  let size = bytes.readUInt32BE(offset);
  const type = bytes.toString('ascii', offset + 4, offset + 8);
  if (size === 1) size = Number(bytes.readBigUInt64BE(offset + 8));
  if (size === 0) size = bytes.length - offset;
  if (size < 8 || offset + size > bytes.length) throw new Error(`Invalid MP4 atom at ${offset}`);
  atoms.push({ type, offset, size });
  offset += size;
}
const video = probe.streams.find(s => s.codec_type === 'video');
const frames = probe.frames.filter(f => f.pict_type);
const keys = frames.flatMap((frame, index) => frame.key_frame ? [index] : []);
const gaps = keys.slice(1).map((key, index) => key - keys[index]);
const deltas = frames.slice(1).map((frame, index) => Number(frame.best_effort_timestamp_time) - Number(frames[index].best_effort_timestamp_time));
const maxGop = Math.max(...gaps, frames.length - keys.at(-1));
const checks = {
  h264: video?.codec_name === 'h264',
  dimensions: video?.width === 1920 && video?.height === 1080,
  duration: Math.abs(Number(video?.duration) - 74) < 1 / 24,
  fps24: video?.r_frame_rate === '24/1' && video?.avg_frame_rate === '24/1',
  constantFrameIntervals: deltas.every(delta => Math.abs(delta - 1 / 24) < 0.00001),
  noBFrames: video?.has_b_frames === 0 && frames.every(frame => frame.pict_type !== 'B'),
  quarterSecondGop: keys[0] === 0 && maxGop <= 6,
  silent: !probe.streams.some(s => s.codec_type === 'audio'),
  faststart: atoms.find(a => a.type === 'moov')?.offset < atoms.find(a => a.type === 'mdat')?.offset,
};
const result = { file, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'), frameCount: frames.length, maxGop, checks, passed: Object.values(checks).every(Boolean) };
if (report) writeFileSync(report, JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result, null, 2));
if (!result.passed) process.exitCode = 1;
