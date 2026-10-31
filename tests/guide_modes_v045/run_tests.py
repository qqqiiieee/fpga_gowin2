"""Isolated Icarus simulation only. All outputs stay in this NEW test directory.

No Gowin/Vivado synthesis, P&R, programming, downloads, UART or production edits.
Input snapshots make results reviewable while another agent edits production.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DEFAULT_TOOLS = Path("D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin")
SOURCES = ["src/guide_play_modes.v", "src/piano_roll_guide.v", "src/piano_roll_score.v", "src/custom_score_ram.v"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool-dir", type=Path, default=DEFAULT_TOOLS)
    args = parser.parse_args()
    tools = args.tool_dir.resolve()
    for name in ("iverilog.exe", "vvp.exe"):
        if not (tools / name).is_file():
            raise SystemExit(f"Missing {tools / name}; specify --tool-dir")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    out = HERE / "results" / stamp
    snapshot = out / "snapshot"
    snapshot.mkdir(parents=True)
    inputs = SOURCES + [str(p.relative_to(ROOT)) for p in sorted(HERE.glob("tb_*.v"))]
    inputs += [str(Path(__file__).resolve().relative_to(ROOT))]
    hashes = {}
    for relative in inputs:
        source = ROOT / relative
        data = source.read_bytes()
        dest = snapshot / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        hashes[relative] = hashlib.sha256(data).hexdigest()
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""))
    cases = [("unit", "tb_guide_play_modes", {}, SOURCES[:1], "GUIDE_MODES_UNIT_PASS")]
    for beat in (64, 67):
        for mode in (0, 1, 2):
            cases.append((f"timeline_b{beat}_m{mode}", "tb_guide_modes_timeline",
                          {"BEAT_SAMPLES": beat, "RUN_MODE": mode}, SOURCES,
                          "GUIDE_MODES_TIMELINE_PASS"))
    for mode in (1, 2):
        cases.append((f"custom_m{mode}", "tb_guide_modes_custom", {"RUN_MODE": mode},
                      SOURCES, "GUIDE_MODES_CUSTOM_PASS"))

    def execute(label, argv):
        try:
            result = subprocess.run(list(map(str, argv)), cwd=snapshot, env=env,
                                    capture_output=True, text=True, encoding="utf-8",
                                    errors="replace", timeout=60)
            log, code = result.stdout + result.stderr, result.returncode
        except subprocess.TimeoutExpired as exc:
            log, code = f"TIMEOUT after 60s: {exc}", None
        (out / f"{label}.log").write_text(log, encoding="utf-8")
        return {"exit_code": code, "log": f"{label}.log", "argv": list(map(str, argv))}, log

    def test(case):
        name, top, params, sources, marker = case
        binary = out / f"{name}.vvp"
        compile_result, log = execute(name + "_compile", [tools / "iverilog.exe", "-g2012", "-Wall",
            "-s", top, *[f"-P{top}.{key}={value}" for key, value in params.items()],
            "-o", binary, *sources, f"tests/guide_modes_v045/{top}.v"])
        record = {"name": name, "compile": compile_result, "passed": False}
        if compile_result["exit_code"] == 0:
            run, log = execute(name, [tools / "vvp.exe", binary])
            record["simulation"] = run
            record["passed"] = run["exit_code"] == 0 and marker in log and "FATAL:" not in log
            record["metrics"] = [line for line in log.splitlines() if "_PASS" in line]
        print(f"{name}: {'PASS' if record['passed'] else 'FAIL'}", flush=True)
        if not record["passed"]:
            print(log[-2500:], flush=True)
        return record

    with ThreadPoolExecutor(max_workers=3) as pool:
        records = list(pool.map(test, cases))
    changed = [p for p, old in hashes.items() if hashlib.sha256((ROOT / p).read_bytes()).hexdigest() != old]
    report = {"passed": all(r["passed"] for r in records), "utc": stamp,
              "source_sha256": hashes, "inputs_changed_during_run": changed,
              "tests": records, "fpga_compiled": False, "flashed": False,
              "hardware_tested": False, "production_integration_performed": False,
              "tool_dir": str(tools), "results_directory": str(out)}
    text = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    (out / "report.json").write_text(text, encoding="utf-8")
    (HERE / "latest_report.json").write_text(text, encoding="utf-8")
    print(f"Report: {out / 'report.json'}", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
