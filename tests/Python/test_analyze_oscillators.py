"""Synthetic audio only: these tests cannot acquire audio or touch FPGA ports."""
import io
import json
from pathlib import Path
import tempfile
import unittest
import wave

import numpy as np

import analyze_oscillators as ao

HERE = Path(__file__).resolve().parent


def wav_stream(samples, rate=48000, channels=2):
    pcm = np.clip(np.rint(samples*32768), -32768, 32767).astype('<i2')
    stream = io.BytesIO()
    with wave.open(stream, 'wb') as wav:
        wav.setnchannels(channels); wav.setsampwidth(2); wav.setframerate(rate)
        wav.writeframes(pcm.tobytes())
    stream.seek(0)
    return stream


def bank(seconds=8, *, missing=(), offsets=None, amplitude=.006, extra=None, antiphase=False):
    t = np.arange(round(seconds*ao.RATE))/ao.RATE
    signal = np.zeros(len(t))
    for i, f in enumerate(ao.DDS):
        if i not in missing:
            signal += amplitude*np.sin(2*np.pi*(f+(offsets or {}).get(i, 0))*t+i*.17)
    if extra:
        signal += extra[1]*np.sin(2*np.pi*extra[0]*t)
    return np.column_stack((signal, -signal if antiphase else signal))


def timing(start=.1, **updates):
    return dict(source='waveInStart+protocol08_echo', acquisition_progress_verified=True,
                sweep_start_seconds=start, sweep_request_seconds=start-.001,
                sweep_ack_seconds=start+.001, uncertainty_seconds=.05, **updates)


def sweep(*, disappear=True, noise=0., collateral=False, start=.1):
    samples = bank(32.6)
    t = np.arange(len(samples))/ao.RATE
    if disappear:
        for i, f in enumerate(ao.DDS):
            selection = (t >= start+i) & (t < start+i+.5)
            tone = .006*np.sin(2*np.pi*f*t[selection]+i*.17)
            samples[selection] -= tone[:, None]
            if collateral and i == 10:
                other = .004*np.sin(2*np.pi*ao.DDS[20]*t[selection]+20*.17)
                samples[selection] -= other[:, None]
    if noise:
        samples += np.random.default_rng(841).normal(0, noise, samples.shape)
    return wav_stream(samples)


class OscillatorAnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.full_bytes = wav_stream(bank()).getvalue()

    def main_audio(self):
        return io.BytesIO(self.full_bytes)

    def test_exact_dds_frequencies_all_32_pass(self):
        result, _ = ao.analyze(self.main_audio())
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(len(result['frequencies']), 32)
        self.assertTrue(all(r['error_hz'] < .1 for r in result['frequencies']))
        self.assertEqual(result['fullscale_sample_count'], 0)
        self.assertFalse(result['physical_controls_verified'])

    def test_one_missing_voice_is_failure(self):
        result, _ = ao.analyze(wav_stream(bank(missing=(11,))))
        self.assertEqual(result['status'], 'fail')
        self.assertEqual(result['frequencies'][11]['status'], 'fail')

    def test_wrong_voice_frequency_is_failure(self):
        result, _ = ao.analyze(wav_stream(bank(offsets={7: 12})))
        self.assertEqual(result['status'], 'fail')
        self.assertGreater(result['frequencies'][7]['error_hz'], 10)

    def test_tolerance_is_maximum_of_3hz_and_point2percent(self):
        result, _ = ao.analyze(wav_stream(bank(offsets={0: 2.6, 31: 6})))
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['frequencies'][0]['tolerance_hz'], 3)
        self.assertGreater(result['frequencies'][31]['tolerance_hz'], 6)

    def test_large_5k_tone_does_not_replace_specified_peaks(self):
        result, _ = ao.analyze(wav_stream(bank(extra=(5000, .4))))
        self.assertEqual(result['status'], 'pass')

    def test_constant_5k_alone_never_passes(self):
        result, _ = ao.analyze(wav_stream(bank(missing=range(32), extra=(5000, .4))))
        self.assertEqual(result['status'], 'inconclusive')
        self.assertFalse(any(r['visible'] for r in result['frequencies']))

    def test_harmonics_do_not_replace_all_specified_frequencies(self):
        t = np.arange(8*ao.RATE)/ao.RATE
        mono = sum(.006*np.sin(2*np.pi*400*i*t) for i in range(1, 17))
        result, _ = ao.analyze(wav_stream(np.column_stack((mono, mono))))
        self.assertNotEqual(result['status'], 'pass')

    def test_stereo_antiphase_does_not_cancel(self):
        result, _ = ao.analyze(wav_stream(bank(antiphase=True)))
        self.assertEqual(result['status'], 'pass')

    def test_positive_and_negative_fullscale_are_failure(self):
        for value in (32767/32768, -1):
            samples = bank(); samples[100, 1] = value
            result, _ = ao.analyze(wav_stream(samples))
            self.assertEqual(result['status'], 'fail')
            self.assertEqual(result['fullscale_sample_count'], 1)

    def test_quiet_bank_is_inconclusive(self):
        result, _ = ao.analyze(wav_stream(bank(amplitude=1e-7)))
        self.assertEqual(result['status'], 'inconclusive')

    def test_broadband_noise_is_inconclusive(self):
        samples = np.random.default_rng(32).normal(0, .03, (8*ao.RATE, 2))
        result, _ = ao.analyze(wav_stream(samples))
        self.assertEqual(result['status'], 'inconclusive')

    def test_short_bank_is_inconclusive(self):
        result, _ = ao.analyze(wav_stream(bank(2)))
        self.assertEqual(result['status'], 'inconclusive')

    def test_wrong_format_and_unbounded_duration_rejected(self):
        for stream in (wav_stream(bank(), rate=44100), wav_stream(bank()[:, :1], channels=1),
                       wav_stream(np.zeros((40*ao.RATE+1, 2)))):
            with self.assertRaises(ValueError):
                ao.read_wav(stream)

    def test_truncated_wav_rejected(self):
        with self.assertRaises(ValueError):
            ao.read_wav(io.BytesIO(self.full_bytes[:-4]))

    def test_autonomous_32_voice_independence_passes(self):
        result, _ = ao.analyze(self.main_audio(), independence_wav=sweep(), timing=timing())
        self.assertEqual(result['status'], 'pass')
        voices = result['independence']['voices']
        self.assertEqual(len(voices), 32)
        self.assertTrue(all(r['target_loss_lower_bound_db'] >= 15 for r in voices))
        self.assertTrue(all(r['other_peak_max_change_db'] <= 3 for r in voices))

    def test_constant_bank_cannot_pass_independence(self):
        result, _ = ao.analyze(self.main_audio(), independence_wav=sweep(disappear=False), timing=timing())
        self.assertEqual(result['independence']['status'], 'fail')

    def test_collateral_voice_change_is_failure(self):
        result, _ = ao.analyze(self.main_audio(), independence_wav=sweep(collateral=True), timing=timing())
        self.assertEqual(result['independence']['voices'][10]['status'], 'fail')

    def test_missing_inexact_or_unverified_timing_is_inconclusive(self):
        bad = [None, {}, timing() | {'uncertainty_seconds': .3}, timing() | {'sweep_ack_seconds': .4},
               timing() | {'acquisition_progress_verified': False}, timing() | {'sweep_start_seconds': float('nan')}]
        for item in bad:
            result, _ = ao.analyze(self.main_audio(), independence_wav=sweep(), timing=item)
            self.assertEqual(result['independence']['status'], 'inconclusive')

    def test_noisy_disappearance_is_not_false_pass(self):
        result, _ = ao.analyze(self.main_audio(), independence_wav=sweep(noise=.1), timing=timing())
        self.assertEqual(result['independence']['status'], 'inconclusive')

    def test_observed_audio_timing_shift_is_inconclusive_not_false_failure(self):
        result, _ = ao.analyze(self.main_audio(), independence_wav=sweep(start=.4), timing=timing())
        self.assertEqual(result['independence']['status'], 'inconclusive')
        self.assertIn('contradicts', result['independence']['reason'])

    def test_report_saves_absolute_json_csv_and_png_without_overwrite(self):
        result, fft = ao.analyze(self.main_audio())
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            paths = ao.save_report(result, fft, tmp)
            self.assertTrue(all(Path(p).is_absolute() and Path(p).is_file() for p in paths.values()))
            self.assertEqual(json.loads(Path(paths['json']).read_text(encoding='utf-8'))['status'], 'pass')
            self.assertEqual(len(Path(paths['csv']).read_text(encoding='utf-8-sig').splitlines()), 33)
            self.assertEqual(Path(paths['png']).read_bytes()[:8], b'\x89PNG\r\n\x1a\n')
            with self.assertRaises(ValueError):
                ao.save_report(result, fft, tmp)


if __name__ == '__main__':
    unittest.main()
