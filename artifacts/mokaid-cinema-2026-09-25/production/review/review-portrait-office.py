from pathlib import Path
import subprocess
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
VIDEO = ROOT / 'clips/04-office-portrait.mp4'
REVIEW = ROOT / 'production/review'
FRAMES = REVIEW / 'portrait-office-frames'
FRAMES.mkdir(exist_ok=True)

probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(VIDEO)]))
video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
fps_num, fps_den = map(int, video['r_frame_rate'].split('/'))
fps = fps_num / fps_den
last_frame = int(video['nb_frames']) - 1
samples = sorted(set([round(t * fps) for t in range(12)] + [last_frame]))
tile_w, tile_h, label_h = 216, 384, 28
cols = 7
rows = (len(samples) + cols - 1) // cols
sheet = Image.new('RGB', (cols * tile_w, rows * (tile_h + label_h)), '#111111')
draw = ImageDraw.Draw(sheet)
for i, frame in enumerate(samples):
    dest = FRAMES / f'frame-{frame:04d}.png'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(VIDEO), '-vf', f'select=eq(n\\,{frame})', '-frames:v', '1', str(dest)], check=True)
    image = Image.open(dest).convert('RGB').resize((tile_w, tile_h), Image.Resampling.LANCZOS)
    x, y = (i % cols) * tile_w, (i // cols) * (tile_h + label_h)
    sheet.paste(image, (x, y))
    draw.text((x + 8, y + tile_h + 6), f'{frame / fps:.2f} s / f{frame}', fill='white')
sheet.save(REVIEW / 'portrait-office-contact.jpg', quality=94)

pairs = [
    ('Start reference', ROOT / 'references/office-04-portrait-start.png'),
    ('Generated first', FRAMES / 'frame-0000.png'),
    ('Generated last', FRAMES / f'frame-{last_frame:04d}.png'),
    ('End reference', ROOT / 'references/office-04-portrait-end.png'),
]
joins = Image.new('RGB', (4 * 270, 508), '#111111')
join_draw = ImageDraw.Draw(joins)
for i, (label, path) in enumerate(pairs):
    joins.paste(Image.open(path).convert('RGB').resize((270, 480), Image.Resampling.LANCZOS), (i * 270, 0))
    join_draw.text((i * 270 + 6, 486), label, fill='white')
joins.save(REVIEW / 'portrait-office-endpoints.jpg', quality=95)
(REVIEW / 'portrait-office-probe.json').write_text(json.dumps(probe, indent=2) + '\n')
print(json.dumps({'duration': video.get('duration'), 'width': video['width'], 'height': video['height'], 'fps': fps, 'frames': int(video['nb_frames']), 'sampleFrames': samples, 'audioStreams': len([s for s in probe['streams'] if s['codec_type'] == 'audio'])}))
