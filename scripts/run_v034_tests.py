"""Source-only V034 button/UART/hybrid regressions; never build or program hardware.

Each invocation freezes Verilog/includes/ROMs and this runner in a unique snapshot,
records SHA256 plus exact commands/logs, and checks for concurrent source edits.
HDMI is a passive test boundary. UART bit/optical/button timers are scaled;
these tests do not certify electrical timing, visible HDMI, or audible output.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time
from toolchain import find_icarus, ToolchainError

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=["buttons", "short", "phone", "hybrid"], action="append")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    if args.workers < 1 or args.timeout < 1:
        parser.error("--workers and --timeout must be positive")
    try:
        tools = find_icarus()
    except ToolchainError as exc:
        parser.error(str(exc))
    selected = args.case or ["buttons", "short", "phone", "hybrid"]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    out = ROOT / "validation/v034" / stamp
    snapshot = out / "snapshot"
    snapshot.mkdir(parents=True)
    inputs = sorted(p for d in ("src", "tests") for p in (ROOT / d).iterdir()
                    if p.is_file() and p.suffix in (".v", ".vh", ".hex"))
    inputs.append(Path(__file__).resolve())
    inputs.append(ROOT / "scripts/toolchain.py")
    before = {p.relative_to(ROOT).as_posix(): sha(p) for p in inputs}
    for path in inputs:
        target = snapshot / path.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    hashes = {name: sha(snapshot / name) for name in before}
    snapshot_consistent = hashes == before
    sources = sorted(p.relative_to(snapshot).as_posix() for p in (snapshot / "src").glob("*.v")
                     if not p.name.startswith(("hdmi_", "tmds_", "video_")))
    cases = []
    if "buttons" in selected:
        for db in (2, 5):
            cases.append((f"buttons_DB{db}", "tb_v034_buttons", [f"-Ptb_v034_buttons.DB={db}"],
                          ["src/four_button_display_control.v", "tests/tb_v034_buttons.v"], "V034_BUTTONS_PASS"))
    if "short" in selected:
        cases.append(("legacy_short", "tb_fourphone_buttons", [],
                      ["src/four_button_display_control.v", "tests/tb_fourphone_buttons.v"], "FOURPHONE_BUTTONS_PASS"))
    if "phone" in selected:
        cases.append(("top_phone", "tb_v034_top_phone", [], sources + ["tests/tb_v034_top_phone.v"], "V034_TOP_PHONE_PASS"))
    if "hybrid" in selected:
        cases.append(("hybrid_audio", "tb_v034_hybrid_audio", [], sources + ["tests/tb_v034_hybrid_audio.v"], "V034_HYBRID_AUDIO_PASS"))
    env = tools.environment()

    def run_case(case):
        name, top, params, files, marker = case
        result = {"name": name, "top": top, "passed": False, "marker": marker}
        exe = out / (name + ".vvp")
        commands = [("compile", [str(tools.iverilog), "-g2012", "-I", ".", "-I", "tests", "-s", top,
                                  *params, "-o", str(exe), *files]),
                    ("run", [str(tools.vvp), str(exe)])]
        for phase, argv in commands:
            started = time.monotonic()
            record = {"argv": argv, "cwd": str(snapshot)}
            try:
                proc = subprocess.run(argv, cwd=snapshot, env=env, capture_output=True, text=True,
                                      encoding="utf-8", errors="replace", timeout=args.timeout)
                record.update(exit_code=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)
            except subprocess.TimeoutExpired as exc:
                def decoded(value):
                    return value.decode("utf-8", "replace") if isinstance(value, bytes) else value or ""
                record.update(exit_code=None, timed_out=True, stdout=decoded(exc.stdout), stderr=decoded(exc.stderr))
            except OSError as exc:
                record.update(exit_code=None, stdout="", stderr=str(exc))
            record["elapsed_seconds"] = round(time.monotonic() - started, 3)
            result[phase] = record
            (out / f"{name}_{phase}.log").write_text(record["stdout"] + record["stderr"], encoding="utf-8")
            if record["exit_code"] != 0:
                break
        result["passed"] = ("run" in result and result["run"]["exit_code"] == 0
                            and marker in result["run"]["stdout"]
                            and not any(s in result["run"]["stdout"] + result["run"]["stderr"]
                                        for s in ("ERROR:", "FATAL:", "Unable to open")))
        print(name, "PASS" if result["passed"] else "FAIL", flush=True)
        if not result["passed"]:
            for phase in ("compile", "run"):
                if phase in result:
                    print(result[phase]["stdout"] + result[phase]["stderr"], flush=True)
        return result

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(run_case, cases))
    changed = [name for name, digest in hashes.items() if not (ROOT / name).is_file() or sha(ROOT / name) != digest]
    report = {"passed": all(r["passed"] for r in results) and snapshot_consistent and not changed,
              "project": str(ROOT), "snapshot": str(snapshot), "tools": tools.as_dict(), "snapshot_consistent": snapshot_consistent,
              "source_stable": not changed, "changed_since_snapshot": changed, "source_sha256": hashes,
              "tests": results, "hardware_tested": False, "gowin_built": False, "programmed": False,
              "hdmi_boundary_stub": True, "timing_parameters_scaled": True}
    (out / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("REPORT", out / "summary.json", flush=True)
    if changed:
        print("SOURCE_CHANGED", ", ".join(changed), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
