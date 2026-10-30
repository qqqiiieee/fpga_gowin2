"""Run only optical/player Icarus tests; shared-tree write is optical_agent.json.

Compile products and immutable source snapshots live in a system temp directory.
No firmware build, publish, main sources, or another worker's report is touched.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FILES = ["src/optical_strum.v", "src/strum_player.v", "tests/tb_optical_strum.v",
         "tests/tb_strum_player.v", "scripts/run_optical_tests.py"]
REPORT = ROOT / "validation/optical_agent.json"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(argv, cwd, timeout):
    record = {"argv": [str(x) for x in argv]}
    start = time.monotonic()
    try:
        proc = subprocess.run(record["argv"], cwd=cwd, capture_output=True,
                              text=True, encoding="utf-8", errors="replace", timeout=timeout)
        record.update(returncode=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)
    except subprocess.TimeoutExpired as exc:
        def decode(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
        record.update(returncode=None, timed_out=True, stdout=decode(exc.stdout), stderr=decode(exc.stderr))
    except OSError as exc:
        record.update(returncode=None, error=str(exc))
    record["elapsed_seconds"] = round(time.monotonic() - start, 3)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--workers", type=int, default=4)
    args = parser.parse_args()
    suffix = ".exe" if os.name == "nt" else ""
    runtime = ROOT / "tools/vendor/iverilog-v12/app/bin"
    iverilog, vvp = runtime / ("iverilog" + suffix), runtime / ("vvp" + suffix)
    report = {
        "schema_version": 1, "status": "fail", "source_stable": False,
        "started_utc": datetime.now(timezone.utc).isoformat(), "project": str(ROOT),
        "scope": "Independent Icarus optical_strum/strum_player tests only",
        "tests": [], "sources_sha256": {}, "hardware_tested": False,
        "full_build_performed": False, "programmed_or_published": False,
        "sensor_reference": {
            "url": "https://www.dfrobot.com.cn/goods-3274.html",
            "verified_date": "2026-10-24", "model": "SEN0503",
            "supply_v": [3.0, 5.0], "range_at_3v3_cm": 20,
            "output": "NPN normally open; blocked HIGH/LOW not explicitly stated",
            "sensor_response_ms": 2,
            "project_wiring": "red 3V3, black GND, white OUT; each OUT external 10k to 3V3",
            "pullup_provenance": "project integration requirement, not a manufacturer resistance specification",
            "geometry": "two parallel beam pairs A/B spaced 3..5cm along hand travel"},
        "integration_contract": {
            "clock_hz": 27000000, "filter_cycles": 27000,
            "startup_stable_cycles": 5400000, "pair_window_cycles": 4050000,
            "beam_bits": "bit0=A, bit1=B; A then B ascending, B then A descending",
            "same_clock_edges": "reverse=0, velocity=180, gap_ms=6; no inferred direction",
            "pair_bins_ms_velocity_gap_ms": [[8,255,2],[20,220,4],[50,180,6],[150,140,10]],
            "single_fallback": "after full 150ms window: reverse=0, velocity=160, gap_ms=8",
            "player_tags_assigned_by_main": {"source": 2, "timbre": 1},
            "event_acceptance": "valid && ready && !suppress; main gates acceptance and clears voices in test mode",
            "max_notes": 6, "hold_ms_from_final_accepted_on": 150,
            "pending_trigger_depth": 1,
            "production_counter_width_bits": {"optical_filter_per_line": 15, "optical_startup": 23,
                                               "optical_pair_age": 22, "player_elapsed": 22,
                                               "player_gap": 19, "player_note_counts": 3},
            "suppression": "cancel pending gesture/playback; optical waits for both beams idle before arm"},
        "limitations": [
            "Boot with both optical paths unobstructed and stable for 200ms. A hand at boot learns the wrong idle; remove hand and RESET.",
            "Idle baseline is locked until reset; no continuous adaptation of long obstruction.",
            "Single-beam fallback has 150ms pairing latency plus sensor/filter delay; unused input needs a fixed pulled idle level.",
            "Physical sensor polarity, range, crosstalk, timing, FPGA synthesis/resources and main integration are not verified here.",
            "Synchronous trigger is one clock. Busy pending queue keeps only latest trigger; stalled accepted-event cleanup is never overwritten.",
            "Milliseconds ceil to clock cycles for CLK_HZ not divisible by 1000; one-slot player minimum transfer spacing is two clocks."
        ]}
    start = time.monotonic()
    try:
        if not iverilog.is_file() or not vvp.is_file():
            raise FileNotFoundError("Project Icarus runtime missing")
        with tempfile.TemporaryDirectory(prefix="optical_unit_") as folder:
            snapshot = Path(folder)
            for relative in FILES:
                dst = snapshot / relative
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, dst)
                report["sources_sha256"][relative] = digest(dst)
            report["tool_versions"] = [run([iverilog, "-V"], snapshot, 15),
                                       run([vvp, "-V"], snapshot, 15)]

            def case(spec):
                top, production = spec
                name = top + ("_production" if production else "_scaled")
                image = snapshot / (name + ".vvp")
                module = top.removeprefix("tb_")
                compile_result = run([iverilog, "-g2012", "-Wall", "-s", top,
                                      "-P", f"{top}.PRODUCTION={production}", "-o", image,
                                      snapshot / f"src/{module}.v", snapshot / f"tests/{top}.v"],
                                     snapshot, args.timeout)
                result = {"name": name, "production_parameters": bool(production),
                          "status": "fail", "compile": compile_result}
                if compile_result["returncode"] == 0:
                    sim = run([vvp, image], snapshot, args.timeout)
                    result["simulate"] = sim
                    pattern = rf"^PASS {top} {'production' if production else 'scaled'} checks=(\d+)"
                    match = re.search(pattern, sim.get("stdout") or "", re.MULTILINE)
                    if sim["returncode"] == 0 and match:
                        result.update(status="pass", checks=int(match[1]))
                return result

            specs = [(top, production) for top in ["tb_optical_strum", "tb_strum_player"]
                     for production in [0, 1]]
            with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
                report["tests"] = list(executor.map(case, specs))
            report["source_stable"] = all(digest(ROOT / p) == h
                                          for p, h in report["sources_sha256"].items())
            if report["source_stable"] and all(t["status"] == "pass" for t in report["tests"]):
                report["status"] = "pass"
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    report["elapsed_seconds"] = round(time.monotonic() - start, 3)
    REPORT.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for result in report["tests"]:
        print(f"{result['status'].upper()} {result['name']} checks={result.get('checks', 0)}")
        if result["status"] != "pass":
            print(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"{report['status'].upper()} report={REPORT} source_stable={report['source_stable']}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
