"""V021短定向UART abort/渐入恢复回归；只写系统临时目录中的快照和日志。

生产RTL不变。默认仅在测试实例将音频核设为最小合法2声部，完整32声部由主集成覆盖；
控制器仍请求32、门控ffffffff。UART=864clk/bit，音频=288clk/tick，无force。
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
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
CASES = {"abort_cc120": 0, "abort_ff": 1, "abort_active_sense": 2}
for phase, offset in [("start", 3), ("mid", 8)]:
    for index, event in enumerate(["note", "kick", "snare", "closed_hat", "open_hat"]):
        CASES[f"ramp_{phase}_{event}"] = offset + index
BENCH = "tests/tb_v021_test_abort.v"
FAILURE = re.compile(r"(?im)^\s*(?:FATAL:|ERROR:)|\b\w*_TEST_FAIL\b")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def command(argv, work, label, timeout, env):
    started = time.monotonic()
    record = {"argv": [str(item) for item in argv], "cwd": str(work), "timeout_seconds": timeout}
    with (work / f"{label}.log").open("wb") as log:
        proc = subprocess.Popen(record["argv"], cwd=work, env=env, stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT)
        try:
            proc.wait(timeout=timeout)
            record["timed_out"] = False
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                               capture_output=True, timeout=15)
            else:
                proc.kill()
            proc.wait(timeout=15)
            record["timed_out"] = True
    record.update(returncode=proc.returncode, elapsed_seconds=round(time.monotonic()-started, 3))
    write_json(work / f"{label}.command.json", record)
    return record, (work / f"{label}.log").read_text(encoding="utf-8", errors="replace")


def run_case(name, snapshot, run, hashes, iv, vvp, voices, timeout, env):
    work = run / name
    work.mkdir()
    started = time.monotonic()
    result = {"status": "FAIL", "directory": str(work), "commands": []}
    try:
        shutil.copytree(snapshot / "src", work / "src")
        (work / "tests").mkdir()
        shutil.copyfile(snapshot / BENCH, work / BENCH)
        top = "tb_v021_test_abort"
        flags = ["-g2012", "-I", str(work), "-s", top, "-o", "simulation.vvp",
                 "-P", f"{top}.CASE={CASES[name]}", "-P", f"{top}.SHORT_VOICES={voices}"]
        rtl = sorted(str(p.relative_to(work)) for p in (work / "src").glob("*.v"))
        record, output = command([iv, *flags, *rtl, BENCH], work, "compile", 60, env)
        result["commands"].append(record)
        if record["returncode"] != 0 or record["timed_out"]:
            raise RuntimeError("Icarus compile failed: " + output[-3500:])
        record, output = command([vvp, "-i", "-n", "simulation.vvp"], work, "simulate", timeout, env)
        result["commands"].append(record)
        if record["returncode"] != 0 or record["timed_out"] or FAILURE.search(output) or "V021_ABORT_TEST_PASS" not in output:
            raise RuntimeError("Simulation failed: " + output[-3500:])
        changed = [item for item, digest in hashes.items()
                   if item != "scripts/run_v021_abort_tests.py" and sha(work / item) != digest]
        if changed:
            raise RuntimeError("Private case inputs changed: " + repr(changed))
        result.update(status="PASS", input_hashes_verified=True,
                      markers=[line for line in output.splitlines() if "V021_ABORT_TEST_PASS" in line])
    except Exception as exc:
        result["reason"] = str(exc)
    result["elapsed_seconds"] = round(time.monotonic()-started, 3)
    write_json(work / "result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--voices", type=int, choices=[2, 32], default=2)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    if args.list:
        print("\n".join(CASES))
        return 0
    if args.jobs<1 or args.timeout<=0:
        parser.error("jobs and timeout must be positive")
    suffix = ".exe" if os.name == "nt" else ""
    runtime = ROOT / "tools/vendor/iverilog-v12/app/bin"
    iv, vvp = runtime / ("iverilog"+suffix), runtime / ("vvp"+suffix)
    if not iv.is_file() or not vvp.is_file():
        parser.error("Existing local Icarus runtime was not found; no tool will be installed")
    parent = args.output or Path(tempfile.gettempdir()) / "gowin_v021_abort"
    run = parent.resolve() / (datetime.now().strftime("run_%Y%m%d_%H%M%S_%f")+f"_{os.getpid()}")
    snapshot = run / "snapshot"
    snapshot.mkdir(parents=True)
    inputs = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "src").rglob("*")
                    if p.is_file() and p.suffix.lower() in {".v", ".vh", ".hex"})
    inputs += [BENCH, "scripts/run_v021_abort_tests.py"]
    hashes = {}
    for item in inputs:
        dest = snapshot / item
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes((ROOT / item).read_bytes())
        hashes[item] = sha(dest)
    report = {"status": "RUNNING", "started_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "13 directed UART abort/fade-in cases only; no synthesis or hardware",
              "contract": {"control_test_voices": args.voices, "production_voices_unchanged": 32,
                           "full32_coverage": "separate main integration, not claimed by reduced cases",
                           "uart_clocks_per_bit": 864, "audio_clocks_per_tick": 288,
                           "active_sense_ms": 1, "test_ramp_div": 1, "test_hold_samples": 4,
                           "force_used": False, "ui_stimulus": "audio_top public ui_test_keys"},
              "project": str(ROOT), "source_hashes": hashes,
              "iverilog": {"path": str(iv), "sha256": sha(iv)},
              "vvp": {"path": str(vvp), "sha256": sha(vvp)}, "tests": {}}
    write_json(run / "results.json", report)
    print(f"RUN_DIRECTORY {run}\nCONTROL_VOICES {args.voices}; production RTL remains 32", flush=True)
    env = os.environ.copy()
    env["PATH"] = str(runtime) + os.pathsep + env.get("PATH", "")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_case, name, snapshot, run, hashes, iv, vvp, args.voices, args.timeout, env): name
                   for name in dict.fromkeys(args.case or CASES)}
        for future in as_completed(futures):
            name = futures[future]
            result = future.result()
            report["tests"][name] = result
            print(f"{result['status']} {name}"+(" "+result["reason"] if "reason" in result else ""), flush=True)
            write_json(run / "results.json", report)
    report["snapshot_hashes_verified"] = all(sha(snapshot / p)==digest for p,digest in hashes.items())
    report["live_files_changed_since_snapshot"] = [p for p,digest in hashes.items() if sha(ROOT / p)!=digest]
    report["status"] = "PASS" if report["snapshot_hashes_verified"] and not report["live_files_changed_since_snapshot"] and all(
        item["status"]=="PASS" for item in report["tests"].values()) else "FAIL"
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    write_json(run / "results.json", report)
    print(f"RESULT {run / 'results.json'}\nV021_ABORT_SUITE_{report['status']}", flush=True)
    return 0 if report["status"]=="PASS" else 1


if __name__=="__main__":
    raise SystemExit(main())
