"""Independent FFT check of PCM emitted by RTL; explicitly not hardware audio."""
from pathlib import Path
import json
import wave
import numpy as np
from PIL import Image, ImageDraw

ROOT=Path(__file__).resolve().parents[1]
SIM=ROOT/'validation/simulation'
RUNS=sorted(p.parent for p in SIM.glob('run_*/digital_pcm32.txt'))
if RUNS: SIM=RUNS[-1]
OUT=ROOT/'validation/digital_spectrum'
OUT.mkdir(exist_ok=True)
rate=93750
targets=np.array([round((400+97*i)*2**24/rate)*rate/2**24 for i in range(32)])

def spectrum(path):
    values=np.loadtxt(path,dtype=np.int16).astype(float)
    window=np.hanning(len(values))
    nfft=2**int(np.ceil(np.log2(len(values)*16)))
    data=2*np.abs(np.fft.rfft((values-values.mean())*window,n=nfft))/window.sum()
    freq=np.fft.rfftfreq(nfft,1/rate)
    return values,freq,data

def peak(freq,amplitude,target):
    window=(freq>=target-8)&(freq<=target+8)
    indices=np.flatnonzero(window)
    index=int(indices[np.argmax(amplitude[window])])
    return float(freq[index]),float(amplitude[index])

full,freq,amp=spectrum(SIM/'digital_pcm32.txt')
off,off_freq,off_amp=spectrum(SIM/'digital_pcm31_voice18_off.txt')
rows=[]
for i,target in enumerate(targets):
    hz,level=peak(freq,amp,target)
    removed_hz,removed_level=peak(off_freq,off_amp,target)
    candidates=(freq>target-40)&(freq<target+40)&(np.abs(freq-target)>16)
    local_noise=max(float(np.median(amp[candidates])),1e-12)
    prominence=20*np.log10(max(level,1e-12)/local_noise)
    change=20*np.log10(max(removed_level,1e-12)/max(level,1e-12))
    row={'voice':i+1,'target_hz':float(target),'measured_sim_hz':hz,
         'error_hz':hz-float(target),'peak_dbfs':float(20*np.log10(max(level,1e-12)/32768)),
         'local_prominence_db':float(prominence),'voice18_off_change_db':float(change)}
    assert abs(row['error_hz'])<1.0 and prominence>12,row
    if i==17:assert change < -15,row
    else:assert abs(change)<3,row
    rows.append(row)
assert np.max(np.abs(full))<16384
for name,values in [('RTL_32路_仿真非录音.wav',full),('RTL_第18路关闭_仿真非录音.wav',off)]:
    with wave.open(str(OUT/name),'wb') as output:
        output.setnchannels(1);output.setsampwidth(2);output.setframerate(rate)
        output.writeframes(values.astype('<i2').tobytes())
result={'source':'actual RTL simulation PCM; not physical DAC or microphone recording',
        'sample_rate_hz':rate,'frames':len(full),'peak_pcm':int(np.max(np.abs(full))),
        'targets_detected':len(rows),'voice18_frequency_hz':float(targets[17]),
        'voice18_independent_mute_verified':True,'rows':rows,'hardware_verified':False}
(OUT/'RTL频谱验证.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
(OUT/'32路频率.csv').write_text('voice,target_hz,sim_hz,error_hz,peak_dbfs,prominence_db,voice18_off_change_db\n'+
    ''.join(','.join(str(row[key]) for key in ('voice','target_hz','measured_sim_hz','error_hz','peak_dbfs','local_prominence_db','voice18_off_change_db'))+'\n' for row in rows),encoding='ascii')

# Static exported scientific spectrum, sourced from the actual FFT arrays.
im=Image.new('RGB',(1500,680),'white');draw=ImageDraw.Draw(im)
left,top,right,bottom=65,80,1465,580
for db in (-100,-80,-60,-40,-20,0):
    y=bottom-(db+100)*(bottom-top)/100
    draw.line((left,y,right,y),fill='#dddddd');draw.text((12,y-5),str(db),fill='black')
for hz in range(0,4001,500):
    x=left+hz/4000*(right-left)
    draw.line((x,top,x,bottom),fill='#eeeeee');draw.text((x-10,bottom+12),str(hz),fill='black')
for f,a,color in ((freq,amp,'#2374c2'),(off_freq,off_amp,'#df7046')):
    valid=f<=4000
    points=[(left+float(x)/4000*(right-left),bottom-(max(-100,float(20*np.log10(max(y,1e-12)/32768)))+100)/100*(bottom-top)) for x,y in zip(f[valid][::3],a[valid][::3])]
    draw.line(points,fill=color,width=2)
for row in rows:
    x=left+row['target_hz']/4000*(right-left)
    draw.line((x,top+20,x,bottom),fill='#b9cfbe',width=1)
    draw.text((x-4,top+(0 if row['voice']%2 else 12)),str(row['voice']),fill='black')
draw.text((65,25),'RTL simulation: 32 independent DDS voices, Fs=93750 Hz (not hardware recording)',fill='black')
draw.text((65,45),'BLUE: full 32 | ORANGE: voice 18 (2049 Hz) released, other 31 continue',fill='black')
draw.text((65,625),'Frequency (Hz); vertical axis = peak amplitude dBFS. 32/32 targets detected.',fill='black')
im.save(OUT/'RTL_32路频谱_仿真.png')
print(json.dumps({'targets_detected':32,'voice18_drop_db':rows[17]['voice18_off_change_db'],
                  'max_frequency_error_hz':max(abs(r['error_hz']) for r in rows),
                  'min_prominence_db':min(r['local_prominence_db'] for r in rows),
                  'source':'RTL simulation only'},indent=2))
