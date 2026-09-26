#!/usr/bin/env node
/** Prepare full-take, pitch-preserving media for the native Higgsedit projects. */
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

export const FORMATS = {
  'social-16x9': { width: 1920, height: 1080 },
  'social-4x5': { width: 1080, height: 1350 },
  'social-9x16': { width: 1080, height: 1920 },
  web: { width: 1920, height: 1080 },
};
export const DURATIONS = [7, 6, 7, 12, 10, 9, 10, 6, 7];
export function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: 'inherit', ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status})`);
  return result.stdout;
}
export function probe(path) {
  return JSON.parse(run('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', path], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] }));
}
export function tempoFilter(ratio) {
  const parts = [];
  while (ratio > 2) { parts.push('atempo=2'); ratio /= 2; }
  while (ratio < 0.5) { parts.push('atempo=0.5'); ratio /= 0.5; }
  parts.push(`atempo=${ratio.toFixed(10)}`);
  return parts.join(',');
}
function arg(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index < 0 ? fallback : process.argv[index + 1];
}
function absoluteAsset(path, base) { return isAbsolute(path) ? path : resolve(base, path); }
function isPrepared(path, width, height, duration) {
  if (!existsSync(path)) return false;
  try {
    const metadata = probe(path);
    const video = metadata.streams.find(stream => stream.codec_type === 'video');
    const audio = metadata.streams.find(stream => stream.codec_type === 'audio');
    return video?.width === width && video?.height === height && video?.r_frame_rate === '24/1' &&
      Math.abs(Number(video.duration) - duration) < 1 / 24 && audio && Math.abs(Number(audio.duration) - duration) < 0.1;
  } catch { return false; }
}
export function focusExpression(value, pan) {
  if (!pan) return String(value);
  if (!(pan.from >= 0 && pan.from <= 1 && pan.to >= 0 && pan.to <= 1 && pan.start >= 0 && pan.end > pan.start)) throw new Error('Invalid framing pan.');
  const progress = `clip((t-${pan.start})/${pan.end - pan.start},0,1)`;
  return `${pan.from}+${pan.to - pan.from}*(${progress})*(${progress})*(3-2*(${progress}))`;
}
export function normalizeMedia({ source, output, sourceDuration, duration, width, height, focusX, focusY, panX, panY, reverseVideo = false, audioSource = source, audioSourceDuration = sourceDuration, audioGainDb = 0, hasAudio }) {
  const picture = output.replace(/\.mp4$/, '.picture.partial.mp4');
  const sound = output.replace(/\.mp4$/, '.sound.partial.m4a');
  const muxed = output.replace(/\.mp4$/, '.muxed.partial.mp4');
  const videoFilter = `${reverseVideo ? 'reverse,' : ''}setpts=${(duration / sourceDuration).toFixed(10)}*(PTS-STARTPTS),fps=24,scale=${width}:${height}:force_original_aspect_ratio=increase,crop=${width}:${height}:x='(iw-ow)*(${focusExpression(focusX, panX)})':y='(ih-oh)*(${focusExpression(focusY, panY)})',setsar=1,tpad=stop_mode=clone:stop_duration=0.1,trim=duration=${duration}`;
  // The generated H.264 files place audio first. Some ffmpeg 7 schedulers stall
  // when retimed picture and atempo run together; independent passes avoid it.
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-threads', '2', '-filter_threads', '1', '-i', source,
    '-map', '0:v:0', '-an', '-vf', videoFilter, '-c:v', 'libx264', '-threads', '2', '-preset', 'fast', '-crf', '17', '-pix_fmt', 'yuv420p', '-r', '24', '-g', '48', '-t', String(duration), picture]);
  const audioInput = hasAudio ? ['-i', audioSource] : ['-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo'];
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...audioInput, '-vn',
    '-af', `${tempoFilter(audioSourceDuration / duration)},aresample=48000,volume=${audioGainDb}dB,apad,atrim=duration=${duration},afade=t=in:st=0:d=0.055,afade=t=out:st=${duration - 0.055}:d=0.055`,
    '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2', '-t', String(duration), sound]);
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', picture, '-i', sound, '-map', '0:v:0', '-map', '1:a:0', '-c', 'copy', '-t', String(duration), '-movflags', '+faststart', muxed]);
  if (!isPrepared(muxed, width, height, duration)) throw new Error(`Prepared media failed validation: ${output}`);
  renameSync(muxed, output);
  rmSync(picture);
  rmSync(sound);
}
export function validateManifest(manifest, story) {
  if (manifest.clips?.length !== 9) throw new Error('Expected the nine approved source clips.');
  if (story.duration !== 74 || story.fps !== 24) throw new Error('Story must be 74 seconds at 24 fps.');
  manifest.clips.forEach((clip, index) => {
    if (clip.outputDuration !== DURATIONS[index]) throw new Error(`Clip ${index + 1}: expected outputDuration ${DURATIONS[index]}.`);
    if (!clip.localPath && !clip.url) throw new Error(`Clip ${index + 1}: missing source.`);
  });
  for (const cue of story.cues ?? []) {
    if (!(cue.start >= 0 && cue.end > cue.start && cue.end <= 74 && cue.text)) throw new Error(`Invalid cue ${cue.id}.`);
  }
}

export function prepare({ manifestPath, storyPath, root, logoPath, fontPath, framingPath, formats, force = false }) {
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const story = JSON.parse(readFileSync(storyPath, 'utf8'));
  if (framingPath) {
    const review = JSON.parse(readFileSync(framingPath, 'utf8'));
    for (const override of review.overrides ?? []) {
      const clip = manifest.clips.find(candidate => candidate.index === override.index);
      if (!clip) throw new Error(`Framing override references missing clip ${override.index}.`);
      clip.framing = { ...clip.framing, ...override.framing };
      if (override.audioGainDb !== undefined) clip.audioGainDb = override.audioGainDb;
    }
  }
  validateManifest(manifest, story);
  mkdirSync(join(root, 'sources'), { recursive: true });
  mkdirSync(join(root, 'prepared'), { recursive: true });
  copyFileSync(logoPath, join(root, 'mokaid-logo.png'));
  copyFileSync(fontPath, join(root, 'Manrope.ttf'));
  copyFileSync(join(dirname(fontPath), 'OFL-Manrope.txt'), join(root, 'OFL-Manrope.txt'));
  if (framingPath) copyFileSync(framingPath, join(root, 'framing-review.json'));
  writeFileSync(join(root, 'production-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  writeFileSync(join(root, 'cinematic-story.json'), JSON.stringify(story, null, 2) + '\n');
  const input = { version: 1, fps: 24, duration: 74, logo: 'mokaid-logo.png', font: 'Manrope.ttf', story: 'cinematic-story.json', formats, clips: [], warnings: [] };
  let at = 0;
  for (let index = 0; index < manifest.clips.length; index++) {
    const clip = manifest.clips[index];
    const id = `${String(index + 1).padStart(2, '0')}-${clip.id.replace(/[^a-z0-9-]/gi, '-')}`;
    const sources = {};
    const local = clip.localPath && absoluteAsset(clip.localPath, dirname(manifestPath));
    const urlKey = createHash('sha256').update(clip.url ?? clip.localPath ?? id).digest('hex').slice(0, 12);
    const defaultSource = local && existsSync(local) ? local : join(root, 'sources', `${id}-${urlKey}.mp4`);
    if (!existsSync(defaultSource)) {
      if (!clip.url) throw new Error(`Cannot resolve source ${id}.`);
      run('curl', ['--fail', '--location', '--retry', '3', '--output', defaultSource, clip.url]);
    }
    const record = { id: clip.id, index: index + 1, at, duration: clip.outputDuration, jobId: clip.jobId ?? null, sourceUrl: clip.url ?? null, formats: {} };
    for (const format of formats) {
      if (!FORMATS[format]) throw new Error(`Unknown format ${format}`);
      // The web and horizontal film share the exact same prepared pictures.
      const preparationKey = format === 'web' ? 'social-16x9' : format;
      const framing = clip.framing?.[preparationKey] ?? {};
      let source = defaultSource;
      const framingLocal = framing.localPath && absoluteAsset(framing.localPath, dirname(manifestPath));
      if (framingLocal && existsSync(framingLocal)) source = framingLocal;
      else if (framing.sourceUrl) {
        const framingKey = createHash('sha256').update(framing.sourceUrl).digest('hex').slice(0, 12);
        source = join(root, 'sources', `${id}-${preparationKey}-${framingKey}.mp4`);
        if (!existsSync(source)) run('curl', ['--fail', '--location', '--retry', '3', '--output', source, framing.sourceUrl]);
      } else if (framingLocal) throw new Error(`Missing alternate source and URL: ${framingLocal}`);
      if (!sources[source]) sources[source] = { metadata: probe(source), sha256: createHash('sha256').update(readFileSync(source)).digest('hex') };
      const metadata = sources[source].metadata;
      const video = metadata.streams.find(stream => stream.codec_type === 'video');
      const audioSource = framing.useDefaultAudio ? defaultSource : source;
      if (!sources[audioSource]) sources[audioSource] = { metadata: probe(audioSource), sha256: createHash('sha256').update(readFileSync(audioSource)).digest('hex') };
      const audioMetadata = sources[audioSource].metadata;
      const audio = audioMetadata.streams.find(stream => stream.codec_type === 'audio');
      const audioSourceDuration = Number(audioMetadata.streams.find(stream => stream.codec_type === 'video')?.duration ?? audioMetadata.format.duration);
      if (!video) throw new Error(`No video stream in ${id}.`);
      const sourceDuration = Number(video.duration ?? metadata.format.duration);
      if (!Number.isFinite(sourceDuration) || sourceDuration <= 0) throw new Error(`Invalid duration in ${id}.`);
      const duration = clip.outputDuration;
      const { width, height } = FORMATS[format];
      const focusX = framing.focusX ?? 0.5;
      const focusY = framing.focusY ?? 0.5;
      if (!(focusX >= 0 && focusX <= 1 && focusY >= 0 && focusY <= 1)) throw new Error(`Invalid framing for ${id}/${format}.`);
      const relative = `prepared/${id}-${preparationKey}.mp4`;
      const output = join(root, relative);
      const panX = framing.panX;
      const panY = framing.panY;
      focusExpression(focusX, panX);
      focusExpression(focusY, panY);
      if ([panX, panY].some(pan => pan && pan.end > duration)) throw new Error(`Framing pan exceeds clip duration: ${id}/${format}.`);
      const audioGainDb = framing.audioGainDb ?? clip.audioGainDb ?? 0;
      if (!Number.isFinite(audioGainDb) || Math.abs(audioGainDb) > 60) throw new Error(`Invalid audio gain: ${id}/${format}.`);
      const reverseVideo = Boolean(framing.reverseVideo);
      const preparation = { version: 3, sourceSha256: sources[source].sha256, sourceDuration, audioSourceSha256: sources[audioSource].sha256, audioSourceDuration, duration, width, height, focusX, focusY, panX, panY, reverseVideo, audioGainDb, hasAudio: Boolean(audio) };
      const preparationKeyHash = createHash('sha256').update(JSON.stringify(preparation)).digest('hex');
      const cachePath = `${output}.sha256`;
      const samePreparation = existsSync(cachePath) && readFileSync(cachePath, 'utf8').trim() === preparationKeyHash;
      if (force || !samePreparation || !isPrepared(output, width, height, duration)) {
        normalizeMedia({ source, audioSource, output, ...preparation });
        writeFileSync(cachePath, preparationKeyHash + '\n');
      }
      const reviewRequired = format !== 'web' && format !== 'social-16x9' && framing.reviewed !== true;
      const sha256 = createHash('sha256').update(readFileSync(output)).digest('hex');
      record.formats[format] = { path: relative, sha256, sourceJobId: framing.jobId ?? clip.jobId ?? null, sourceUrl: framing.sourceUrl ?? clip.url ?? null, sourceDuration, reverseVideo, useDefaultAudio: Boolean(framing.useDefaultAudio), audioSourceDuration, focusX, focusY, panX, panY, audioGainDb, framingReviewed: !reviewRequired, sourceHadAudio: Boolean(audio) };
      if (reviewRequired) input.warnings.push(`Review crop ${id}/${format}: center is a preview default, not an approved composition.`);
      if (!audio) input.warnings.push(`${id}/${format}: source lacks generated audio; silence was substituted.`);
    }
    input.clips.push(record);
    at += clip.outputDuration;
  }
  writeFileSync(join(root, 'export-input.json'), JSON.stringify(input, null, 2) + '\n');
  console.log(`Prepared ${input.clips.length} clips, ${at}s. ${input.warnings.length} review warnings. Input: ${join(root, 'export-input.json')}`);
  return input;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const here = dirname(fileURLToPath(import.meta.url));
  const repo = resolve(here, '../../..');
  prepare({
    manifestPath: resolve(arg('manifest', join(here, '../production-manifest.json'))),
    storyPath: resolve(arg('story', join(repo, 'apps/web/src/data/cinematic-story.json'))),
    root: resolve(arg('out', join(here, 'build'))),
    logoPath: resolve(arg('logo', join(repo, 'apps/web/public/branding/logo-without-bg.png'))),
    fontPath: resolve(arg('font', join(repo, 'apps/web/public/fonts/Manrope.ttf'))),
    framingPath: arg('framing') ? resolve(arg('framing')) : undefined,
    formats: arg('formats', Object.keys(FORMATS).join(',')).split(','),
    force: process.argv.includes('--force'),
  });
}
