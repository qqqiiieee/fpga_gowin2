"""使用工程Icarus运行触摸独立测试，仅写指定报告，编译中间产物存于临时目录。"""
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
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ["src/mcp3208_reader.v", "src/analog_touch_keypad.v", "src/touch_centers.hex",
           "assets/touch_calibration.json", "scripts/generate_touch_centers.py",
           "tests/tb_mcp3208_reader.v", "tests/tb_analog_touch_keypad.v", "scripts/run_touch_unit_tests.py"]
DATASHEET = "https://ww1.microchip.com/downloads/aemDocuments/documents/APID/ProductDocuments/DataSheets/21298e.pdf"


def run_command(argv, cwd, timeout):
    started = time.monotonic()
    record = {"argv": [str(x) for x in argv], "timeout_seconds": timeout}
    try:
        proc = subprocess.run(record["argv"], cwd=cwd, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=timeout)
        record.update(returncode=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)
    except subprocess.TimeoutExpired as exc:
        def readable(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
        record.update(returncode=None, timed_out=True, stdout=readable(exc.stdout), stderr=readable(exc.stderr))
    except OSError as exc:
        record.update(returncode=None, error=str(exc))
    record["elapsed_seconds"] = round(time.monotonic() - started, 3)
    return record


def generator_checks(snapshot):
    # 直接执行已快照脚本，避免在共享工程写__pycache__；使用最少字段的host JSON。
    namespace = {"__name__": "touch_generator_checks", "__file__": str(snapshot / "scripts/generate_touch_centers.py")}
    exec(compile((snapshot / "scripts/generate_touch_centers.py").read_text(encoding="utf-8"),
                 namespace["__file__"], "exec"), namespace)
    validate = namespace["validate"]
    row = namespace["ROW_MAJOR"]
    defaults = namespace["reference_defaults"]()
    checked = 0
    def expect_error(data):
        nonlocal checked
        try:
            validate(data)
        except ValueError:
            checked += 1
        else:
            raise AssertionError("Invalid calibration accepted")
    for data in [defaults, {"centers": [8+12*i for i in range(16)], "row_major_keys": row},
                 {"centers": [x//2 for x in defaults["centers"]][::-1], "row_major_keys": row},
                 {"centers": [4094-12*i for i in range(16)], "row_major_keys": row}]:
        assert len(validate(data)) == 16
        checked += 1
    for bad in [0, 7, 4095, -1, 4096, 8.0, True]:
        values = defaults["centers"][:]
        values[0] = bad
        expect_error({"centers": values, "row_major_keys": row})
    for offset in [0, 1, 11]:
        values = defaults["centers"][:]
        values[1] = values[0]+offset
        expect_error({"centers": values, "row_major_keys": row})
    expect_error({"centers": defaults["centers"][:-1], "row_major_keys": row})
    expect_error({"centers": defaults["centers"], "row_major_keys": row[::-1]})
    # CLI真正读入只有16中心和顺序的实测JSON，两个别名都生成相同hex。
    measured = {"centers": [8+12*i for i in range(16)], "row_major_keys": row}
    measured_path = snapshot / "measured.json"
    measured_path.write_text(json.dumps(measured), encoding="utf-8")
    commands = []
    for alias in ["--source", "--calibration"]:
        command = run_command([sys.executable, snapshot / "scripts/generate_touch_centers.py", alias,
                               measured_path, "--output", snapshot / "measured.hex"], snapshot, 10)
        commands.append(command)
        assert command["returncode"] == 0, command
        assert (snapshot / "measured.hex").read_text() == namespace["render_hex"](measured)
        checked += 1
    command = run_command([sys.executable, snapshot / "scripts/generate_touch_centers.py", "--check"], snapshot, 10)
    commands.append(command)
    assert command["returncode"] == 0, command
    checked += 1
    return {"name": "calibration_generator", "status": "pass", "checks": checked, "commands": commands}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=ROOT / "validation/touch_driver_agent.json")
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--workers", type=int, default=3)
    args = parser.parse_args()
    runtime = ROOT / "tools/vendor/iverilog-v12/app/bin"
    suffix = ".exe" if os.name == "nt" else ""
    iverilog, vvp = runtime / ("iverilog"+suffix), runtime / ("vvp"+suffix)
    # Cloud Linux uses the distribution Icarus; bundled Windows binaries are excluded.
    if os.name != "nt":
        iverilog = Path(os.environ.get("IVERILOG") or shutil.which("iverilog") or "/missing/iverilog")
        vvp = Path(os.environ.get("VVP") or shutil.which("vvp") or "/missing/vvp")
    report = {"status": "fail", "started_utc": datetime.now(timezone.utc).isoformat(),
              "project": str(ROOT), "tests": [], "sources_sha256": {},
              "hardware_tested": False, "programmed_or_published": False,
              "timing_source": {"url": DATASHEET, "document": "DS21298E", "page": 21,
                                "sections": ["5", "6.1", "Figure 6-1"],
                                "spi_mode": 0, "tx": "00000,1,1,D2,D1,D0,14 zeros",
                                "capture_rising_edges": [13, 24]},
              "integration_contract": {"row_major_keys": ["1","2","3","A","4","5","6","B","7","8","9","C","*","0","#","D"],
                                       "touch_processing_cycles_including_capture": 34,
                                       "poll_definition": "start_to_start_minimum",
                                       "sclk_hz_at_default": 500000, "poll_hz_at_5400": 5000,
                                       "idle_raw_below": 4, "center_range": [8,4094],
                                       "minimum_valid_gap": 12, "ambiguity_margin": 2,
                                       "window": "max(2,min(32,nearest_gap>>2)); idle0 participates in gap",
                                       "cal_write_priority": "cancel current frame, release and clear debounce even on commit cycle",
                                       "valid": "one clock pulse for completed nonambiguous sample, including idle/debounce",
                                       "fault": "latched latest stale/invalid/ambiguous/overrun diagnostic; fresh valid judgment clears"},
              "limitations": ["Default centers are estimates, not hardware measurements; runtime calibration is required.",
                              "A fixed disconnected analog level inside a valid window cannot be distinguished from a held key.",
                              "No ADC presence detection or protocol acknowledgement exists.",
                              "No synthesis/resource/physical verification is claimed by this unit-test report."]}
    started = time.monotonic()
    try:
        if not iverilog.is_file() or not vvp.is_file():
            raise FileNotFoundError("Project Icarus runtime missing")
        with tempfile.TemporaryDirectory(prefix="touch_unit_") as folder:
            snapshot = Path(folder)
            for relative in SOURCES:
                source = ROOT / relative
                content = source.read_bytes()
                report["sources_sha256"][relative] = hashlib.sha256(content).hexdigest()
                target = snapshot / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
            report["runtime"] = {
                "iverilog": str(iverilog), "vvp": str(vvp),
                "iverilog_sha256": hashlib.sha256(iverilog.read_bytes()).hexdigest(),
                "vvp_sha256": hashlib.sha256(vvp.read_bytes()).hexdigest(),
                "iverilog_version": run_command([iverilog, "-V"], snapshot, 10),
                "vvp_version": run_command([vvp, "-V"], snapshot, 10)}
            report["tests"].append(generator_checks(snapshot))
            cases = [
                ("spi_default_1khz", "tb_mcp3208_reader", "mcp3208_reader", {"TEST_POLL":27000}),
                ("spi_production_5khz", "tb_mcp3208_reader", "mcp3208_reader", {"TEST_POLL":5400}),
                ("spi_all_12bit_ch0_ch7", "tb_mcp3208_reader", "mcp3208_reader",
                 {"TEST_DIV":1,"TEST_POLL":1,"EXHAUSTIVE":1}),
                ("touch_stable_3", "tb_analog_touch_keypad", "analog_touch_keypad", {"TEST_STABLE":3}),
                ("touch_stable_1", "tb_analog_touch_keypad", "analog_touch_keypad", {"TEST_STABLE":1}),
                ("touch_stable_5", "tb_analog_touch_keypad", "analog_touch_keypad", {"TEST_STABLE":5}),
            ]
            def run_case(case):
                name, top, rtl, params = case
                output = snapshot / (name+".vvp")
                argv = [iverilog,"-g2012","-Wall","-s",top,"-o",output]
                argv += [f"-P{top}.{key}={value}" for key,value in params.items()]
                argv += [snapshot / f"src/{rtl}.v", snapshot / f"tests/{top}.v"]
                compiled = run_command(argv, snapshot, args.timeout)
                result = {"name":name, "parameters":params, "compile":compiled, "status":"fail"}
                if compiled["returncode"] == 0:
                    simulated = run_command([vvp,output], snapshot, args.timeout)
                    result["simulation"] = simulated
                    marker = rtl.upper()+"_TEST_PASS"
                    stdout = simulated.get("stdout") or ""
                    if simulated["returncode"] == 0 and marker in stdout and not re.search(r"(?im)^\s*(ERROR:|FATAL:)", stdout):
                        result["status"] = "pass"
                    result["pass_marker"] = marker
                print(f"{name}: {result['status']}", flush=True)
                return result
            with ThreadPoolExecutor(max_workers=max(1,args.workers)) as pool:
                report["tests"].extend(pool.map(run_case,cases))
            changed = [relative for relative,sha in report["sources_sha256"].items()
                       if hashlib.sha256((ROOT/relative).read_bytes()).hexdigest() != sha]
            report["sources_changed_during_run"] = changed
            report["status"] = "pass" if not changed and all(test["status"]=="pass" for test in report["tests"]) else "fail"
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
    report["elapsed_seconds"] = round(time.monotonic()-started,3)
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"status":report["status"],"report":str(args.report),
                      "tests":len(report["tests"]),"elapsed_seconds":report["elapsed_seconds"]},ensure_ascii=False))
    return 0 if report["status"]=="pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
