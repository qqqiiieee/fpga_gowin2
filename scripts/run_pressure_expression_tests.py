"""Standalone offline pressure_expression tests; no Gowin/build/flash operations.

Only validation/pressure_expression_agent.json and the dedicated
validation/pressure_expression_tests/ tree are written. RTL, benches and this
runner are snapshotted before testing and hashed again after all simulations.
Use --list or --case NAME to inspect/select cases; no third-party Python modules.
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
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "validation/pressure_expression_agent.json"
RUN_BASE = ROOT / "validation/pressure_expression_tests"
FROZEN_RTL_SHA256 = "5c89d20c29040db3ef93d7fc939dd6b9cec93418dc603c228851733df0e3c70c"
SOURCES = (
    "src/pressure_expression.v",
    "tests/tb_pressure_expression.v",
    "tests/pressure_expression/tb_pressure_expression_preflight.v",
    "scripts/run_pressure_expression_tests.py",
)
PRODUCTION = {"CAL_SAMPLES": 16, "DEAD_COUNT": 64, "SCALE_SHIFT": 4, "STALE_CYCLES": 6_750_000}


def case(name, *, cal=16, dead=64, shift=4, stale=128, mode=0):
    return {"name": name, "top": "tb_pressure_expression", "bench": SOURCES[1],
            "parameters": {"TEST_CAL_SAMPLES": cal, "TEST_DEAD_COUNT": dead,
                           "TEST_SCALE_SHIFT": shift, "TEST_STALE_CYCLES": stale, "MODE": mode},
            "marker": "PRESSURE_EXPRESSION_TEST_PASS"}


CASES = [
    {"name": "frozen_rtl_preflight", "top": "tb_pressure_expression_preflight",
     "bench": SOURCES[2], "parameters": {}, "marker": "PRESSURE_EXPRESSION_PREFLIGHT_PASS"},
    case("default_transfer_and_calibration"),
    case("calibration_one", cal=1),
    case("calibration_non_power_three", cal=3, stale=37),
    case("calibration_maximum_256", cal=256, stale=64),
    case("dead_zero_scale_zero", cal=3, dead=0, shift=0),
    case("dead_16_scale_one", cal=3, dead=16, shift=1),
    case("dead_128_scale_six", cal=3, dead=128, shift=6),
    case("stale_one", cal=1, stale=1, mode=1),
    case("stale_two", cal=3, stale=2, mode=1),
    case("stale_three_cal_256", cal=256, stale=3, mode=1),
    case("max_dead_and_shift", cal=256, dead=32767, shift=15, mode=3),
    case("maximum_shift_zero_dead", cal=1, dead=0, shift=15, mode=3),
    case("exhaustive_signed_adc_both_channels", cal=1, mode=4),
    case("unscaled_250ms_timeout", stale=6_750_000, mode=2),
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def command(argv, cwd, timeout, log_path):
    argv = [str(item) for item in argv]
    record = {"argv": argv, "command_line": subprocess.list2cmdline(argv),
              "cwd": str(cwd), "timeout_seconds": timeout,
              "started_utc": datetime.now(timezone.utc).isoformat(), "log": str(log_path)}
    start = time.monotonic()
    try:
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=timeout)
        record.update(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
    except subprocess.TimeoutExpired as exc:
        def as_text(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")
        record.update(returncode=None, timed_out=True, stdout=as_text(exc.stdout), stderr=as_text(exc.stderr))
    except OSError as exc:
        record.update(returncode=None, error=str(exc), stdout="", stderr="")
    record["elapsed_seconds"] = round(time.monotonic() - start, 6)
    write_json(log_path, record)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", dest="selected", choices=[x["name"] for x in CASES])
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--timeout", type=int, default=120, help="timeout per tool command in seconds")
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    if args.list:
        print("\n".join(item["name"] for item in CASES))
        return 0
    if args.timeout < 1 or args.jobs < 1:
        parser.error("--timeout and --jobs must be positive")
    chosen = [item for item in CASES if not args.selected or item["name"] in args.selected]
    now = datetime.now(timezone.utc)
    run_dir = RUN_BASE / (now.strftime("%Y%m%dT%H%M%S_%fZ_") + uuid.uuid4().hex[:8])
    snapshot = run_dir / "snapshot"
    logs = run_dir / "logs"
    run_dir.mkdir(parents=True, exist_ok=False)
    runtime = ROOT / "tools/vendor/iverilog-v12/app"
    suffix = ".exe" if os.name == "nt" else ""
    iverilog = runtime / "bin" / ("iverilog" + suffix)
    vvp = runtime / "bin" / ("vvp" + suffix)
    # Cloud Linux uses the distribution Icarus; bundled Windows binaries are excluded.
    if os.name != "nt":
        iverilog = Path(os.environ.get("IVERILOG") or shutil.which("iverilog") or "/missing/iverilog")
        vvp = Path(os.environ.get("VVP") or shutil.which("vvp") or "/missing/vvp")
    start = time.monotonic()
    report = {
        "status": "FAIL", "scope": "standalone offline RTL simulation only",
        "started_utc": now.isoformat(), "project": str(ROOT), "run_directory": str(run_dir),
        "invocation": {"argv": [sys.executable, *sys.argv], "cwd": str(Path.cwd())},
        "production_parameters": PRODUCTION, "source_files": list(SOURCES),
        "sources_sha256_before": {}, "sources_sha256_after": {}, "snapshot_sha256_after": {},
        "frozen_rtl_expected_sha256": FROZEN_RTL_SHA256, "tests": [], "syntax_checks": [],
        "requested_cases": [x["name"] for x in chosen], "full_suite_selected": len(chosen) == len(CASES),
        "hardware_tested": False, "gowin_build_performed": False, "programmed_or_published": False,
        "contract": {
            "ports": "clk,rst_n,ready,adc_valid,adc_channel[1:0],adc_data[15:0]; level0[7:0],level1[7:0],calibrated[1:0]",
            "calibration": "per-channel arithmetic mean, floor division; last calibration sample outputs zero",
            "default_mapping": "delta=max(signed-nonnegative raw-baseline,0); delta<=64 ->0; else min(255,delta>>4); 65->4,4080->255",
            "smoothing": "on own sample only, floor(abs(error)/4); residual <4 completed directly",
            "baseline": "no upward movement after calibration, including deadband; downward max(1,distance>>5) per sample",
            "stale": "independent per channel, exactly N missing clock edges; fresh own sample wins deadline",
            "ready": "ready=0 synchronously clears both; independent timers remain active while ready=1",
            "parameter_ranges": {"CAL_SAMPLES": [1, 256], "DEAD_COUNT": [0, 32767],
                                 "SCALE_SHIFT": [0, 15], "STALE_CYCLES": [1, 2147483647]},
        },
        "limitations": [
            "Offline digital samples only; no physical FSR, ADS1115, voltage/force or noise measurements.",
            "No Gowin synthesis, placement/routing, timing closure, UART/system/audio integration, publishing or programming in this report.",
            "Startup and recovery require the user to unload sensors; a held load during calibration becomes the new zero.",
            "Downward-only post-calibration baseline deliberately does not compensate upward resting drift; use ready/reset to recalibrate.",
            "Default deadband gate jumps from 0 at delta=64 to 4 at delta=65; codes 1..3 are transient smoothing values.",
            "The real 6750000-cycle timeout is simulated; most functional cases shorten this parameter explicitly.",
            "Parameter corner tests cover selected configurations, not the Cartesian product of all supported values.",
            "A valid but physically stuck ADC stream cannot be distinguished from steady pressure by this module.",
        ],
    }
    try:
        for relative in SOURCES:
            content = (ROOT / relative).read_bytes()
            report["sources_sha256_before"][relative] = hashlib.sha256(content).hexdigest()
            target = snapshot / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        if report["sources_sha256_before"][SOURCES[0]] != FROZEN_RTL_SHA256:
            raise RuntimeError("RTL differs from the agreed frozen source; review before rerunning")
        if not iverilog.is_file() or not vvp.is_file():
            raise FileNotFoundError("Bundled Icarus runtime is missing")
        # Hash the complete bundled runtime, including compiler backends, to
        # retain more than the small executable front end in the audit trail.
        report["runtime"] = {
            "iverilog": str(iverilog), "vvp": str(vvp),
            "files_sha256": ({path.relative_to(runtime).as_posix(): digest(path)
                              for path in sorted(runtime.rglob("*")) if path.is_file()}
                             if os.name == "nt" else
                             {"iverilog": digest(iverilog), "vvp": digest(vvp)}),
            "iverilog_version": command([iverilog, "-V"], run_dir, args.timeout, logs / "iverilog_version.json"),
            "vvp_version": command([vvp, "-V"], run_dir, args.timeout, logs / "vvp_version.json"),
        }
        syntax = command([iverilog, "-g2005", "-Wall", "-s", "pressure_expression", "-t", "null",
                          snapshot / SOURCES[0]], run_dir, args.timeout, logs / "rtl_verilog2005.json")
        report["syntax_checks"].append({"name": "rtl_verilog2005", "command": syntax,
                                        "status": "PASS" if syntax["returncode"] == 0 else "FAIL"})

        def run_case(item):
            name = item["name"]
            output = run_dir / (name + ".vvp")
            parameters = item["parameters"]
            result = {"name": name, "status": "FAIL", "parameters": parameters,
                      "pass_marker": item["marker"], "black_box_ports_only": True}
            if parameters:
                result["parameter_scaling"] = {
                    "cal_samples_vs_default": parameters["TEST_CAL_SAMPLES"] / PRODUCTION["CAL_SAMPLES"],
                    "stale_cycles_vs_default": parameters["TEST_STALE_CYCLES"] / PRODUCTION["STALE_CYCLES"],
                    "stale_ms_at_27mhz": parameters["TEST_STALE_CYCLES"] / 27000,
                    "dead_or_scale_changed": parameters["TEST_DEAD_COUNT"] != PRODUCTION["DEAD_COUNT"]
                                             or parameters["TEST_SCALE_SHIFT"] != PRODUCTION["SCALE_SHIFT"],
                    "clock_period_ns": 37.036, "timing_authority": "integer clock cycles; nominal 27MHz test clock",
                }
            argv = [iverilog, "-g2012", "-Wall", "-s", item["top"], "-o", output]
            argv += [f"-P{item['top']}.{key}={value}" for key, value in parameters.items()]
            argv += [snapshot / SOURCES[0], snapshot / item["bench"]]
            result["compile"] = command(argv, run_dir, args.timeout, logs / (name + "_compile.json"))
            if result["compile"]["returncode"] == 0:
                result["compiled_sha256"] = digest(output)
                simulated = command([vvp, output], run_dir, args.timeout, logs / (name + "_simulation.json"))
                result["simulation"] = simulated
                combined = simulated["stdout"] + simulated["stderr"]
                result["coverage_groups"] = re.findall(r"^GROUP_PASS (.+)$", simulated["stdout"], re.M)
                stats = re.search(r"PRESSURE_EXPRESSION_TEST_PASS checks=(\d+) groups=(\d+)", combined)
                if stats:
                    result["assertions"] = int(stats[1])
                    result["groups"] = int(stats[2])
                if (simulated["returncode"] == 0 and item["marker"] in combined
                        and not re.search(r"(?im)^\s*(FAIL\b|ERROR:|FATAL:)", combined)):
                    result["status"] = "PASS"
            print(f"{name}: {result['status']}", flush=True)
            return result

        with ThreadPoolExecutor(max_workers=min(args.jobs, len(chosen))) as executor:
            report["tests"] = list(executor.map(run_case, chosen))
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        for relative in report["sources_sha256_before"]:
            for base, field in [(ROOT, "sources_sha256_after"), (snapshot, "snapshot_sha256_after")]:
                path = base / relative
                report[field][relative] = digest(path) if path.is_file() else None
        report["sources_changed_during_run"] = [
            relative for relative, sha in report["sources_sha256_before"].items()
            if report["sources_sha256_after"].get(relative) != sha
            or report["snapshot_sha256_after"].get(relative) != sha]
        report["source_stable"] = (len(report["sources_sha256_before"]) == len(SOURCES)
                                   and not report["sources_changed_during_run"])
        report["frozen_rtl_matches"] = report["sources_sha256_after"].get(SOURCES[0]) == FROZEN_RTL_SHA256
        version_ok = bool(report.get("runtime")) and all(
            report["runtime"][key]["returncode"] == 0 for key in ["iverilog_version", "vvp_version"])
        if (not report.get("error") and version_ok and report["source_stable"] and report["frozen_rtl_matches"]
                and len(report["tests"]) == len(chosen) and all(x["status"] == "PASS" for x in report["tests"])
                and report["syntax_checks"] and all(x["status"] == "PASS" for x in report["syntax_checks"])):
            report["status"] = "PASS"
        report["assertions"] = sum(x.get("assertions", 0) for x in report["tests"])
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        report["elapsed_seconds"] = round(time.monotonic()-start, 3)
        write_json(run_dir / "report.json", report)
        write_json(REPORT, report)
    print(json.dumps({"status": report["status"], "tests": len(report["tests"]),
                      "assertions": report["assertions"], "source_stable": report["source_stable"],
                      "report": str(REPORT), "elapsed_seconds": report["elapsed_seconds"]}, ensure_ascii=False))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
