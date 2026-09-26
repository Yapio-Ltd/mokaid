from pathlib import Path
import subprocess, json, hashlib
from PIL import Image, ImageDraw, ImageChops, ImageStat

ROOT = Path(__file__).resolve().parents[2]
REVIEW = ROOT / 'production/review'
FRAMES = REVIEW / '7-adaptive-frames'
FRAMES.mkdir(exist_ok=True)

def extract(clip, n, dest, extra=''):
    vf = f'select=eq(n\\,{n})' + (',' + extra if extra else '')
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(ROOT/'clips'/clip),'-vf',vf,'-frames:v','1',str(dest)],check=True)
    return dest

def sheet(paths, dest, size=(216,384), cols=6):
    w,h=size
    rows=(len(paths)+cols-1)//cols
    im=Image.new('RGB',(cols*w,rows*(h+28)),'#111111')
    draw=ImageDraw.Draw(im)
    for i,(label,path) in enumerate(paths):
        x,y=(i%cols)*w,(i//cols)*(h+28)
        im.paste(Image.open(path).convert('RGB').resize(size,Image.Resampling.LANCZOS),(x,y))
        draw.text((x+5,y+h+7),label,fill='white')
    im.save(dest,quality=94)

summary=[]
for variant,job in [('portrait','1254b527-037e-4ce6-8b9c-76caa2b23c95'),('square','e27cf9f0-b299-4773-803b-abe8055fd872')]:
    filename=f'07-execution-{variant}.mp4'
    path=ROOT/'clips'/filename
    probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(path)]))
    stream=next(s for s in probe['streams'] if s['codec_type']=='video')
    last=int(stream['nb_frames'])-1
    raw=[]
    output=[]
    for n in sorted(set(list(range(0,last+1,24))+[last])):
        p=extract(filename,n,FRAMES/f'{variant}-{n:04d}.png')
        raw.append((f'{n/24:.2f}s / f{n}',p))
        if variant=='square':
            cropped=FRAMES/f'square-4x5-{n:04d}.png'
            image=Image.open(p).convert('RGB')
            w,h=image.size
            cw=round(h*4/5)
            image.crop(((w-cw)//2,0,(w+cw)//2,h)).save(cropped)
            output.append((f'{n/24:.2f}s / f{n}',cropped))
        else: output.append(raw[-1])
    sheet(output,REVIEW/f'7-adaptive-{variant}-contact.jpg',size=(216,384) if variant=='portrait' else (264,330))
    if variant=='square': sheet(raw,REVIEW/'7-adaptive-square-raw-contact.jpg',size=(240,240))
    crop='crop=ih*9/16:ih:(iw-ow)*0.5:0,scale=1080:1920:flags=lanczos' if variant=='portrait' else 'crop=ih*4/5:ih:(iw-ow)*0.5:0,scale=1080:1350:flags=lanczos'
    start=extract(f'06-life-{variant}-reverse.mp4',0,FRAMES/f'{variant}-start-reference.png',crop)
    target_crop='crop=ih*9/16:ih:(iw-ow)*0.65:0,scale=1080:1920:flags=lanczos' if variant=='portrait' else 'crop=ih*4/5:ih:(iw-ow)*0.65:0,scale=1080:1350:flags=lanczos'
    end=extract('07-execution.mp4',240,FRAMES/f'{variant}-end-reference.png',target_crop)
    pairs=[('06 reversed final',start),('07 generated first',output[0][1]),('07 generated last',output[-1][1]),('07 real final crop .65',end)]
    sheet(pairs,REVIEW/f'7-adaptive-{variant}-joins.jpg',size=(270,480) if variant=='portrait' else (320,400),cols=4)
    diffs={}
    for name,ref,actual in [('start',start,output[0][1]),('end',end,output[-1][1])]:
        a=Image.open(ref).convert('RGB')
        b=Image.open(actual).convert('RGB').resize(a.size,Image.Resampling.LANCZOS)
        means=ImageStat.Stat(ImageChops.difference(a,b)).mean
        diffs[name]=round(sum(means)/3,3)
    summary.append({'variant':variant,'jobId':job,'file':str(path.relative_to(ROOT)),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'fileBytes':path.stat().st_size,'width':stream['width'],'height':stream['height'],'frames':int(stream['nb_frames']),'frameRate':stream['r_frame_rate'],'videoDuration':stream['duration'],'audioStreams':len([s for s in probe['streams'] if s['codec_type']=='audio']),'sampleFrames':[int(label.split('f')[-1]) for label,p in raw],'endpointMeanAbsoluteRGBDifference255':diffs})
    (REVIEW/f'7-adaptive-{variant}-probe.json').write_text(json.dumps(probe,indent=2)+'\n')
(REVIEW/'7-adaptive-technical.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
