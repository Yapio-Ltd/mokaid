#!/usr/bin/env node
/** Build/render native projects, encode deliveries, verify them, and package edits. */
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { FORMATS, probe, run } from './prepare-media.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(process.env.MOKAID_PRODUCTION_ROOT || join(here, 'build'));
const input = JSON.parse(readFileSync(join(root, 'export-input.json'), 'utf8'));
const formats = (process.env.MOKAID_FORMATS || input.formats.join(',')).split(',');
const outputDir = resolve(process.env.MOKAID_EXPORT_DIR || join(root, 'deliveries'));
const render = !process.argv.includes('--build-only');
mkdirSync(outputDir, { recursive: true });
const deliveryPath = join(outputDir, 'delivery-manifest.json');
const previousDelivery = existsSync(deliveryPath) ? JSON.parse(readFileSync(deliveryPath, 'utf8')) : null;
const retainedFiles = previousDelivery?.duration === 74 && previousDelivery?.fps === 24
  ? previousDelivery.files.filter(file => !formats.includes(file.format)) : [];
const delivery = { version: 1, duration: 74, fps: 24, tool: 'Higgsedit native', createdAt: new Date().toISOString(), warnings: input.warnings, files: retainedFiles };
for (const format of formats) {
  if (!FORMATS[format]) throw new Error(`Unknown format ${format}.`);
  const dir = join(root, 'projects', format);
  run('higgsedit', ['build', join(here, 'build-film.mjs')], { env: { ...process.env, MOKAID_PRODUCTION_ROOT: root, MOKAID_FORMAT: format, MOKAID_RENDER: '0' } });
  run('higgsedit', ['check', dir]);
  if (!render) continue;
  const renderPath = join(dir, 'renders/native.mp4');
  const buildKey = createHash('sha256').update(readFileSync(join(here, 'build-film.mjs'))).update(readFileSync(join(root, 'export-input.json'))).update(readFileSync(join(root, input.story))).digest('hex');
  const buildKeyPath = join(dir, 'render-input.sha256');
  const sameBuild = existsSync(buildKeyPath) && readFileSync(buildKeyPath, 'utf8').trim() === buildKey;
  if (!existsSync(renderPath) || !sameBuild || process.argv.includes('--force')) {
    run('higgsedit', ['render', dir, '--out', 'renders/native.mp4', '--depth', '8', '--bitrate', '12M', '--shards', '8', '--concurrency', '2']);
    writeFileSync(buildKeyPath, buildKey + '\n');
  }
  const output = join(outputDir, `mokaid-${format}-74s.mp4`);
  const args = ['-hide_banner', '-loglevel', 'error', '-y', '-i', renderPath, '-map', '0:v:0'];
  if (format === 'web') {
    // Quarter-second maximum seek distance, no B-frame reordering, index before media.
    args.push('-an', '-c:v', 'libx264', '-preset', 'slow', '-crf', '21', '-maxrate', '8M', '-bufsize', '16M', '-g', '6', '-keyint_min', '6', '-sc_threshold', '0', '-bf', '0', '-r', '24', '-pix_fmt', 'yuv420p');
  } else {
    const native = probe(renderPath);
    if (!native.streams.some(stream => stream.codec_type === 'audio')) throw new Error(`${format}: native film lost the generated audio.`);
    args.push('-map', '0:a:0', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-af', 'loudnorm=I=-20:LRA=9:TP=-1.5', '-ar', '48000');
  }
  args.push('-t', '74', '-movflags', '+faststart', '-metadata', 'title=Mokaid — Enter your AI office', '-metadata', 'comment=Higgsfield Cinema Studio Video v2; native Higgsedit composition', output);
  run('ffmpeg', args);
  const metadata = probe(output);
  const video = metadata.streams.find(stream => stream.codec_type === 'video');
  const audio = metadata.streams.find(stream => stream.codec_type === 'audio');
  const expected = FORMATS[format];
  if (video.width !== expected.width || video.height !== expected.height || video.r_frame_rate !== '24/1' || Math.abs(Number(video.duration) - 74) > 1 / 24) throw new Error(`Delivery validation failed: ${format}.`);
  if (format === 'web' && (audio || video.has_b_frames !== 0)) throw new Error('Web delivery must be silent with no B-frames.');
  let maximumKeyframeGap = null;
  if (format === 'web') {
    const keyframes = JSON.parse(run('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-skip_frame', 'nokey', '-show_frames', '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', output], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] })).frames.map(frame => Number(frame.best_effort_timestamp_time));
    maximumKeyframeGap = Math.max(...keyframes.slice(1).map((time, index) => time - keyframes[index]));
    if (!keyframes.length || maximumKeyframeGap > 0.251) throw new Error('Web keyframe spacing exceeds the 250ms seeking budget.');
  }
  const digest = createHash('sha256').update(readFileSync(output)).digest('hex');
  delivery.files.push({ format, filename: output.split('/').at(-1), sha256: digest, width: video.width, height: video.height, duration: Number(video.duration), fps: video.r_frame_rate, audio: Boolean(audio), maximumKeyframeGap, bytes: Number(metadata.format.size) });
  if (format === 'web') copyFileSync(output, join(outputDir, `mokaid-office-journey.${digest.slice(0, 12)}.mp4`));
}
writeFileSync(deliveryPath, JSON.stringify(delivery, null, 2) + '\n');
if (render && !process.argv.includes('--skip-archive')) {
  // Relative sources and vendored project media keep this archive editable elsewhere.
  const authoring = join(root, 'authoring');
  mkdirSync(authoring, { recursive: true });
  for (const name of ['prepare-media.mjs', 'build-film.mjs', 'export-films.mjs', 'analyze-audio.mjs', 'verify-web-media.mjs', 'check-speech.py', 'README-speech.md', 'README.md']) {
    if (existsSync(join(here, name))) copyFileSync(join(here, name), join(authoring, name));
  }
  const optional = ['framing-review.json', 'credits-ledger.json', 'portrait-manifest.json', 'portrait-office-manifest.json'].filter(name => existsSync(join(root, name)));
  run('zip', ['-q', '-r', join(outputDir, 'mokaid-higgsedit-editable.zip'), 'projects', 'prepared', 'authoring', 'production-manifest.json', 'cinematic-story.json', 'export-input.json', 'mokaid-logo.png', 'Manrope.ttf', 'OFL-Manrope.txt', ...optional, '-x', '*/renders/*', '*/.cache/*', '*/.render-cache/*'], { cwd: root });
}
console.log(JSON.stringify({ outputDir, rendered: render, files: delivery.files.map(file => file.filename), warnings: delivery.warnings }, null, 2));
