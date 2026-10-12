"""Pure offline 32-oscillator checks; no device, capture or programming calls.

Input is finite 48000 Hz stereo PCM16. Frequencies use the FPGA DDS rate,
93750 Hz, not the acquisition rate. Sweep timing is approximate: UART echo
does not report FPGA test state or calibrate input latency.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
import wave

import numpy as np

RATE = 48000
TARGETS = np.array([400 + 97*i for i in range(32)], dtype=float)
DDS = np.array([round(float(f)*2**24/93750)*93750/2**24 for f in TARGETS])
MIN_LEVEL_DBFS = -72.0
PROMINENCE_DB = 12.0
LOSS_DB = 15.0
STABILITY_DB = 3.0
TIMING_NOTE = ('FFT 时间轴按 WAV 首样本与 waveInStart/控制事件近似对齐；'
               '未标定采集驱动延迟，ACK 仅验证协议 08 回显，不证明 FPGA 测试状态。')


def db(value):
    return float(20*np.log10(max(float(value), 1e-15)))


def read_wav(source):
    """A path or binary stream; reject wrong formats, truncation and >40 s."""
    owned = isinstance(source, (str, Path))
    stream = Path(source).open('rb') if owned else source
    try:
        with wave.open(stream, 'rb') as wav:
            if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth(),
                    wav.getcomptype()) != (RATE, 2, 2, 'NONE'):
                raise ValueError('requires 48000 Hz stereo uncompressed PCM16 WAV')
            frames = wav.getnframes()
            if not 0 < frames <= 40*RATE:
                raise ValueError('WAV must have a finite duration in (0, 40] seconds')
            raw = wav.readframes(frames)
            if len(raw) != frames*4:
                raise ValueError('truncated PCM data')
        pcm = np.frombuffer(raw, dtype='<i2').reshape(-1, 2).copy()
        return pcm, pcm.astype(float)/32768
    finally:
        if owned:
            stream.close()


def spectrum(samples):
    if len(samples) < .15*RATE:
        raise ValueError('analysis window too short')
    window = np.hanning(len(samples))
    centered = samples - samples.mean(axis=0)
    amplitudes = np.abs(np.fft.rfft(centered*window[:, None], axis=0))*2/window.sum()
    # Power across channels preserves antiphase stereo tones.
    amplitude = np.sqrt(np.mean(amplitudes**2, axis=1))
    return np.fft.rfftfreq(len(samples), 1/RATE), amplitude


def peak_rows(samples):
    frequencies, amplitudes = spectrum(samples)
    spacing = frequencies[1]
    rows = []
    for index, (target, expected) in enumerate(zip(TARGETS, DDS)):
        near = np.flatnonzero(np.abs(frequencies-expected) <= 35)
        k = int(near[np.argmax(amplitudes[near])])
        side = (np.abs(frequencies-expected) >= 8) & (np.abs(frequencies-expected) <= 45)
        noise = max(float(np.percentile(amplitudes[side], 80)), 1e-15)
        amplitude = float(amplitudes[k])
        prominence = db(amplitude/noise)
        local_max = 0 < k < len(amplitudes)-1 and amplitudes[k] > max(amplitudes[k-1], amplitudes[k+1])
        offset = 0.0
        if local_max:
            left, center, right = np.log(np.maximum(amplitudes[k-1:k+2], 1e-15))
            denominator = left-2*center+right
            if denominator:
                offset = float(np.clip(.5*(left-right)/denominator, -.5, .5))
        measured = float(frequencies[k] + offset*spacing)
        visible = bool(local_max and db(amplitude) >= MIN_LEVEL_DBFS and prominence >= PROMINENCE_DB)
        tolerance = max(3., .002*float(expected))
        rows.append(dict(index=index, target_hz=float(target), dds_hz=float(expected),
                         measured_hz=measured if visible else None,
                         error_hz=abs(measured-expected) if visible else None,
                         tolerance_hz=tolerance, level_dbfs=db(amplitude),
                         local_noise_dbfs=db(noise), local_prominence_db=prominence,
                         visible=visible, status='pass' if visible and abs(measured-expected) <= tolerance
                         else 'fail' if visible else 'inconclusive'))
    # Missing peaks are decisive only with evidence of a strong intended bank.
    # A microphone hiss or an unrelated 5 kHz maximum cannot supply that evidence.
    reliable_bank = sum(r['visible'] for r in rows) >= 24
    for row in rows:
        if not row['visible']:
            row['status'] = 'fail' if reliable_bank else 'inconclusive'
            row['reason'] = ('specified peak missing in an otherwise visible bank' if reliable_bank
                             else 'insufficient intended signal or local prominence')
    return rows, (frequencies, amplitudes)


def combine(statuses):
    return 'fail' if 'fail' in statuses else 'inconclusive' if 'inconclusive' in statuses else 'pass'


def amplitudes_at_dds(samples):
    """Windowed complex projection at each DDS frequency, separately per channel."""
    window = np.hanning(len(samples))
    centered = samples-samples.mean(axis=0)
    times = np.arange(len(samples))/RATE
    # Small .2 s windows keep allocation finite even for the 32 s sweep.
    basis = np.exp(-2j*np.pi*DDS[:, None]*times[None, :])
    amplitude = 2*np.abs(basis @ (centered*window[:, None]))/window.sum()
    return np.sqrt(np.mean(amplitude**2, axis=1))


def sweep_analysis(samples, timing):
    duration = len(samples)/RATE
    empty = dict(status='inconclusive', voices=[], timing_note=TIMING_NOTE)
    try:
        start = float(timing['sweep_start_seconds'])
        uncertainty = float(timing['uncertainty_seconds'])
        bound_start = float(timing['sweep_request_seconds'])
        bound_end = float(timing['sweep_ack_seconds'])
        valid = (timing.get('source') == 'waveInStart+protocol08_echo'
                 and timing.get('acquisition_progress_verified') is True
                 and all(math.isfinite(x) for x in (start, uncertainty, bound_start, bound_end))
                 and 0 <= uncertainty <= .10 and 0 <= bound_start <= start <= bound_end
                 and bound_end-bound_start <= .08 and start >= 0
                 and duration >= start+32 and duration <= 40)
    except (KeyError, TypeError, ValueError):
        valid = False
    if not valid:
        return dict(empty, reason='missing/inexact sweep timing or incomplete 32 s capture')
    # An observable voice-0 OFF -> ON edge can contradict host timing. Do not
    # turn a shifted capture into a device failure or silently optimize its
    # alignment until it passes. Absence of an edge remains a sweep failure
    # when the signal itself is sufficient (e.g. an unchanged 32-tone bank).
    centers = np.arange(start+.15, start+1.45, .02)
    envelope = []
    for center in centers:
        segment = samples[round((center-.04)*RATE):round((center+.04)*RATE)]
        window = np.hanning(len(segment))
        basis = np.exp(-2j*np.pi*DDS[0]*np.arange(len(segment))/RATE)
        amplitude = 2*np.abs(basis @ ((segment-segment.mean(axis=0))*window[:, None]))/window.sum()
        envelope.append(float(np.sqrt(np.mean(amplitude**2))))
    reference = max(envelope)
    dark_seen = False
    observed_edge = None
    if db(reference) >= MIN_LEVEL_DBFS:
        for position in range(len(envelope)-1):
            dark_seen |= envelope[position] < .2*reference
            if dark_seen and envelope[position] >= .7*reference and envelope[position+1] >= .7*reference:
                observed_edge = float(centers[position])
                break
    if observed_edge is not None and abs(observed_edge-(start+.5)) > .10:
        return dict(empty, reason='observed voice-0 transition contradicts approximate host timing',
                    observed_voice0_on_seconds=observed_edge, expected_voice0_on_seconds=start+.5)
    rows = []
    for index in range(32):
        def cut(a, b):
            return samples[round((start+index+a)*RATE):round((start+index+b)*RATE)]
        off, on = cut(.15, .35), cut(.65, .85)
        off_amp, on_amp = amplitudes_at_dds(off), amplitudes_at_dds(on)
        off_freq, off_fft = spectrum(off)
        on_freq, on_fft = spectrum(on)
        def floors(freq, fft):
            return np.array([max(float(np.percentile(fft[(np.abs(freq-f) >= 20)
                & (np.abs(freq-f) <= 42)], 80))*3, 2/32768) for f in DDS])
        off_floor, on_floor = floors(off_freq, off_fft), floors(on_freq, on_fft)
        loss = db(on_amp[index]/max(off_amp[index], off_floor[index]))
        others = np.arange(32) != index
        stable = np.array([db(a/b) for a, b in zip(on_amp[others], off_amp[others])])
        sufficient = bool(on_amp[index] >= max(on_floor[index], 10**(MIN_LEVEL_DBFS/20))
                          and np.all(on_amp[others] >= on_floor[others])
                          and np.all(off_amp[others] >= off_floor[others]))
        max_change = float(np.max(np.abs(stable)))
        # If OFF is noise-limited, loss is a conservative lower bound. A noisy
        # bound below 15 dB cannot prove failure of the target disappearance.
        noise_limited = off_amp[index] < off_floor[index]
        status = ('inconclusive' if not sufficient or (noise_limited and loss < LOSS_DB)
                  else 'pass' if loss >= LOSS_DB and max_change <= STABILITY_DB else 'fail')
        rows.append(dict(index=index, dds_hz=float(DDS[index]), status=status,
                         off_window_seconds=[start+index+.15, start+index+.35],
                         on_window_seconds=[start+index+.65, start+index+.85],
                         target_loss_lower_bound_db=loss,
                         other_peak_max_change_db=max_change,
                         other_peak_changes_db=stable.tolist(),
                         signal_sufficient=sufficient, noise_limited=noise_limited))
    return dict(status=combine([r['status'] for r in rows]), voices=rows,
                timing=timing, timing_note=TIMING_NOTE,
                observed_voice0_on_seconds=observed_edge,
                limits=dict(target_loss_db=LOSS_DB, other_peak_change_db=STABILITY_DB))


def analyze(wav, *, independence_wav=None, timing=None):
    pcm, samples = read_wav(wav)
    duration = len(samples)/RATE
    rows, fft = peak_rows(samples)
    clipped = int(np.count_nonzero((pcm == 32767) | (pcm == -32768)))
    bank_status = combine([r['status'] for r in rows]) if duration >= 8 else 'inconclusive'
    result = dict(status=bank_status, wav=str(Path(wav).resolve()) if isinstance(wav, (str, Path)) else '<stream>',
                  duration_seconds=duration, sample_rate_hz=RATE, channels=2,
                  fullscale_sample_count=clipped, frequencies=rows,
                  full_bank_status=bank_status, timing_note=TIMING_NOTE,
                  physical_controls_verified=False, fpga_mode_ack_available=False,
                  thresholds=dict(min_level_dbfs=MIN_LEVEL_DBFS, local_prominence_db=PROMINENCE_DB,
                                  frequency_error='max(3 Hz, 0.2% of DDS frequency)', fullscale_samples=0))
    statuses = [bank_status]
    if independence_wav is not None:
        sweep_pcm, sweep = read_wav(independence_wav)
        result['independence_wav'] = str(Path(independence_wav).resolve()) if isinstance(independence_wav, (str, Path)) else '<stream>'
        result['independence'] = sweep_analysis(sweep, timing or {})
        clipped += int(np.count_nonzero((sweep_pcm == 32767) | (sweep_pcm == -32768)))
        statuses.append(result['independence']['status'])
    if clipped:
        statuses.append('fail')
    result['fullscale_sample_count'] = clipped
    result['status'] = combine(statuses)
    return result, fft


def save_report(result, fft, output_dir):
    """Exclusive JSON/CSV/PNG report creation; Pillow is bundled, no plotting install."""
    from PIL import Image, ImageDraw
    folder = Path(output_dir).resolve()
    paths = {suffix: folder/('oscillators.'+suffix) for suffix in ('json', 'csv', 'png')}
    if not folder.is_dir() or any(p.exists() for p in paths.values()):
        raise ValueError('report directory must exist and report files must be new')
    result['report_paths'] = {k: str(v) for k, v in paths.items()}
    with paths['json'].open('x', encoding='utf-8') as out:
        json.dump(result, out, ensure_ascii=False, indent=2, allow_nan=False)
    columns = ('index', 'target_hz', 'dds_hz', 'measured_hz', 'error_hz', 'tolerance_hz',
               'level_dbfs', 'local_noise_dbfs', 'local_prominence_db', 'status')
    with paths['csv'].open('x', encoding='utf-8-sig', newline='') as out:
        writer = csv.DictWriter(out, fieldnames=columns, extrasaction='ignore')
        writer.writeheader(); writer.writerows(result['frequencies'])
    width, height = 1400, 640
    image = Image.new('RGB', (width, height), 'white')
    draw = ImageDraw.Draw(image)
    left, top, right, bottom = 75, 55, width-30, height-75
    draw.text((left, 15), '32 DDS oscillators | '+result['status']+' | 48 kHz stereo PCM16', fill='black')
    draw.text((left, height-35), 'Frequency (Hz); channel power combined. FFT time alignment approximate.', fill='black')
    for value in range(-120, 1, 20):
        y = top-(value/120)*(bottom-top)
        draw.line((left, y, right, y), fill='#dddddd')
        draw.text((10, y-5), str(value)+' dBFS', fill='black')
    for value in range(0, 6001, 500):
        x = left+value/6000*(right-left)
        draw.text((x-12, bottom+12), str(value), fill='black')
    frequencies, amplitudes = fft
    # Reduce by pixel maxima so an unrelated 5 kHz spike is displayed honestly,
    # while individual test peaks are still decided only at specified targets.
    selected = frequencies <= 6000
    pixels = np.minimum(right-left, (frequencies[selected]/6000*(right-left)).astype(int))
    levels = np.clip(20*np.log10(np.maximum(amplitudes[selected], 1e-15)), -120, 0)
    bins = np.full(right-left+1, -120.)
    np.maximum.at(bins, pixels, levels)
    points = [(left+i, top-float(level)/120*(bottom-top)) for i, level in enumerate(bins)]
    draw.line(points, fill='#254f89', width=1)
    for row in result['frequencies']:
        x = left+row['dds_hz']/6000*(right-left)
        color = {'pass': '#16854a', 'fail': '#c82727', 'inconclusive': '#aa7800'}[row['status']]
        draw.line((x, top, x, top+18), fill=color, width=2)
    with paths['png'].open('xb') as out:
        image.save(out, format='PNG')
    return result['report_paths']


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wav', type=Path, required=True)
    parser.add_argument('--independence-wav', type=Path)
    parser.add_argument('--run-json', type=Path, help='oscillator_test journal with independence_timing')
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args(argv)
    timing = None
    if args.run_json:
        timing = json.loads(args.run_json.read_text(encoding='utf-8')).get('independence_timing')
    result, fft = analyze(args.wav, independence_wav=args.independence_wav, timing=timing)
    save_report(result, fft, args.output_dir)
    print(json.dumps({'status': result['status'], 'reports': result['report_paths']}, ensure_ascii=True))
    return {'pass': 0, 'fail': 1, 'inconclusive': 2}[result['status']]


if __name__ == '__main__':
    raise SystemExit(main())
