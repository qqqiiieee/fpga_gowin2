"""Frozen Icarus regressions; writes only tests/builtin_score_v045/.

Run from anywhere: python tests/builtin_score_v045/run_tests.py [--case NAME]
No synthesis, complete instrument build, hardware access, burn or release.
Existing testbench inputs are copied read-only, then compiled in this directory.
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
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DEFAULT_TOOLS = Path("D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin")


def oracle_words(source):
    """Independent chronological oracle from RAW source pairs, not library/HEX.

    A quarter is assigned by elapsed duration comparison. Next pitched note is
    the first pitched event whose START is later than that quarter. This differs
    from the generator's event-first fill + subsequent-event slice algorithm.
    """
    result = []
    for selected in range(4):
        if selected == 3:
            result.extend([0] * 256)
            continue
        pairs = source["songs"][selected]["events_note_duration_quarters"]
        events, cursor = [], 8
        for step, (pitch, duration) in enumerate(pairs):
            events.append((cursor, cursor + duration, pitch, step))
            cursor += duration
        for quarter in range(256):
            active = next((e for e in events if e[0] <= quarter < e[1]), None)
            step = active[3] if active else (0 if quarter < 8 else len(events) - 1)
            pitch = active[2] if active else 0
            following = next((e[2] for e in events if e[0] > quarter and e[2]), 0)
            word = step * 128 + pitch
            word |= bool(pitch) << 13
            word |= bool(pitch and active[0] == quarter) << 14
            word |= bool(pitch and active[1] - active[0] > 4) << 15
            word |= following << 16
            word |= bool(following) << 23
            word |= (96 if pitch else 0) << 24
            result.append(word)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool-dir", type=Path, default=DEFAULT_TOOLS)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--case", action="append")
    parser.add_argument("--timeout", type=int, default=600,
                        help="per simulator process limit; full real-tempo tests can be slow under concurrent agent load")
    parser.add_argument("--reuse-report", type=Path,
                        help="reuse passing cases only when all RTL, source data and testbench hashes still match")
    args = parser.parse_args()
    tools = args.tool_dir.resolve()
    for name in ("iverilog.exe", "vvp.exe"):
        if not (tools / name).is_file():
            raise SystemExit(f"Missing {tools / name}")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    out = HERE / "results" / stamp
    snapshot = out / "snapshot"
    snapshot.mkdir(parents=True)
    src = ["src/piano_roll_guide.v", "src/piano_roll_renderer.v", "src/piano_roll_score.v",
           "src/custom_score_ram.v", "src/piano_builtin_score_ram.v", "src/piano_builtin_score.hex",
           "src/piano_layout.vh", "src/piano_song_rom_v045.vh"]
    tests = ["tests/tb_piano_roll_guide.v", "tests/custom_score/tb_custom_builtin_compat.v",
             "tests/custom_score/tb_custom_score_guide.v", "tests/custom_score/tb_custom_score_pixels.v",
             "tests/custom_score/score_fixture.vh", "tests/custom_score/baseline_piano_roll_guide.v.txt",
             "tests/custom_score/baseline_piano_roll_renderer.v.txt", "tests/song_library_v045/source.json",
             "tests/song_library_v045/library.json", "scripts/generate_builtin_score_bram_v045.py",
             "tests/builtin_score_v045/run_tests.py"]
    tests += [p.relative_to(ROOT).as_posix() for p in sorted(HERE.glob("tb_*.v"))]
    hashes = {}
    for name in src + tests:
        data = (ROOT / name).read_bytes()
        dest = snapshot / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
    source = json.loads((snapshot / "tests/song_library_v045/source.json").read_text(encoding="utf-8"))
    oracle = oracle_words(source)
    (snapshot / "tests/builtin_score_v045/oracle.hex").write_text(
        "".join(f"{word:08x}\n" for word in oracle), encoding="ascii")
    actual = [int(line, 16) for line in (snapshot / "src/piano_builtin_score.hex").read_text().splitlines()]
    if actual != oracle:
        raise AssertionError("BRAM image differs from raw-event chronological oracle")
    for module in ("guide", "renderer"):
        baseline = (snapshot / f"tests/custom_score/baseline_piano_roll_{module}.v.txt").read_text(encoding="utf-8")
        baseline = baseline.replace(f"module piano_roll_{module}", f"module piano_roll_{module}_baseline", 1)
        (snapshot / f"tests/builtin_score_v045/{module}_golden.v").write_text(baseline, encoding="utf-8")
    # Exercise the EXISTING custom regressions with new library also enabled.
    # Only these frozen test copies change; production/other agents' files do not.
    for kind in ("guide", "pixels"):
        bench = (snapshot / f"tests/custom_score/tb_custom_score_{kind}.v").read_text(encoding="utf-8")
        bench = bench.replace(".CUSTOM_SCORE_ENABLE(1)", ".CUSTOM_SCORE_ENABLE(1),.SONG_LIBRARY_ENABLE(1)")
        (snapshot / f"tests/builtin_score_v045/custom_{kind}.v").write_text(bench, encoding="utf-8")
    guide = ["src/piano_roll_guide.v", "src/custom_score_ram.v"]
    renderer = ["src/piano_roll_renderer.v", "src/custom_score_ram.v"]
    ram = ["src/piano_builtin_score_ram.v"]
    legacy = ["src/piano_roll_score.v"]
    cases = []
    def add(name, top, files, params, marker):
        cases.append((name, top, files, params, marker))
    add("rom", "tb_builtin_rom", ram + ["tests/builtin_score_v045/tb_builtin_rom.v"], {}, "BUILTIN_ROM_PASS")
    # Deliberately OMIT piano_roll_score.v from every enabled build: any old
    # current/next/pixel decoder instance left in that path fails elaboration.
    for beat in (0, 1, 7, 63, 64, 65, 67, 1001, 46875):
        add(f"builtin_guide_{beat}", "tb_builtin_guide", guide + ram + ["tests/builtin_score_v045/tb_builtin_guide.v"],
            {"B": beat}, "BUILTIN_GUIDE_PASS")
        # Conversely omit the new RAM from legacy tests to prove feature=0
        # preserves the old source dependency set as well as behavior.
        add(f"legacy_guide_{beat}", "tb_piano_roll_guide", guide + legacy + ["tests/tb_piano_roll_guide.v"],
            {"TEST_BEAT_SAMPLES": beat}, "PIANO_ROLL_GUIDE_TEST_PASS")
    add("builtin_pixels", "tb_builtin_pixels", renderer + ram + ["tests/builtin_score_v045/tb_builtin_pixels.v"], {}, "BUILTIN_PIXELS_PASS")
    add("ready_switch", "tb_ready_switch", guide + ram + ["tests/builtin_score_v045/tb_ready_switch.v"], {}, "BUILTIN_READY_SWITCH_PASS")
    add("legacy_baseline", "tb_custom_builtin_compat", guide + renderer[:1] + legacy + [
        "tests/custom_score/tb_custom_builtin_compat.v", "tests/builtin_score_v045/guide_golden.v",
        "tests/builtin_score_v045/renderer_golden.v"], {}, "CUSTOM_BUILTIN_COMPAT_PASS")
    for period in (23437, 46875, 187500):
        add(f"custom_guide_{period}", "tb_custom_score_guide", guide + ram + ["tests/builtin_score_v045/custom_guide.v"],
            {"SPB": period}, "CUSTOM_GUIDE_PASS")
    for phase in (0, 11):
        add(f"custom_pixels_{phase}", "tb_custom_score_pixels", renderer + ram + ["tests/builtin_score_v045/custom_pixels.v"],
            {"PIXEL_PHASE": phase}, "CUSTOM_PIXELS_PASS")
    if args.case:
        unknown = set(args.case) - {c[0] for c in cases}
        if unknown:
            raise ValueError(f"unknown case: {unknown}")
        cases = [c for c in cases if c[0] in args.case]
    reusable = {}
    if args.reuse_report:
        previous = json.loads(args.reuse_report.read_text(encoding="utf-8"))
        # Only this runner may differ (e.g. timeout/selection improvements).
        # Every RTL, HEX/include, raw song source, baseline and bench must match;
        # never reuse a pass across a changed DUT or a changed oracle/fixture.
        if not all(previous.get("snapshot_sha256", {}).get(name) == digest
                   for name, digest in hashes.items() if name != "tests/builtin_score_v045/run_tests.py"):
            raise ValueError("reuse refused: RTL/data/testbench inputs changed")
        previous_cases = {c["name"]: c for c in previous["tests"] if c["passed"]}
        for name, top, files, params, marker in cases:
            if name not in previous_cases:
                continue
            rec = previous_cases[name]
            argv = rec["compile"]["argv"]
            if argv[-len(files):] != files or argv[argv.index("-s")+1] != top or sorted(
                a for a in argv if a.startswith("-P")) != sorted(f"-P{top}.{k}={v}" for k, v in params.items()):
                raise ValueError(f"reuse refused: compile configuration changed for {name}")
            if not any(marker in metric for metric in rec["simulation"]["metrics"]):
                raise ValueError(f"reuse refused: pass marker missing for {name}")
            rec["reused_from"] = str(args.reuse_report.resolve())
            for part in ("compile", "simulation"):
                shutil.copy2(Path(previous["result_directory"]) / rec[part]["log"], out / rec[part]["log"])
            reusable[name] = rec
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""))
    def execute(label, argv, marker=None):
        started = time.monotonic()
        try:
            p = subprocess.run(list(map(str, argv)), cwd=snapshot, env=env, capture_output=True,
                               text=True, encoding="utf-8", errors="replace", timeout=args.timeout)
            log, code = p.stdout + p.stderr, p.returncode
        except subprocess.TimeoutExpired as exc:
            log, code = f"TIMEOUT after {args.timeout}s: {exc}", None
        (out / f"{label}.log").write_text(log, encoding="utf-8")
        return dict(exit=code, passed=code == 0 and "FATAL:" not in log and (not marker or marker in log),
                    seconds=round(time.monotonic() - started, 3), argv=list(map(str, argv)),
                    cwd=str(snapshot), log=f"{label}.log", metrics=[l for l in log.splitlines() if "_PASS" in l])
    def run(case):
        name, top, files, params, marker = case
        if name in reusable:
            print(f"{name}: PASS (reused exact RTL/data/bench inputs)", flush=True)
            return reusable[name]
        binary = out / f"{name}.vvp"
        compile_result = execute(name + "_compile", [tools / "iverilog.exe", "-g2001", "-Wall", "-I", ".",
            "-s", top, *[f"-P{top}.{key}={value}" for key, value in params.items()], "-o", binary, *files])
        rec = dict(name=name, compile=compile_result, passed=False)
        if compile_result["passed"]:
            rec["simulation"] = execute(name, [tools / "vvp.exe", binary], marker)
            rec["passed"] = rec["simulation"]["passed"]
        print(f"{name}: {'PASS' if rec['passed'] else 'FAIL'}", flush=True)
        if not rec["passed"]:
            print((out / rec.get("simulation", compile_result)["log"]).read_text(encoding="utf-8")[-2500:], flush=True)
        return rec
    report = dict(passed=False, snapshot_sha256=hashes, oracle_addresses=1024, tests=[],
                  synthesis=False, production_build=False, programming=False, publication=False)
    report_path = HERE / "latest_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        report["tests"] = list(pool.map(run, cases))
    report["inputs_unchanged"] = all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == value for name, value in hashes.items())
    report["passed"] = all(r["passed"] for r in report["tests"]) and report["inputs_unchanged"]
    report["result_directory"] = str(out)
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    (out / "report.json").write_text(text, encoding="utf-8")
    report_path.write_text(text, encoding="utf-8")
    print(f"BUILTIN_SCORE_V045_{'PASS' if report['passed'] else 'FAIL'} cases={len(cases)} results={out}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
