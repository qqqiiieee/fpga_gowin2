"""Deterministic synthetic-only tests. All WAV/JSON fixtures stay in memory.

Run bundled Python with -B -m unittest discover -s remote_debug
    -p test_evaluate_capture.py -v to avoid creating bytecode files.
"""

import contextlib
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import wave

import numpy as np

import evaluate_capture as evaluator


RATE = 48000


def wav_bytes(samples, *, rate=RATE, channels=2, width=2):
    stream = io.BytesIO()
    if samples.ndim == 1:
        samples = np.repeat(samples[:, None], channels, axis=1)
    pcm = np.clip(np.rint(samples * 32768), -32768, 32767).astype("<i2")
    with wave.open(stream, "wb") as writer:
        writer.setnchannels(channels)
        writer.setsampwidth(width)
        writer.setframerate(rate)
        writer.writeframes(pcm.tobytes())
    stream.seek(0)
    return stream


class CaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.t = np.arange(8 * RATE, dtype=np.float64) / RATE
        cls.noise = np.random.default_rng(20261012).normal(0, .001, (8 * RATE, 2))
        cls.mask = (cls.t >= .75) & (cls.t < 5.75)

    def signal(self, frequency=440, amplitude=.12, *, mask=None):
        mask = self.mask if mask is None else mask
        sound = amplitude * np.sin(2 * np.pi * frequency * self.t) * mask
        return self.noise + sound[:, None]

    def evaluate(self, samples, profile="note", **kwargs):
        kwargs.setdefault("active_start", .75)
        kwargs.setdefault("active_end", 5.75)
        report = evaluator.evaluate_capture(wav_bytes(samples), profile, **kwargs)
        json.dumps(report, ensure_ascii=False, allow_nan=False)
        for name, item in report["checks"].items():
            self.assertIn(item["status"], ("pass", "fail", "inconclusive"), name)
            self.assertIn("metrics", item, name)
            self.assertIn("limits", item, name)
        self.assertIn("未确认", report["summary"])
        return report

    def test_440_hann_target_and_snr(self):
        report = self.evaluate(self.signal())
        self.assertEqual(report["status"], "pass")
        peak = report["checks"]["target_frequency"]["metrics"]["peaks"][0]
        self.assertEqual(peak["status"], "pass")
        self.assertLess(peak["metrics"]["error_percent"], .5)
        self.assertGreater(peak["metrics"]["prominence_db"], 12)
        self.assertGreater(peak["metrics"]["energy_rise_db"], 10)
        self.assertIn("测得 440.", report["summary"])
        self.assertFalse(report["checks"]["capture_calibration"]["metrics"]["deviceInput_calibration_confirmed"])

    def test_old_pt8211_target(self):
        report = self.evaluate(self.signal(evaluator.S6_HZ), active_start=1.25, active_end=5.25)
        self.assertEqual(report["status"], "pass")
        measured = report["checks"]["target_frequency"]["metrics"]["peaks"][0]["metrics"]["frequency_hz"]
        self.assertAlmostEqual(measured, evaluator.S6_HZ, delta=.03)
        self.assertEqual(report["checks"]["noise_reference"]["metrics"]["window_seconds"], [0.0, .5])

    def test_pure_noise_fails_note_with_unknown_source(self):
        report = self.evaluate(self.noise)
        target = report["checks"]["target_frequency"]
        self.assertEqual(report["status"], "fail")
        self.assertTrue(target["source_unknown"])
        self.assertLess(target["metrics"]["energy_rise_db"], 10)

    def test_silence_note_fails_with_unknown_source(self):
        report = self.evaluate(np.zeros_like(self.noise))
        self.assertEqual(report["status"], "fail")
        self.assertTrue(report["checks"]["target_frequency"]["source_unknown"])

    def test_5khz_is_not_440(self):
        report = self.evaluate(self.signal(5000, .3))
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["checks"]["target_frequency"]["metrics"]["peaks"][0]["status"], "fail")

    def test_stronger_5khz_does_not_hide_440(self):
        samples = self.signal(440, .06) + (.35 * np.sin(2 * np.pi * 5000 * self.t) * self.mask)[:, None]
        report = self.evaluate(samples)
        self.assertEqual(report["status"], "pass")
        measured = report["checks"]["target_frequency"]["metrics"]["peaks"][0]["metrics"]["frequency_hz"]
        self.assertAlmostEqual(measured, 440, delta=.05)

    def test_wrong_frequency_inside_search_band_fails_error_limit(self):
        report = self.evaluate(self.signal(443))
        self.assertEqual(report["status"], "fail")
        peak = report["checks"]["target_frequency"]["metrics"]["peaks"][0]
        self.assertGreater(peak["metrics"]["prominence_db"], 12)
        self.assertGreaterEqual(peak["metrics"]["error_percent"], .5)

    def test_weak_but_narrow_note_is_inconclusive(self):
        report = self.evaluate(self.signal(440, .002))
        self.assertEqual(report["status"], "inconclusive")
        peak = report["checks"]["target_frequency"]["metrics"]["peaks"][0]
        self.assertGreater(peak["metrics"]["prominence_db"], 12)
        self.assertLess(peak["metrics"]["energy_rise_db"], 10)

    def test_stereo_antiphase_does_not_cancel(self):
        tone = .12 * np.sin(2 * np.pi * 440 * self.t) * self.mask
        samples = self.noise + np.column_stack((tone, -tone))
        self.assertEqual(self.evaluate(samples)["status"], "pass")

    def test_chord_requires_both_fundamentals(self):
        report = self.evaluate(self.signal(440), "chord")
        peaks = report["checks"]["target_frequency"]["metrics"]["peaks"]
        self.assertEqual(report["status"], "fail")
        self.assertEqual([p["status"] for p in peaks], ["fail", "pass"])
        both = self.signal(261.626) + (.08 * np.sin(2 * np.pi * 440 * self.t) * self.mask)[:, None]
        self.assertEqual(self.evaluate(both, "chord")["status"], "pass")

    def test_custom_chord_list(self):
        both = self.signal(330) + (.08 * np.sin(2 * np.pi * 550 * self.t) * self.mask)[:, None]
        report = self.evaluate(both, "chord", expected_hz_list=[330, 550])
        self.assertEqual(report["status"], "pass")

    def test_agc_flat_volume_is_inconclusive(self):
        report = self.evaluate(self.signal(), "volume")
        self.assertEqual(report["status"], "inconclusive")
        self.assertLess(abs(report["checks"]["volume_change"]["metrics"]["rms_increase_db"]), .05)

    def test_increasing_volume_passes(self):
        amplitude = .025 + .225 * np.clip((self.t - .75) / 5, 0, 1)
        report = self.evaluate(self.signal(amplitude=amplitude), "volume")
        self.assertEqual(report["status"], "pass")
        self.assertGreater(report["checks"]["volume_change"]["metrics"]["rms_increase_db"], 6)

    def test_low_snr_volume_is_inconclusive(self):
        report = self.evaluate(self.signal(amplitude=.001), "volume")
        self.assertEqual(report["status"], "inconclusive")

    def pitch_signal(self, first=433, last=447, amplitude=.1, high_tone=False):
        frequency = first + (last - first) * np.clip((self.t - .75) / 5, 0, 1)
        phase = 2 * np.pi * np.cumsum(frequency) / RATE
        samples = self.noise + (amplitude * np.sin(phase) * self.mask)[:, None]
        if high_tone:
            samples += (.3 * np.sin(2 * np.pi * 5000 * self.t) * self.mask)[:, None]
        return samples

    def test_old_firmware_small_rising_pitch_with_recommended_window(self):
        report = self.evaluate(self.pitch_signal(high_tone=True), "pitch", active_start=1.25, active_end=5.25)
        self.assertEqual(report["status"], "pass")
        metrics = report["checks"]["pitch_change"]["metrics"]
        self.assertGreater(metrics["change_hz"], 10)
        self.assertTrue(433 < metrics["first_hz"] < 438)
        self.assertTrue(442 < metrics["last_hz"] < 447)

    def test_wide_pitch_range_tracks_fundamental_not_harmonic(self):
        samples = self.pitch_signal(420, 460)
        frequency = 420 + 40 * np.clip((self.t - .75) / 5, 0, 1)
        samples += (.25 * np.sin(4 * np.pi * np.cumsum(frequency) / RATE) * self.mask)[:, None]
        report = self.evaluate(samples, "pitch", pitch_range=(200, 1000))
        self.assertEqual(report["status"], "pass")
        self.assertLess(report["checks"]["pitch_change"]["metrics"]["last_hz"], 470)

    def test_downward_pitch_fails_up_and_passes_down(self):
        samples = self.pitch_signal(447, 433)
        self.assertEqual(self.evaluate(samples, "pitch")["status"], "fail")
        self.assertEqual(self.evaluate(samples, "pitch", pitch_direction="down")["status"], "pass")

    def test_flat_pitch_fails(self):
        self.assertEqual(self.evaluate(self.signal(), "pitch")["status"], "fail")

    def test_low_snr_and_5khz_pitch_are_inconclusive(self):
        for samples in (self.noise, self.pitch_signal(amplitude=.001), self.signal(5000, .3)):
            with self.subTest():
                self.assertEqual(self.evaluate(samples, "pitch")["status"], "inconclusive")

    def drum(self, profile, onset=1.5):
        time_since = self.t - onset
        envelope = .24 * np.exp(-np.maximum(time_since, 0) / .12) * (time_since >= 0)
        carrier = (np.sin(2 * np.pi * 75 * self.t) if profile == "kick" else
                   np.random.default_rng(22).normal(0, .5, len(self.t)))
        return self.noise + (envelope * carrier)[:, None]

    def test_kick_and_snare_transient_envelope(self):
        for profile in ("kick", "snare"):
            with self.subTest(profile=profile):
                report = self.evaluate(self.drum(profile), profile)
                self.assertEqual(report["status"], "pass")
                self.assertGreater(report["checks"]["transient_decay"]["metrics"]["decay_db"], 6)
                self.assertFalse(report["checks"]["transient_decay"]["limits"]["fixed_fundamental_required"])

    def test_single_sample_spike_is_not_drum(self):
        samples = self.noise.copy()
        samples[int(1.5 * RATE)] += .8
        report = self.evaluate(samples, "snare")
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["checks"]["transient_decay"]["metrics"]["significant_bursts"], 0)

    def test_sustained_sound_has_no_drum_decay(self):
        self.assertEqual(self.evaluate(self.signal(), "kick")["status"], "fail")

    def test_two_strikes_fail_single_pulse(self):
        samples = self.drum("kick", 1.5) + self.drum("kick", 3.0) - self.noise
        report = self.evaluate(samples, "kick")
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["checks"]["transient_decay"]["metrics"]["significant_bursts"], 2)

    def test_noise_drum_is_inconclusive(self):
        self.assertEqual(self.evaluate(self.noise, "snare")["status"], "inconclusive")

    def test_zero_noise_is_observation_not_digital_failure(self):
        report = self.evaluate(self.noise, "zero")
        self.assertEqual(report["status"], "inconclusive")
        observation = report["checks"]["zero_observation"]
        self.assertGreater(observation["metrics"]["rms"], 0)
        self.assertFalse(observation["limits"]["digital_zero_verifiable_from_analog_wav"])
        narrow = self.evaluate(self.signal(1000, .01), "zero")
        self.assertEqual(narrow["status"], "inconclusive")
        self.assertTrue(any(x["narrow_peak_observed"] for x in narrow["checks"]["zero_observation"]["metrics"]["spectral_peaks"]))

    def test_baseline_keeps_gain_assumption(self):
        report = self.evaluate(self.noise, "zero", baseline=wav_bytes(self.noise))
        self.assertEqual(report["status"], "inconclusive")
        self.assertEqual(report["checks"]["baseline_comparison"]["status"], "pass")
        self.assertTrue(any("AGC" in x for x in report["assumptions"]))
        noisy = self.evaluate(self.noise * 4, "zero", baseline=wav_bytes(self.noise))
        self.assertEqual(noisy["status"], "inconclusive")
        self.assertEqual(noisy["checks"]["baseline_comparison"]["status"], "inconclusive")

    def test_baseline_can_support_missing_pre_noise(self):
        mask = (self.t < 5.0)
        report = self.evaluate(self.signal(mask=mask), active_start=0, active_end=5,
                               baseline=wav_bytes(self.noise))
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["checks"]["noise_reference"]["metrics"]["source"], "baseline_assuming_same_gain")
        no_reference = self.evaluate(self.signal(mask=mask), active_start=0, active_end=5)
        self.assertEqual(no_reference["status"], "inconclusive")

    def test_full_scale_counts_both_channels_and_signs(self):
        samples = self.signal()
        samples[100, 0] = 32767 / 32768
        samples[101, 1] = -1
        report = self.evaluate(samples)
        self.assertEqual(report["status"], "fail")
        metrics = report["checks"]["pcm_full_scale"]["metrics"]
        self.assertEqual(metrics["count"], 2)
        self.assertEqual(metrics["per_channel_count"], [1, 1])
        self.assertEqual(metrics["positive_count"], 1)
        self.assertEqual(metrics["negative_count"], 1)

    def test_invalid_wav_format_duration_and_truncation(self):
        for source in (io.BytesIO(b"not a wave"), wav_bytes(self.noise[:5 * RATE]),
                       wav_bytes(self.noise, rate=44100), wav_bytes(self.noise[:, 0], channels=1),
                       wav_bytes(self.noise, width=1), io.BytesIO(wav_bytes(self.noise).getvalue()[:-100])):
            with self.subTest():
                report = evaluator.evaluate_capture(source, "note", active_start=.75, active_end=5.75)
                self.assertEqual(report["status"], "fail")
                self.assertEqual(report["checks"]["wav_format"]["status"], "fail")

    def test_minimum_six_seconds_is_valid(self):
        report = evaluator.evaluate_capture(wav_bytes(self.signal()[:6 * RATE]), "note", active_start=.75, active_end=5.75)
        self.assertEqual(report["status"], "pass")

    def test_missing_and_invalid_windows(self):
        report = self.evaluate(self.signal(), active_start=None, active_end=None, metadata={})
        self.assertEqual(report["status"], "inconclusive")
        for start, end in ((None, 5), (6, 2), (-1, 5), (1, 9), (1, 1.2)):
            with self.subTest(start=start, end=end):
                self.assertEqual(self.evaluate(self.signal(), active_start=start, active_end=end)["status"], "fail")
        invalid = self.evaluate(self.signal(), active_start=float("nan"), active_end=5)
        self.assertEqual(invalid["status"], "inconclusive")

    def test_nested_relative_metadata_and_explicit_override(self):
        metadata = {"timing": {"active": {"start_seconds": .75, "end_seconds": 5.75}}}
        report = self.evaluate(self.signal(), active_start=None, active_end=None, metadata=metadata)
        self.assertEqual(report["status"], "pass")
        self.assertTrue(report["checks"]["timing"]["metrics"]["source"].startswith("timing"))
        override = self.evaluate(self.signal(), metadata={"timing": {"active_start": 100, "active_end": 200}})
        self.assertEqual(override["status"], "pass")

    def test_monotonic_wall_and_legacy_metadata(self):
        variants = [
            {"timing": {"audio": {"start_monotonic": 100}, "commands": {"start_monotonic": 100.75, "end_monotonic": 105.75}}},
            {"timing": {"audio_start_monotonic_ns": 100000000000, "command_start_monotonic_ns": 100750000000, "command_end_monotonic_ns": 105750000000}},
            {"audio_started_local": "2026-10-12T11:00:00+08:00", "control_started_local": "2026-10-12T11:00:00.750+08:00", "control_ended_local": "2026-10-12T11:00:05.750+08:00"},
            {"started_local": "2026-10-12T11:00:00+08:00", "control_started_local": "2026-10-12T11:00:00.750+08:00", "control_ended_local": "2026-10-12T11:00:05.750+08:00"},
            {"started_local": "2026-10-12T10:59:58+08:00",
             "control_started_local": "2026-10-12T11:00:00.750+08:00",
             "control_ended_local": "2026-10-12T11:00:05.750+08:00",
             "capture_ready": {"capture_started_monotonic": 100},
             "control_started_relative_seconds": .75, "control_ended_relative_seconds": 5.75},
            {"capture_ready": {"capture_started_monotonic": 100},
             "control_started_monotonic": 100.75, "control_ended_monotonic": 105.75},
        ]
        for metadata in variants:
            with self.subTest(metadata=metadata):
                report = self.evaluate(self.signal(), active_start=None, active_end=None, metadata=metadata)
                self.assertEqual(report["status"], "pass")
                self.assertAlmostEqual(report["checks"]["timing"]["metrics"]["active_start_seconds"], .75)

    def test_mixed_clocks_are_not_subtracted(self):
        metadata = {"timing": {"audio_start_monotonic": 100,
                    "command_start_wall": "2026-10-12T11:00:00+08:00",
                    "command_end_wall": "2026-10-12T11:00:05+08:00"}}
        report = self.evaluate(self.signal(), active_start=None, active_end=None, metadata=metadata)
        self.assertEqual(report["status"], "inconclusive")

    def test_metadata_discovery_is_local_and_bad_json_is_tolerated(self):
        with patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", return_value='{"timing":{"active_start":0.75,"active_end":5.75}}'):
            metadata, path, error = evaluator.load_metadata(Path("capture.wav"))
        self.assertEqual(path, "capture.run.json")
        self.assertIsNone(error)
        self.assertEqual(metadata["timing"]["active_start"], .75)
        with patch.object(Path, "is_file", return_value=True), patch.object(Path, "read_text", return_value="{"):
            self.assertIsNotNone(evaluator.load_metadata(Path("capture.wav"))[2])

    def test_cli_saves_chinese_json_without_creating_fixture_files(self):
        audio, info = evaluator.read_wav(wav_bytes(self.signal()))
        written = {}

        def save(path, text, encoding=None):
            written["path"] = path
            written["data"] = json.loads(text)
            written["encoding"] = encoding
            return len(text)

        with patch.object(evaluator, "read_wav", return_value=(audio, info)), \
             patch.object(evaluator, "load_metadata", return_value=({}, None, None)), \
             patch.object(Path, "write_text", autospec=True, side_effect=save), \
             contextlib.redirect_stdout(io.StringIO()) as stdout:
            code = evaluator.main(["--wav", "capture.wav", "--profile", "note", "--output", "result.json",
                                   "--expected-hz", "440", "--active-start", "1.25", "--active-end", "5.25"])
        self.assertEqual(code, 0)
        self.assertEqual(written["data"]["status"], "pass")
        self.assertEqual(written["encoding"], "utf-8")
        self.assertIn("通过", stdout.getvalue())

    def test_cli_will_not_overwrite_inputs(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            evaluator.main(["--wav", "capture.wav", "--profile", "note", "--output", "capture.wav"])


if __name__ == "__main__":
    unittest.main()
