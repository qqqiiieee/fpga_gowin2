"""Analyze explicit PCM16 recordings. No audio device or firmware changes."""
from __future__ import annotations

from pathlib import Path
import wave

import numpy as np


def db(value):
    return float(20 * np.log10(max(float(value), 1e-15)))


def welch(samples, rate):
    # One-second Hann windows, 50% overlap, one-sided power/Hz referenced to
    # sample value 1.0. A full-scale sine has integrated power 0.5 (-3.01 dB).
    length = min(rate, len(samples))
    window = np.hanning(length)
    frames = []
    for start in range(0, len(samples) - length + 1, max(1, length // 2)):
        block = samples[start:start + length]
        spectrum = np.abs(np.fft.rfft((block - block.mean()) * window)) ** 2
        spectrum /= rate * np.sum(window * window)
        if length % 2 == 0:
            spectrum[1:-1] *= 2
        else:
            spectrum[1:] *= 2
        frames.append(spectrum)
    return np.fft.rfftfreq(length, 1 / rate), np.mean(frames, axis=0)


def analyze(path):
    with wave.open(str(path), "rb") as wav:
        if wav.getsampwidth() != 2 or wav.getcomptype() != "NONE":
            raise ValueError("Expected uncompressed PCM16 WAV")
        rate, channels = wav.getframerate(), wav.getnchannels()
        raw = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2")
    raw = raw.reshape(-1, channels)
    samples = raw.astype(np.float64) / 32768.0
    skip = int(0.5 * rate) if len(samples) >= 2 * rate else 0
    statistics = []
    spectra = []
    for channel in range(channels):
        values = samples[:, channel]
        stable = values[skip:]
        frequencies, power = welch(stable, rate)
        spacing = frequencies[1] - frequencies[0]
        candidates = np.flatnonzero((frequencies >= 20) & (frequencies <= 20000))
        peaks = []
        for index in candidates[np.argsort(power[candidates])[::-1]]:
            if all(abs(frequencies[index] - entry["frequency_hz"]) >= 30 for entry in peaks):
                peaks.append({"frequency_hz": round(float(frequencies[index]), 3),
                              "power_dbfs_per_hz": round(float(10 * np.log10(max(power[index], 1e-30))), 2)})
            if len(peaks) == 8:
                break
        bands = {}
        for low, high in [(20, 200), (200, 1000), (1000, 5000), (5000, 20000), (48, 52), (98, 102)]:
            selection = (frequencies >= low) & (frequencies < high)
            bands[f"{low}-{high}_Hz"] = round(db(np.sqrt(power[selection].sum() * spacing)), 2)
        ac = stable - stable.mean()
        statistics.append({
            "channel": channel + 1,
            "rms_dbfs_whole_capture": round(db(np.sqrt(np.mean(values ** 2))), 2),
            "ac_rms_dbfs_excluding_startup": round(db(np.sqrt(np.mean(ac ** 2))), 2),
            "peak_dbfs": round(db(np.max(np.abs(values))), 2),
            "dc_mean": float(values.mean()),
            "rail_sample_count": int(np.count_nonzero((raw[:, channel] == -32768) | (raw[:, channel] == 32767))),
            "rail_sample_fraction": float(np.mean((raw[:, channel] == -32768) | (raw[:, channel] == 32767))),
            "zero_sample_fraction": float(np.mean(raw[:, channel] == 0)),
            "spectral_band_rms_dbfs": bands,
            "strongest_separated_psd_bins": peaks,
        })
        spectra.append((frequencies, power))
    block = max(1, round(rate * 0.1))
    trimmed = samples[:len(samples) // block * block]
    rms_series = np.sqrt(np.mean(trimmed.reshape(-1, block, channels) ** 2, axis=1))
    times = (np.arange(len(rms_series)) + 0.5) * block / rate
    result = {"file": str(path.resolve()), "rate_hz": rate, "channels": channels,
              "duration_seconds": len(samples) / rate, "sample_format": "PCM16",
              "startup_seconds_excluded_from_spectrum": skip / rate,
              "fft_resolution_hz": float(spectra[0][0][1] - spectra[0][0][0]),
              "channel_statistics": statistics,
              "stereo_correlation": float(np.corrcoef(samples.T)[0, 1]) if channels == 2 and np.std(samples, axis=0).min() > 0 else None,
              "measurement_note": "Digital recording levels only; input gain/processing and actual physical jack mode are not calibrated. Requested key action is not independently confirmed. Rail test does not detect upstream analog clipping."}
    return result, samples, times, rms_series, spectra

