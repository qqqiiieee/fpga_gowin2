"""只读冻结oracle的Icarus ADSR/FSR回归；不综合、不写工程清单。

默认日志/不可变输入快照放系统临时目录，只在本机使用已有Icarus。
用法：python scripts/run_live_adsr_tests.py [--case adsr_ram] [--jobs 2]
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
CASES = {
    "adsr_ram": (0, 1, 0), "adsr_regs": (0, 0, 0),
    "damping_ram": (1, 1, 0), "damping_regs": (1, 0, 0),
    "test32_ram": (2, 1, 0), "test32_regs": (2, 0, 0),
    "default16_ram": (3, 1, 0), "default16_regs": (3, 0, 0),
    "boundary_negative_ram": (4, 1, 0), "boundary_positive_ram": (4, 1, 1),
    "nondual_damping_ram": (5, 1, 0),
    "legacy_dual": None,
}
INPUTS = [
    "src/wavetable_synth.v", "src/note_table.v", "src/oscillator_test_frequencies.v",
    "src/test_sine.hex", "src/timbre_soft.hex", "src/timbre_dual.hex", "src/timbre_dual_half.hex",
    "tests/tb_live_adsr.v", "tests/tb_dual_timbre_synth.v",
    "tests/fixtures/v016_wavetable_synth_reference.v",
]
FAILURE = re.compile(r"(?im)^\s*(?:FATAL:|ERROR:)|\b\w*_TEST_FAIL\b")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def find_tool(explicit, name, project):
    # 与run_iverilog_tests.py相同的本机vendor优先查找，不修改PATH/不安装工具。
    executable = name + (".exe" if os.name == "nt" else "")
    if explicit:
        candidate = explicit.expanduser().resolve()
        if candidate.is_dir():
            candidate /= executable
        if not candidate.is_file():
            raise FileNotFoundError(candidate)
        return candidate
    candidates = [project / "tools/vendor/iverilog-v12/app/bin" / executable]
    candidates += sorted((project / "tools/vendor").glob(f"*/bin/{executable}"))
    candidates += sorted((project / "tools/vendor").glob(f"*/app/bin/{executable}"))
    if shutil.which(name):
        candidates.append(Path(shutil.which(name)))
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise FileNotFoundError(f"No {name}; pass --{name}. No tool is installed automatically.")


def command(argv, cwd, label, timeout, env):
    argv = [str(item) for item in argv]
    started = time.monotonic()
    record = {"argv": argv, "cwd": str(cwd), "timeout_seconds": timeout}
    with (cwd / (label + ".log")).open("wb") as log:
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL)
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
    record.update(returncode=proc.returncode, elapsed_seconds=round(time.monotonic() - started, 3))
    write_json(cwd / (label + ".command.json"), record)
    return record, (cwd / (label + ".log")).read_text(encoding="utf-8", errors="replace")


def run_case(name, snapshot, output, iv, vvp, timeout, env):
    started = time.monotonic()
    work = output / name
    work.mkdir()
    result = {"status": "FAIL", "directory": str(work), "commands": []}
    try:
        for item in INPUTS:
            dest = work / item
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(snapshot / item, dest)
        params = CASES[name]
        top = "tb_dual_timbre_synth" if params is None else "tb_live_adsr"
        marker = "DUAL_TIMBRE_SYNTH_TEST_PASS" if params is None else "LIVE_ADSR_TEST_PASS"
        if params is not None:
            value = "7fff" if params[2] else "8000"
            # 常数极值ROM是独立算术夹具，不改生产ROM，不由DUT算法生成期望。
            for filename, count in [("boundary_dual.hex", 2048), ("boundary_legacy.hex", 16384)]:
                (work / filename).write_text((value + "\n") * count, encoding="ascii")
        hashes = {p.relative_to(work).as_posix(): sha(p) for p in work.rglob("*") if p.is_file()}
        write_json(work / "sourcehash.json", hashes)
        sources = ["src/wavetable_synth.v", "src/note_table.v", "src/oscillator_test_frequencies.v",
                   "tests/fixtures/v016_wavetable_synth_reference.v", f"tests/{top}.v"]
        flags = ["-g2012", "-s", top, "-o", "simulation.vvp"]
        if params is not None:
            for key, value in zip(["CASE", "PHASE_RAM", "BOUNDARY_POSITIVE"], params):
                flags += ["-P", f"{top}.{key}={value}"]
            if params[0] in (3, 5):
                flags += ["-P", f'{top}.WAVE="src/timbre_soft.hex"']
            elif params[0] == 4:
                flags += ["-P", f'{top}.WAVE="boundary_dual.hex"',
                          "-P", f'{top}.OLD_WAVE="boundary_legacy.hex"']
        record, text = command([iv, *flags, *sources], work, "compile", 60, env)
        result["commands"].append(record)
        if record["returncode"] != 0 or record["timed_out"]:
            raise RuntimeError("Icarus compile failed: " + text[-3000:])
        record, text = command([vvp, "-i", "-n", "simulation.vvp"], work, "simulate", timeout, env)
        result["commands"].append(record)
        if record["returncode"] != 0 or record["timed_out"] or FAILURE.search(text) or marker not in text:
            raise RuntimeError("Simulation failed: " + text[-3000:])
        if any(sha(work / item) != digest for item, digest in hashes.items()):
            raise RuntimeError("Private test input changed during simulation")
        result.update(status="PASS", marker=[line for line in text.splitlines() if marker in line],
                      input_hashes_verified=True)
    except Exception as exc:
        result["reason"] = str(exc)
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    write_json(work / "result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--iverilog", type=Path)
    parser.add_argument("--vvp", type=Path)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--output", type=Path, help="New run parent; defaults to system temp")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    if args.list:
        print("\n".join(CASES))
        return 0
    if args.jobs < 1 or args.timeout <= 0:
        parser.error("jobs and timeout must be positive")
    project = args.project.resolve()
    iv = find_tool(args.iverilog, "iverilog", project)
    sibling = iv.parent / ("vvp.exe" if os.name == "nt" else "vvp")
    vvp = find_tool(args.vvp or sibling, "vvp", project)
    parent = (args.output or Path(tempfile.gettempdir()) / "gowin_live_adsr").resolve()
    run = parent / (datetime.now().strftime("run_%Y%m%d_%H%M%S_%f") + f"_{os.getpid()}")
    snapshot = run / "snapshot"
    snapshot.mkdir(parents=True)
    hashes = {}
    for item in [*INPUTS, "scripts/run_live_adsr_tests.py"]:
        dest = snapshot / item
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes((project / item).read_bytes())
        hashes[item] = sha(dest)
    report = {"status": "RUNNING", "started_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "RTL simulation only; no synthesis or hardware", "project": str(project),
              "source_hashes": hashes, "iverilog": str(iv), "vvp": str(vvp), "tests": {}}
    write_json(run / "results.json", report)
    print(f"RUN_DIRECTORY {run}", flush=True)
    env = os.environ.copy()
    env["PATH"] = str(iv.parent) + os.pathsep + str(vvp.parent) + os.pathsep + env.get("PATH", "")
    selected = args.case or list(CASES)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_case, name, snapshot, run, iv, vvp, args.timeout, env): name
                   for name in dict.fromkeys(selected)}
        for future in as_completed(futures):
            name = futures[future]
            result = future.result()
            report["tests"][name] = result
            print(f"{result['status']} {name}" + (" " + result["reason"] if "reason" in result else ""), flush=True)
            write_json(run / "results.json", report)
    report["snapshot_hashes_verified"] = all(sha(snapshot / item) == digest for item, digest in hashes.items())
    report["live_files_changed_since_snapshot"] = [item for item, digest in hashes.items()
                                                   if sha(project / item) != digest]
    report["status"] = "PASS" if report["snapshot_hashes_verified"] and all(
        item["status"] == "PASS" for item in report["tests"].values()) else "FAIL"
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    write_json(run / "results.json", report)
    print(f"RESULT {run / 'results.json'}\nLIVE_ADSR_SUITE_{report['status']}", flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
