/** Native Higgsedit authoring. Run with MOKAID_PRODUCTION_ROOT and MOKAID_FORMAT. */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

export default async (api) => {
  const { project, frame, text, rect, media, path } = api;
  const root = resolve(process.env.MOKAID_PRODUCTION_ROOT || './build');
  const format = process.env.MOKAID_FORMAT || 'social-16x9';
  const sizes = { 'social-16x9': [1920, 1080], 'social-4x5': [1080, 1350], 'social-9x16': [1080, 1920], web: [1920, 1080] };
  if (!sizes[format]) throw new Error(`Unknown format ${format}`);
  const [width, height] = sizes[format];
  const input = JSON.parse(readFileSync(join(root, 'export-input.json'), 'utf8'));
  const story = JSON.parse(readFileSync(join(root, input.story), 'utf8'));
  const dir = join(root, 'projects', format);
  mkdirSync(dir, { recursive: true });
  const p = await project({ dir, size: `${width}x${height}`, fps: 24, background: '#090910' });
  const brandFont = input.font ? await p.add(join(root, input.font)) : null;
  const font = (weight = 400) => brandFont ? { fontFamily: 'Manrope', fontWeight: weight, typography: { fontAssetId: brandFont.id, axes: { wght: weight } } } : { fontFamily: 'Inter', fontWeight: weight };
  for (const clip of input.clips) {
    const source = await p.add(join(root, clip.formats[format].path));
    p.cut(source, { from: 0, dur: clip.duration, at: clip.at, fit: 'cover' });
  }
  if (Math.abs(p.duration() - 74) > 1 / 24) throw new Error('Native timeline did not preserve the 74s story.');
  if (format !== 'web') {
    const portrait = width < height;
    const safeX = portrait ? 76 : 112;
    const textWidth = portrait ? width - safeX * 2 : 970;
    const titleSize = portrait ? 65 : 74;
    const secondarySize = portrait ? 31 : 29;
    const defaultTitleY = format === 'social-9x16' ? 1390 : format === 'social-4x5' ? 900 : 735;
    const animate = (duration, keep = false) => [
      { property: 'opacity', keyframes: [
        { at: 0, value: 0 }, { at: Math.min(0.4, duration / 4), value: 1 },
        { at: Math.max(0.5, duration - 0.35), value: 1 }, { at: duration, value: keep ? 1 : 0 },
      ] },
      { property: 'offsetY', from: 20, to: 0, at: 0, duration: Math.min(0.65, duration / 3), easing: 'house' },
    ];
    for (const cue of story.cues) {
      const duration = cue.end - cue.start;
      const final = cue.end === story.duration;
      // Portrait copy stays above faces/action. The shorter4:5 coffee composition
      // requires a compact top title so neither player's face is covered.
      const compactCoffee = format === 'social-4x5' && cue.id === 'coffee';
      const cueTitleSize = compactCoffee ? 48 : titleSize;
      const cueSecondarySize = compactCoffee ? 28 : secondarySize;
      const titleY = final ? defaultTitleY : compactCoffee ? 48 : portrait ? 96 : cue.id === 'closer' ? 145 : defaultTitleY;
      const headlineLines = Math.ceil(cue.text.length / (compactCoffee ? 36 : portrait ? 26 : 27));
      const headlineHeight = Math.min(255, Math.max(compactCoffee ? 60 : 92, headlineLines * cueTitleSize * 1.13));
      const titleNodes = [
        text(cue.text, { x: safeX, y: titleY, width: textWidth, height: headlineHeight, ...font(700), fontSize: cueTitleSize, lineHeight: 1.1, letterSpacing: -1.6, color: '#ffffff' }),
      ];
      if (cue.secondary) titleNodes.push(text(cue.secondary, { x: safeX, y: titleY + headlineHeight + 16, width: textWidth, height: 100, ...font(), fontSize: cueSecondarySize, lineHeight: 1.35, color: '#ddd9e8' }));
      if (final) {
        const ctaText = `${story.cta.text} →`;
        titleNodes.push(text(ctaText, { x: safeX, y: titleY + headlineHeight + (cue.secondary ? 107 : 36), width: textWidth, height: 62, ...font(700), fontSize: portrait ? 38 : 34, color: '#d1bbff' }));
      }
      const topCopy = !final && (portrait || cue.id === 'closer');
      const scrimY = topCopy ? 0 : Math.max(0, titleY - 170);
      const scrimHeight = topCopy ? titleY + headlineHeight + (cue.secondary ? 100 : 0) + 120 : height - scrimY;
      p.compose([
        rect({ x: 0, y: scrimY, width, height: scrimHeight, fill: { kind: 'linear', angle: 180, stops: topCopy ? [{ offset: 0, color: '#090910', opacity: 0.7 }, { offset: 0.65, color: '#090910', opacity: 0.45 }, { offset: 1, color: '#090910', opacity: 0 }] : [{ offset: 0, color: '#090910', opacity: 0 }, { offset: 0.45, color: '#090910', opacity: 0.56 }, { offset: 1, color: '#090910', opacity: 0.84 }] }, animate: [animate(duration, final)[0]] }),
        frame({ width, height, layout: 'none', animate: animate(duration, final) }, titleNodes),
      ], { at: cue.start, dur: duration, name: `Copy · ${cue.id}` });
    }
    for (const [index, notification] of story.notifications.entries()) {
      const notificationTime = notification.time ?? notification.at;
      const duration = story.duration - notificationTime;
      const cardWidth = portrait ? width - safeX * 2 : 530;
      const cardHeight = portrait ? 83 : 68;
      const cardX = portrait ? safeX : width - cardWidth - safeX;
      const cardY = (portrait ? 215 : 115) + index * (cardHeight + 12);
      p.compose(frame({ x: cardX, y: cardY, width: cardWidth, height: cardHeight, layout: 'none',
        motion: { enter: { from: { y: 24, opacity: 0 }, duration: 0.45, easing: 'house' } },
      }, [
        rect({ width: cardWidth, height: cardHeight, radius: 17, fill: '#14131fe8', strokeColor: '#ffffff20', strokeWidth: 1 }),
        rect({ x: 20, y: (cardHeight - 30) / 2, width: 30, height: 30, radius: 15, fill: '#33c58b' }),
        path({ x: 27, y: (cardHeight - 14) / 2, width: 17, height: 14, d: 'M 1 7 L 6 12 L 16 1', stroke: { color: '#ffffff', width: 2.4, cap: 'round' } }),
        text(notification.text, { x: 67, y: portrait ? 25 : 20, width: cardWidth - 85, height: 44, ...font(), fontSize: portrait ? 29 : 24, color: '#f9f8ff' }),
      ]), { at: notificationTime, dur: duration, name: `Completed · ${notification.id}` });
    }
    const titleY = defaultTitleY;
    const logo = await p.add(join(root, input.logo));
    const logoAt = story.logoAt;
    p.compose(frame({ width, height, layout: 'none', animate: animate(74 - logoAt, true) }, [
      media({ file: logo, x: safeX, y: titleY - 137, width: 95, height: 95, fit: 'contain' }),
      text('Mokaid', { x: safeX + 110, y: titleY - 116, width: 410, height: 76, ...font(700), fontSize: 58, letterSpacing: -1.2, color: '#ffffff' }),
    ]), { at: logoAt, dur: 74 - logoAt, name: 'Mokaid · original brand mark' });
  }
  writeFileSync(join(dir, 'authoring-provenance.json'), JSON.stringify({ tool: 'Higgsedit native', fps: 24, duration: 74, format, composition: 'p.cut + p.compose; no DOM or browser capture', clips: input.clips.map(clip => ({ id: clip.id, at: clip.at, duration: clip.duration, ...clip.formats[format] })), warnings: input.warnings }, null, 2));
  if (process.env.MOKAID_RENDER === '1') {
    const report = await p.render('renders/native.mp4', { depth: 8, bitrate: 12_000_000, shards: 8, concurrency: 2 });
    writeFileSync(join(dir, 'render-report.json'), JSON.stringify(report, null, 2));
  }
};
