"""Offline, read-only piano pitch audit; run: python -B tests/test_piano_pitch.py.

Only tests/test_piano_pitch.py, tests/tb_midi_piano_notes.v and
validation/piano_pitch/** belong to this audit. No source fix, hardware access,
network access or Gowin build is performed. A quantization failure is an actual
failure (exit 1), never an expected failure or an automatically widened tolerance.
Python standard library only; uses this project's copied Icarus installation.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone, timedelta
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "validation/piano_pitch"
BIN = ROOT / "tools/vendor/iverilog-v12/app/bin"
FS = 93750
MODULUS = 1 << 24
LSB_HZ = FS / MODULUS
SEMITONE = 2 ** (1 / 12)
WHITE = (60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77, 79)
AUDIO_RTL = (
    "midi_uart_rx", "midi_keyboard", "performance_input_hub", "note_table", "voice_allocator",
    "wavetable_synth", "oscillator_test_frequencies", "instrument_audio", "drum_voice",
    "snare_voice", "hat_voice", "performance_mixer", "audio_mix", "dc_blocker",
    "audio_cleanup", "audio_controls", "pt8211_driver",
)
FAILURE = re.compile(r"(?im)^\s*(?:FATAL:|ERROR:)|\b\w*_TEST_FAIL\b")
SESSION = None


def ideal_increment(note):
    return 440 * 2 ** ((note - 69) / 12) * MODULUS / FS


def quantization_violations(values):
    # No low-note or note-zero exemption. Epsilon covers double arithmetic only.
    return [n for n in range(128) if abs(values[n] - ideal_increment(n)) > 0.5 + 1e-9]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


class AuditSession:
    def __init__(self, timeout=240):
        self.timeout = timeout
        self.started = time.monotonic()
        stamp = datetime.now(timezone(timedelta(hours=8))).strftime("%Y%m%d_%H%M%S_%f")
        self.folder = OUTPUT / ("run_" + stamp)
        self.snapshot = self.folder / "snapshot"
        self.snapshot.mkdir(parents=True)
        self.report = {
            "started_beijing": datetime.now(timezone(timedelta(hours=8))).isoformat(),
            "project": str(ROOT), "snapshot": str(self.snapshot),
            "sample_rate_hz": FS, "dds_bits": 24, "quantization_tolerance_lsb": 0.5,
            "quantization_float_epsilon_lsb": 1e-9,
            "hardware_tested": False, "gowin_build_started": False,
            "product_source_modified_by_audit": False,
            "sources_sha256": {}, "snapshot_adaptations": [], "commands": [], "tests": [],
        }
        inputs = sorted((ROOT / "src").glob("*.v")) + sorted((ROOT / "src").glob("*.hex"))
        inputs += [ROOT / p for p in (
            "tests/tb_midi_piano_notes.v", "tests/test_piano_pitch.py", "tests/tb_performance_keys.v")]
        for path in inputs:
            relative = path.relative_to(ROOT).as_posix()
            content = path.read_bytes()
            target = self.snapshot / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            self.report["sources_sha256"][relative] = hashlib.sha256(content).hexdigest()
        # Adapt only a private copy of the historical bench's unconnected inputs.
        legacy = self.snapshot / "tests/tb_performance_keys.v"
        text = legacy.read_text(encoding="utf-8-sig")
        old = ".selected_timbre(chosen));"
        new = (".selected_timbre(chosen),.suppress_select(1'b0),.virtual_enable(1'b0),"
               ".virtual_keys(16'd0),.external_keys(16'd0),.timbre_set_valid(1'b0),"
               ".timbre_set_value(4'd0));")
        if text.count(old) != 1:
            raise RuntimeError("Historical bench changed; inspect the inactive-port adaptation")
        legacy.write_text(text.replace(old, new), encoding="utf-8")
        self.report["snapshot_adaptations"].append({
            "file": "tests/tb_performance_keys.v", "before": old, "after": new,
            "reason": "Tie unused inputs inactive in the private historical-bench copy only; assertions unchanged.",
            "adapted_sha256": sha256(legacy),
        })
        (self.snapshot / "piano_expected.hex").write_text(
            "".join(f"{math.floor(ideal_increment(n) + 0.5):06x}\n" for n in range(128)), encoding="ascii")
        (self.snapshot / "timescale.v").write_text("`timescale 1ns/1ps\n", encoding="ascii")
        app = BIN.parent
        self.report["runtime"] = {
            "iverilog": str(BIN / "iverilog.exe"), "vvp": str(BIN / "vvp.exe"),
            "sha256": {p.relative_to(app).as_posix(): sha256(p)
                       for subdir in (app / "bin", app / "lib")
                       for p in sorted(subdir.rglob("*")) if p.is_file()},
        }
        for tool in ("iverilog.exe", "vvp.exe"):
            if not (BIN / tool).is_file():
                raise FileNotFoundError(BIN / tool)
        self.command("iverilog_version", [BIN / "iverilog.exe", "-V"])
        self.table = self.read_table()
        self.integration = None
        self.report["notes"] = [self.note_row(n) for n in range(128)]
        with (self.folder / "note_table.csv").open("w", encoding="utf-8-sig", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=self.report["notes"][0].keys())
            writer.writeheader(); writer.writerows(self.report["notes"])

    def command(self, label, argv, cwd=None):
        work = cwd or self.snapshot
        started = time.monotonic()
        record = {"label": label, "argv": list(map(str, argv)), "cwd": str(work)}
        try:
            result = subprocess.run(record["argv"], cwd=work, stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=self.timeout)
            output = result.stdout.decode("utf-8", "replace") + result.stderr.decode("utf-8", "replace")
            record.update(returncode=result.returncode, timed_out=False)
        except subprocess.TimeoutExpired as exc:
            output = (exc.stdout or b"").decode("utf-8", "replace") + (exc.stderr or b"").decode("utf-8", "replace")
            record.update(returncode=None, timed_out=True)
        output = output.replace("\r", "")  # Windows Icarus emits CRLF even through pipes.
        record["elapsed_seconds"] = round(time.monotonic() - started, 3)
        log = self.folder / (label + ".log")
        log.write_text(output, encoding="utf-8")
        record["log"] = str(log)
        self.report["commands"].append(record)
        return record, output

    def simulate(self, top, label, work=None, expected_failure=None):
        work = work or self.snapshot
        binary = work / (top + ".vvp")
        bench = "tb_performance_keys.v" if top == "tb_performance_keys" else "tb_midi_piano_notes.v"
        names = (("note_table",) if top == "tb_piano_note_table" else
                 ("matrix_keypad",) if top == "tb_performance_keys" else AUDIO_RTL)
        command = [BIN / "iverilog.exe", "-g2012", "-Wall", "-s", top, "-o", binary,
                   work / "timescale.v", *(work / "src" / (n + ".v") for n in names), work / "tests" / bench]
        compile_record, compile_log = self.command(label + "_compile", command, work)
        if compile_record["returncode"] != 0 or compile_record["timed_out"]:
            raise AssertionError(f"{label}: compilation failed; {compile_record['log']}\n{compile_log[-3000:]}")
        run_record, output = self.command(label + "_run", [BIN / "vvp.exe", binary], work)
        if expected_failure:
            if run_record["timed_out"] or run_record["returncode"] in (None, 0) or expected_failure not in output:
                raise AssertionError(f"{label}: mutation was not rejected for {expected_failure}; {run_record['log']}")
        else:
            marker = {"tb_piano_note_table": "PIANO_NOTE_TABLE_TEST_PASS",
                      "tb_midi_piano_notes": "MIDI_PIANO_NOTES_TEST_PASS",
                      "tb_performance_keys": "PERFORMANCE_KEYS_TEST_PASS"}[top]
            if run_record["returncode"] != 0 or run_record["timed_out"] or FAILURE.search(output) or marker not in output:
                raise AssertionError(f"{label}: simulation failed; {run_record['log']}\n{output[-3000:]}")
        return output

    def read_table(self):
        output = self.simulate("tb_piano_note_table", "table")
        pairs = re.findall(r"^PIANO_TABLE note=(\d+) increment=(\d+)$", output, re.M)
        if len(pairs) != 128 or {int(n) for n, _ in pairs} != set(range(128)):
            raise AssertionError("RTL table dump does not cover each MIDI note exactly once")
        return {int(n): int(inc) for n, inc in pairs}

    def note_row(self, n):
        actual = self.table[n] * LSB_HZ
        target = 440 * 2 ** ((n - 69) / 12)
        return {"midi_note": n, "name": ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")[n % 12] + str(n // 12 - 1),
                "target_hz": target, "increment": self.table[n], "ideal_increment": ideal_increment(n),
                "nearest_increment": math.floor(ideal_increment(n) + 0.5),
                "error_lsb": self.table[n] - ideal_increment(n), "actual_hz": actual,
                "error_hz": actual - target, "error_cents": 1200 * math.log2(actual / target) if actual > 0 else None,
                "passes_half_lsb": abs(self.table[n] - ideal_increment(n)) <= 0.5 + 1e-9}

    def run_integration(self):
        if self.integration is None:
            self.integration = self.simulate("tb_midi_piano_notes", "midi_audio")
            self.report["uart_audio_pass_marker"] = re.search(r"^MIDI_PIANO_NOTES_TEST_PASS .+$", self.integration, re.M).group()
        return self.integration

    def finish(self, result):
        self.report["passed"] = result.wasSuccessful() and result.testsRun == 8 and not result.skipped
        self.report["status"] = "pass" if result.wasSuccessful() else "fail"
        self.report["unittest"] = {"run": result.testsRun, "failures": len(result.failures),
                                   "errors": len(result.errors), "skipped": len(result.skipped)}
        self.report["quantization_failed_notes"] = quantization_violations(self.table)
        self.report["live_files_changed_since_snapshot"] = [
            name for name, digest in self.report["sources_sha256"].items()
            if not (ROOT / name).is_file() or sha256(ROOT / name) != digest]
        essential = {f"src/{name}.v" for name in AUDIO_RTL} | {
            "src/test_sine.hex", "src/timbre_dual_half.hex", "src/matrix_keypad.v",
            "tests/tb_performance_keys.v", "tests/tb_midi_piano_notes.v", "tests/test_piano_pitch.py"}
        self.report["essential_pitch_sources_sha256"] = {
            name: digest for name, digest in self.report["sources_sha256"].items() if name in essential}
        self.report["essential_pitch_sources_changed_since_snapshot"] = [
            name for name in self.report["live_files_changed_since_snapshot"] if name in essential]
        self.report["essential_pitch_sources_match"] = not self.report["essential_pitch_sources_changed_since_snapshot"]
        self.report["passed"] = self.report["passed"] and self.report["essential_pitch_sources_match"]
        self.report["status"] = "pass" if self.report["passed"] else "fail"
        self.report["elapsed_seconds"] = round(time.monotonic() - self.started, 3)
        self.report["finished_beijing"] = datetime.now(timezone(timedelta(hours=8))).isoformat()
        self.report["scope"] = (
            "Production UART receiver -> MIDI decoder -> performance_input_hub -> voice_allocator -> "
            "wavetable_synth PHASE_RAM=1 -> instrument_audio monitor PCM; not full top/UI, hardware, or Gowin.")
        write_json(self.folder / "results.json", self.report)
        # The manifest covers the immutable input copies, binaries, logs and results.
        files = {p.relative_to(self.folder).as_posix(): sha256(p)
                 for p in sorted(self.folder.rglob("*")) if p.is_file() and p.name != "SHA256SUMS.txt"}
        (self.folder / "SHA256SUMS.txt").write_text(
            "".join(f"{digest}  {name}\n" for name, digest in files.items()), encoding="utf-8")
        write_json(OUTPUT / "latest.json", {
            "run": str(self.folder), "status": self.report["status"], "passed": self.report["passed"],
            "results_sha256": sha256(self.folder / "results.json"),
            "manifest_sha256": sha256(self.folder / "SHA256SUMS.txt")})
        write_json(OUTPUT / "results.json", self.report)
        print(f"\nPIANO_AUDIT {self.report['status']} {self.folder / 'results.json'}", flush=True)


def session():
    global SESSION
    if SESSION is None:
        SESSION = AuditSession()
    return SESSION


class PianoPitchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.audit = session()

    def test_01_all_128_present_and_nonzero(self):
        self.assertEqual(set(self.audit.table), set(range(128)))
        self.assertTrue(all(0 < x < MODULUS for x in self.audit.table.values()))

    def test_02_all_128_nearest_dds_increment_half_lsb(self):
        bad = quantization_violations(self.audit.table)
        detail = [{"note": n, "actual": self.audit.table[n],
                   "nearest": math.floor(ideal_increment(n) + 0.5),
                   "error_lsb": round(self.audit.table[n] - ideal_increment(n), 9)} for n in bad]
        self.assertEqual(bad, [], f"DDS entries exceed +/-0.5 LSB: {detail}")

    def test_03_equal_temperament_no_linear_hz_or_diatonic_collapse(self):
        values = self.audit.table
        self.assertEqual(len(set(values.values())), 128)
        for n in range(127):
            self.assertGreater(values[n + 1], values[n], f"collapsed/reversed semitone at {n}")
            # Structural check allows <=1 LSB per entry; strict rounding is test_02.
            self.assertLessEqual(abs(values[n + 1] - SEMITONE * values[n]), 1 + SEMITONE + 1e-9)
        for n in range(116):
            self.assertLessEqual(abs(values[n + 12] - 2 * values[n]), 3)
        self.assertGreater(values[71] - values[70], values[61] - values[60])
        for low, high, steps in ((60, 61, 1), (61, 62, 1), (64, 65, 1), (71, 72, 1), (60, 62, 2)):
            ratio = 2 ** (steps / 12)
            self.assertLessEqual(abs(values[high] - ratio * values[low]), 0.5 * (1 + ratio) + 1e-9)

    def test_04_a4_440_quantization(self):
        row = self.audit.note_row(69)
        self.assertEqual(row["increment"], 78741)
        self.assertLessEqual(abs(row["error_hz"]), LSB_HZ / 2 + 1e-12)
        self.audit.report["a4"] = row
        self.audit.report["one_lsb_hz"] = LSB_HZ

    def test_05_real_uart_chromatic_held_release_velocity_audio_dds(self):
        output = self.audit.run_integration()
        phases = re.findall(r"PIANO_DDS note=(\d+) timbre=(\d+) velocity=(\d+) delta=(\d+) frames=32 increment=(\d+)", output)
        self.assertEqual(len(phases), 26)
        self.assertEqual({(int(n), int(t)) for n, t, *_ in phases},
                         {(n, t) for n in range(60, 73) for t in (0, 1)})
        for n, t, velocity, delta, increment in phases:
            self.assertEqual(int(increment), math.floor(ideal_increment(int(n)) + 0.5))
            self.assertEqual(int(delta), int(increment) * 32 % MODULUS)
        self.audit.report["dds_chromatic_observations"] = [
            dict(zip(("note", "timbre", "velocity", "delta_32_frames", "increment"), map(int, p))) for p in phases]

    def test_06_black_key_pcm_fundamental_distinct(self):
        self.audit.run_integration()
        observations = []
        for n in (60, 61, 62):
            samples = [int(x) for x in (self.audit.snapshot / f"pcm_t0_n{n}.txt").read_text().split()]
            self.assertEqual(len(samples), 4096)
            measured = measure_fundamental(samples)
            measured.update(note=n, target_hz=440 * 2 ** ((n - 69) / 12))
            observations.append(measured)
        self.audit.report["pcm_fundamental"] = observations
        for item in observations:
            self.assertGreater(item["rms"], 1)
            self.assertGreater(item["correlation"], 0.98)
            self.assertLess(abs(item["measured_hz"] - item["target_hz"]), 1.0)
        for a, b in zip(observations, observations[1:]):
            self.assertGreater(b["measured_hz"] - a["measured_hz"], 10)
        self.audit.report["pcm_estimator"] = (
            "4096 production monitor PCM samples at 93750 Hz; decimate by 4; normalized autocorrelation "
            "in 240..320 Hz, quadratic peak interpolation; +/-1 Hz acceptance, correlation>0.98. "
            "Window selected for these C4/C#4/D4 probes only, not a general pitch detector.")

    def test_07_existing_performance_keys_legacy_only(self):
        output = self.audit.simulate("tb_performance_keys", "legacy_performance_keys")
        self.assertIn("12 pitches, 16 timbres", output)
        self.audit.report["legacy_performance_keys"] = {
            "status": "pass", "scope": "Historical matrix-keypad PERFORMANCE_MODE=1, default 16 timbres only",
            "notes": list(WHITE), "proves_chromatic_midi": False,
            "adaptation": "Only inactive-port ties in private bench snapshot; original file unchanged."}

    def test_08_negative_controls_are_detected(self):
        # Start with a mathematically correct table so pre-existing defects cannot
        # accidentally make these negative controls look effective.
        golden = {n: math.floor(ideal_increment(n) + 0.5) for n in range(128)}
        self.assertEqual(quantization_violations(golden), [])
        zero = dict(golden);zero[0] = 0
        self.assertEqual(quantization_violations(zero), [0])
        linear = {n: round(golden[0] + (golden[127] - golden[0]) * n / 127) for n in range(128)}
        self.assertGreater(len(quantization_violations(linear)), 120)
        collapsed = dict(golden)
        for black in (61, 63, 66, 68, 70):collapsed[black] = golden[black - 1]
        self.assertEqual(quantization_violations(collapsed), [61, 63, 66, 68, 70])
        controls = []
        for name, relative, old, new, rejection in (
            ("dds_black_key_alias", "src/note_table.v", "7'd61:phase_inc=24'd49604;",
             "7'd61:phase_inc=24'd46820;", "DDS_NOTE_MISMATCH note=61"),
            ("hub_black_key_alias", "src/performance_input_hub.v",
             "assign note=local_event?local_note:(use_midi?m_note:o_note);",
             "assign note=local_event?local_note:(use_midi?((m_note==61)?7'd60:m_note):o_note);",
             "AUDIO_EVENT_MISMATCH"),
        ):
            work = self.audit.folder / ("negative_" + name)
            # Private sources only; never write production src/**.
            shutil.copytree(self.audit.snapshot, work, ignore=shutil.ignore_patterns("*.vvp", "pcm_*.txt"))
            path = work / relative
            text = path.read_text(encoding="utf-8-sig")
            self.assertEqual(text.count(old), 1, "Source changed; inspect mutation anchor")
            path.write_text(text.replace(old, new), encoding="utf-8")
            self.audit.simulate("tb_midi_piano_notes", name, work, expected_failure=rejection)
            controls.append({"name": name, "private_file": str(path), "before": old,
                             "after": new, "rejected_for": rejection, "status": "pass"})
        self.audit.report["negative_controls"] = {
            "math": ["MIDI 0 incorrectly muted", "linear Hz spacing", "five black keys aliased to white keys"],
            "rtl_private_mutations": controls}


def measure_fundamental(samples):
    mean = sum(samples) / len(samples)
    rms = math.sqrt(sum((x - mean) ** 2 for x in samples) / len(samples))
    signal = [x - mean for x in samples[::4]]
    low = math.floor(FS / 4 / 320)
    high = math.ceil(FS / 4 / 240)
    correlations = {}
    for lag in range(low - 1, high + 2):
        a, b = signal[:-lag], signal[lag:]
        denominator = math.sqrt(sum(x * x for x in a) * sum(x * x for x in b))
        correlations[lag] = sum(x * y for x, y in zip(a, b)) / denominator if denominator else -1
    peak = max(range(low, high + 1), key=correlations.get)
    left, center, right = (correlations[peak + i] for i in (-1, 0, 1))
    denominator = left - 2 * center + right
    offset = 0.5 * (left - right) / denominator if denominator else 0
    return {"measured_hz": FS / 4 / (peak + offset), "correlation": center,
            "rms": rms, "lag_decimated": peak + offset}


class AuditResult(unittest.TextTestResult):
    def addSuccess(self, test):
        super().addSuccess(test)
        session().report["tests"].append({"name": test._testMethodName, "status": "pass"})

    def addFailure(self, test, err):
        super().addFailure(test, err)
        session().report["tests"].append({"name": test._testMethodName, "status": "fail", "detail": str(err[1])})

    def addError(self, test, err):
        super().addError(test, err)
        if SESSION:
            SESSION.report["tests"].append({"name": str(test), "status": "error", "detail": str(err[1])})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=240, help="Timeout per Icarus command in seconds")
    args = parser.parse_args()
    global SESSION
    SESSION = AuditSession(timeout=args.timeout)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PianoPitchTests)
    result = unittest.TextTestRunner(verbosity=2, resultclass=AuditResult).run(suite)
    SESSION.finish(result)
    return 0 if SESSION.report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
