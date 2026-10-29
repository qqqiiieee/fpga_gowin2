"""Independent pressure audio RTL regression; offline, no Gowin or hardware.

Writes only validation/pressure_audio_agent.json and its dedicated directory
validation/pressure_audio_agent/. Input snapshots and all logs are retained.
Run: python scripts/run_pressure_audio_tests.py
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BENCH = "tests/tb_pressure_audio_expression.v"
SCRIPT = "scripts/run_pressure_audio_tests.py"
CASES = ["tb_pressure_audio_expression", "tb_pressure_vibrato_hub", "tb_pressure_instrument_audio"]
FAILURE = re.compile(r"(?im)^\s*(?:FATAL:|ERROR:)|\b\w*TEST_FAIL\b")
FS = 93750


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(argv, cwd, log, timeout):
    started = time.monotonic()
    record = {"argv": list(map(str, argv)), "cwd": str(cwd), "log": str(log)}
    try:
        p = subprocess.run(record["argv"], cwd=cwd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout)
        record.update(returncode=p.returncode, stdout=p.stdout, stderr=p.stderr)
    except subprocess.TimeoutExpired as exc:
        def string(s):
            return s.decode("utf-8", errors="replace") if isinstance(s, bytes) else (s or "")
        record.update(returncode=None, timed_out=True, stdout=string(exc.stdout), stderr=string(exc.stderr))
    except OSError as exc:
        record.update(returncode=None, error=str(exc), stdout="", stderr="")
    record["elapsed_seconds"] = round(time.monotonic() - started, 3)
    log.write_text("ARGV " + json.dumps(record["argv"]) + "\nCWD " + str(cwd) + "\n" +
                   record["stdout"] + "\nSTDERR\n" + record["stderr"], encoding="utf-8")
    return record


def rms(values):
    return math.sqrt(sum(x*x for x in values)/len(values))


def filter_analysis(path):
    groups = {}
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            f = int(row["frequency_hz"])
            groups.setdefault(f, []).append([int(row[n]) for n in ["input", "pressure0", "pressure128", "pressure255"]])
    results = {}
    for f in [400, 6000]:
        rows = groups[f]
        assert len(rows) == 9375, (f, "missing tone samples")
        levels = [rms([r[i] for r in rows]) for i in range(4)]
        gain = [x/levels[0] for x in levels[1:]]
        expected = []
        for a in [8, 72, 135]:
            b = 1-a/256
            expected.append((a/256)/math.sqrt(1+b*b-2*b*math.cos(2*math.pi*f/FS)))
        assert levels[1] < levels[2] < levels[3], (f, "pressure RMS not monotonic", levels)
        assert all(abs(a-b)<0.002 for a, b in zip(gain, expected)), (f, gain, expected)
        assert all(abs(sum(r[i] for r in rows)/len(rows)) < 2 for i in range(1, 4)), "tone DC bias"
        results[str(f)] = {"samples": len(rows), "input_rms": levels[0],
                           "output_rms_pressure_0_128_255": levels[1:], "gain": gain,
                           "independent_ideal_one_pole_gain": expected,
                           "high_to_low_pressure_rms_ratio": levels[3]/levels[1],
                           "high_to_low_pressure_energy_ratio": (levels[3]/levels[1])**2,
                           "peak_abs": [max(abs(r[i]) for r in rows) for i in range(1, 4)]}
    assert results["6000"]["high_to_low_pressure_rms_ratio"] > 4, "high-frequency opening <=4x RMS"
    assert results["400"]["gain"][0] > 0.7, "400Hz at light pressure unexpectedly attenuated"
    assert results["400"]["gain"][2] > 0.995, "400Hz heavy-pressure gain not stable"
    return results


def integration_analysis(path):
    groups = {}
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            groups.setdefault(row["mode"], []).append([int(row["pressure0"]), int(row["pressure255"])])
    normal, test = groups["normal"], groups["test32"]
    assert len(normal) == len(test) == 2048, "integration capture missing samples"
    levels = [rms([r[i] for r in normal]) for i in [0, 1]]
    assert levels[1] > 1.2*levels[0] > 0, ("normal PCM brightness did not open", levels)
    assert all(r[0] == r[1] for r in test), "32test pressure dependence"
    return {"normal_rms_pressure0_255": levels, "normal_rms_ratio": levels[1]/levels[0],
            "normal_differing_samples": sum(r[0] != r[1] for r in normal),
            "test32_bit_identical_samples": len(test), "test32_rms": rms([r[0] for r in test]),
            "production_frame_clock_count": 288}


def connection_review(snapshot):
    """Read-only connection audit of the exact sources used for simulation."""
    evidence = []

    def require(relative, pattern, note, minimum=1):
        text = (snapshot / relative).read_text(encoding="utf-8-sig")
        # Preserve line numbering while excluding comments from connection checks.
        code = re.sub(r"//[^\n]*", lambda m: " "*len(m[0]), text)
        code = re.sub(r"/\*.*?\*/", lambda m: "\n"*m[0].count("\n"), code, flags=re.S)
        matches = list(re.finditer(pattern, code, re.S))
        if len(matches) < minimum:
            raise AssertionError("connection audit: " + note)
        evidence.append({"status": "PASS", "note": note, "path": relative,
                         "sha256": sha(snapshot / relative), "match_count": len(matches),
                         "lines": [code.count("\n", 0, m.start())+1 for m in matches]})

    require("src/top.v", r"parameter\s+PRESSURE_EXPRESSION_ENABLE\s*=\s*1", "root top enables pressure expression")
    require("src/top.v", r"\.PRESSURE_EXPRESSION_ENABLE\(PRESSURE_EXPRESSION_ENABLE\)", "root top forwards parameter to audio top")
    require("src/instrument_audio_top.v", r"\.PRESSURE_EXPRESSION_ENABLE\(PRESSURE_EXPRESSION_ENABLE\)", "audio top forwards parameter to inputs and audio", 2)
    require("src/instrument_inputs.v", r"\.PRESSURE_EXPRESSION_ENABLE\(PRESSURE_EXPRESSION_ENABLE\)", "inputs forward parameter to performance hub")
    require("src/instrument_audio.v", r"\.EXPRESSION_ENABLE\(PRESSURE_EXPRESSION_ENABLE\)", "audio forwards expression parameter to cleanup")
    require("src/instrument_inputs.v", r"\.level0\(pressure_brightness\).*?\.level1\(pressure_vibrato\).*?\.calibrated\(pressure_calibrated\)", "pressure A0/A1 outputs are brightness/vibrato with calibration")
    require("src/instrument_audio_top.v", r"\.pressure_brightness\(monitor_expression0\).*?\.pressure_vibrato\(monitor_expression1\)", "inputs export both expression levels")
    require("src/instrument_audio_top.v", r"\.pressure_brightness\(monitor_expression0\).*?\.pressure_brightness_ready\(monitor_pressure_calibrated\[0\]\)", "brightness and its own calibration bit reach audio")
    require("src/instrument_audio.v", r"\.expression\(pressure_brightness\).*?\.expression_ready\(pressure_brightness_ready\)", "brightness/calibration reach actual cleanup ports")
    require("src/instrument_inputs.v", r"\.pressure_vibrato\(pressure_vibrato\)", "A1 vibrato reaches performance hub")
    require("src/instrument_inputs.v", r"if\(PRESSURE_EXPRESSION_ENABLE\).*?assign\s+local_hit0\s*=\s*1'b0\s*;\s*assign\s+local_hit1\s*=\s*1'b0", "expression branch ties both local drum hits to zero")
    require("src/instrument_inputs.v", r"assign\s+local_velocity0\s*=\s*8'd0\s*;\s*assign\s+local_velocity1\s*=\s*8'd0", "expression branch ties local drum velocities to zero")
    require("src/instrument_inputs.v", r"assign\s+hit0\s*=\s*local_hit0\s*\|\|\s*midi_hit0.*?assign\s+hit1\s*=\s*local_hit1\s*\|\|\s*midi_hit1", "MIDI drum hits remain independently connected")
    require("src/instrument_inputs.v", r"slider_controls\s+sliders\(.*?\.adc_channel\(adc_channel\).*?\.volume\(physical_volume\).*?\.pitch\(physical_pitch\)", "A2/A3 still feed slider_controls")
    require("src/slider_controls.v", r"if\(adc_valid\s*&&\s*adc_channel>=2\).*?if\(!idx\)\s*volume<=position;.*?else\s+pitch<=", "slider_controls ignores A0/A1 and maps A2 volume / A3 pitch")
    require("src/instrument_inputs.v", r"assign\s+adc_valid=remote_active\?virtual_valid:hw_adc_valid.*?assign\s+adc_channel=remote_active\?virtual_channel:hw_adc_channel.*?assign\s+adc_data=remote_active\?virtual_data:hw_adc_data", "virtual ADC selects the same pressure and slider path")
    require("src/instrument_audio_top.v", r"\.allow_performance\(normal_input_ready\)", "test-controller normal_input_ready gates performance hub")
    require("src/oscillator_test_control.v", r"assign\s+normal_input_ready=\(state==NORMAL\s*\|\|\s*state==FADE_NORMAL_IN\)", "active test blocks performance modulation, return fade enables normal input")
    require("src/instrument_inputs.v", r"\.digital_zero\(digital_zero_test\)", "digital zero reaches performance hub")
    require("src/performance_input_hub.v", r"pressure_depth=\(PRESSURE_EXPRESSION_ENABLE\s*&&\s*allow_performance\s*&&\s*!digital_zero\)\?pressure_vibrato", "pressure vibrato is gated by performance permission and digital zero")
    require("src/instrument_audio.v", r"\.pitch\(test_mode\?9'sd0:pitch_smooth\)", "32test oscillator pitch bypasses performance modulation")
    require("src/instrument_audio.v", r"mode_sample=test_mode\?mixed:normal_sample", "32test PCM bypasses brightness filter path")
    require("src/instrument_audio.v", r"headphone_sample=digital_zero_test\?16'd0", "final headphone PCM gives digital zero priority")
    return {"status": "PASS", "method": "read-only source connection review; code matches exclude comments",
            "historical_slider_equivalence_claimed": False,
            "note": "Current A2/A3 mapping reviewed; no separate historical-file equivalence test claimed.",
            "checks": evidence}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--iverilog", type=Path)
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    if args.list:
        print("\n".join(CASES));return 0
    chosen = list(dict.fromkeys(args.case or CASES))
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    run = ROOT / "validation/pressure_audio_agent" / stamp
    snapshot = run / "snapshot"
    snapshot.mkdir(parents=True)
    destination = ROOT / "validation/pressure_audio_agent.json"
    suffix = ".exe" if os.name == "nt" else ""
    iv = (args.iverilog or ROOT / ("tools/vendor/iverilog-v12/app/bin/iverilog"+suffix)).resolve()
    vvp = iv.with_name("vvp"+suffix)
    report = {"schema_version": 1, "status": "RUNNING", "scope": "offline_actual_RTL_simulation",
              "project": str(ROOT), "run_directory": str(run), "snapshot_directory": str(snapshot),
              "started_utc": datetime.now(timezone.utc).isoformat(), "tests": [],
              "full_suite": chosen == CASES, "sources_sha256": {}, "bugs": [],
              "write_scope": [BENCH, SCRIPT, "validation/pressure_audio_agent.json", "validation/pressure_audio_agent/**"],
              "hardware_tested": False, "gowin_started": False, "programmed_or_published": False,
              "production": {"main_clock_hz": 27000000, "clocks_per_audio_frame": 288,
                             "sample_hz": FS, "vibrato_phase_step": 1074,
                             "vibrato_hz_calculated": 1074*FS/2**24,
                             "vibrato_period_samples": 2**24/1074,
                             "maximum_pressure_offset_expected": [-128, 125],
                             "offset_note": "triangle -64..63 times255 arithmetic_shift7 gives -128..125 (approximately requested -128..126)"},
              "parameters": {CASES[0]: {"EXPRESSION_ENABLE": [0, 1], "LOWPASS_ENABLE": [0, 1],
                                                        "pressure": [0, 128, 255], "legacy_enable": [0, 1], "ready": [0, 1]},
                             CASES[1]: {"MIDI_ENABLE": [0, 1], "OPTICAL_ENABLE": 0,
                                        "PRESSURE_EXPRESSION_ENABLE": [0, 1], "UART_clocks_per_bit": 864,
                                        "test_clock_period_ns": 10, "sample_tick_accelerated": True},
                             CASES[2]: {"PRESSURE_EXPRESSION_ENABLE": 1, "PHASE_RAM": 1,
                                        "REDUCED_TIMBRES": 1, "NUM_VOICES": 32, "filter_enable": 0}},
              "stimulus": {"sample_hz": FS, "frequencies_hz": [400, 6000], "amplitude": 30000,
                           "coefficient_settle_samples": 2200, "tone_warmup_samples": 9375,
                           "tone_measured_samples": 9375, "separate_files_and_runs": True},
              "limitations": ["Only RTL simulation and calculated production tick frequency; no physical audio or 6Hz measurement.",
                              "No Gowin synthesis, place/route, timing closure, programming, publishing, DAC or analog validation.",
                              "Standalone hub sample_tick is accelerated without skipping sample counts; UART preserves 864 clocks per bit.",
                              "Filter DC full-scale tests concern audio_cleanup; the full instrument intentionally contains a DC blocker.",
                              "Current-tree PASS additionally requires all snapshotted inputs unchanged at completion."]}
    started = time.monotonic()

    def save():
        content = json.dumps(report, ensure_ascii=False, indent=2)+"\n"
        (run / "report.json").write_text(content, encoding="utf-8")
        destination.write_text(content, encoding="utf-8")

    try:
        if not iv.is_file() or not vvp.is_file():
            raise FileNotFoundError("Offline Icarus compiler/runtime missing")
        sources = sorted(p for p in (ROOT / "src").rglob("*") if p.is_file() and p.suffix.lower() in {".v", ".vh", ".hex"})
        sources += [ROOT / BENCH, ROOT / SCRIPT]
        for source in sources:
            relative = source.relative_to(ROOT)
            content = source.read_bytes()
            report["sources_sha256"][relative.as_posix()] = hashlib.sha256(content).hexdigest()
            target = snapshot / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        report["connection_review"] = connection_review(snapshot)
        report["runtime"] = {"iverilog": str(iv), "vvp": str(vvp),
                             "iverilog_sha256": sha(iv), "vvp_sha256": sha(vvp),
                             "version": execute([iv, "-V"], snapshot, run / "runtime_version.log", 15)}
        for frequency in [400, 6000]:
            content = "".join(f"{round(30000*math.sin(2*math.pi*frequency*n/FS)) & 65535:04x}\n" for n in range(9375))
            path = snapshot / f"sine_{frequency}.hex"
            path.write_text(content, encoding="ascii")
            report["stimulus"][f"sine_{frequency}_sha256"] = sha(path)
        save()

        def test(name):
            directory = run / name
            directory.mkdir()
            # Each simulator owns its output working directory. ROMs remain frozen.
            shutil.copytree(snapshot / "src", directory / "src")
            for f in [400, 6000]:
                shutil.copy2(snapshot / f"sine_{f}.hex", directory / f"sine_{f}.hex")
            image = directory / (name+".vvp")
            result = {"name": name, "status": "FAIL", "directory": str(directory)}
            rtl = sorted((snapshot / "src").glob("*.v"))
            result["compile"] = execute([iv, "-g2012", "-Wall", "-Wno-timescale", "-s", name, "-o", image,
                                         snapshot / BENCH, *rtl], directory, directory / "compile.log", args.timeout)
            if result["compile"].get("returncode") != 0:
                return result
            result["simulation"] = execute([vvp, image], directory, directory / "simulation.log", args.timeout)
            output = result["simulation"]["stdout"]+result["simulation"]["stderr"]
            result["coverage"] = re.findall(r"^PRESSURE_CASE_PASS (.+)$", output, re.MULTILINE)
            result["coverage_case_count"] = len(result["coverage"])
            result["counts"] = {key: int(value) for key, value in
                                re.findall(r"\b(checked_samples|checks|frames)=(\d+)", output)}
            marker = name.removeprefix("tb_").upper()+"_TEST_PASS"
            if result["simulation"].get("returncode") != 0 or marker not in output or FAILURE.search(output):
                return result
            try:
                if name == CASES[0]:result["measurements"] = filter_analysis(directory / "filter_pcm.csv")
                if name == CASES[2]:result["measurements"] = integration_analysis(directory / "instrument_pcm.csv")
                result["status"] = "PASS"
            except Exception as exc:
                result["analysis_error"] = repr(exc)
            result["artifacts_sha256"] = {p.name: sha(p) for p in directory.iterdir() if p.is_file()}
            return result

        with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
            jobs = {pool.submit(test, name): name for name in chosen}
            for job in as_completed(jobs):
                item = job.result();report["tests"].append(item)
                print(item["name"], item["status"], flush=True)
                if item["status"] != "PASS":
                    print(item.get("analysis_error", ""), flush=True)
                    phase = item.get("simulation", item.get("compile", {}))
                    print((phase.get("stdout", "")+phase.get("stderr", ""))[-6000:], flush=True)
                save()
        report["tests"].sort(key=lambda r: CASES.index(r["name"]))
        report["changed_sources"] = [name for name, value in report["sources_sha256"].items()
                                     if not (ROOT/name).is_file() or sha(ROOT/name) != value]
        report["sources_unchanged"] = not report["changed_sources"]
        report["snapshot_tests_pass"] = all(t["status"] == "PASS" for t in report["tests"])
        report["summary"] = {"test_groups": len(report["tests"]),
                             "passed_groups": sum(t["status"] == "PASS" for t in report["tests"]),
                             "coverage_cases": sum(t.get("coverage_case_count", 0) for t in report["tests"]),
                             "connection_review_checks": len(report["connection_review"]["checks"]),
                             "counts_by_group": {t["name"]: t.get("counts", {}) for t in report["tests"]}}
        report["stable_source_manifest_sha256"] = hashlib.sha256(
            json.dumps(report["sources_sha256"], sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        if report["snapshot_tests_pass"]:
            report["status"] = "PASS" if report["sources_unchanged"] else "PASS_SNAPSHOT_SOURCE_CHANGED"
        else:
            report["status"] = "FAIL"
            report["bugs"] = [{"test": t["name"], "kind": "requires_triage_RTL_or_test",
                               "evidence": t.get("analysis_error") or t.get("simulation", t["compile"])}
                              for t in report["tests"] if t["status"] != "PASS"]
    except Exception as exc:
        report["status"] = "FAIL"
        report["error"] = repr(exc)
    report["elapsed_seconds"] = round(time.monotonic()-started, 3)
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    save()
    print("PRESSURE_AUDIO_AGENT_"+report["status"], str(destination), flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
