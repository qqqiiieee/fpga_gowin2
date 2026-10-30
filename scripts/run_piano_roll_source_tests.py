"""钢琴卷帘源域/物理held离线回归；不调用Gowin、不烧录、不发布。

默认逐采样跑完三首曲目，含正式46875采样/拍与多组分数tick参数。
独立快照隔离其他代理的显示编辑，报告记录实际源哈希和完整编译/运行命令。
用例输出仅写validation/piano_roll_source；不修改工程XML或任何显示文件。
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

ROOT = Path(__file__).resolve().parents[1]
OWNED = ["src/piano_roll_score.v", "src/piano_roll_guide.v",
         "src/performance_input_hub.v", "src/instrument_inputs.v", "src/instrument_audio_top.v",
         "tests/tb_piano_roll_guide.v", "tests/tb_piano_held_monitor.v",
         "scripts/run_piano_roll_source_tests.py"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=["guide", "monitor", "legacy"], action="append")
    parser.add_argument("--beats", type=int, nargs="+", default=[0, 1, 7, 63, 64, 65, 67, 1001, 46875])
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    selected = args.case or ["guide", "monitor", "legacy"]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    out = ROOT / "validation/piano_roll_source" / stamp
    snapshot = out / "snapshot"
    snapshot.mkdir(parents=True)
    tool = ROOT / "tools/vendor/iverilog-v12/app/bin"
    env = dict(os.environ, PATH=str(tool)+os.pathsep+os.environ.get("PATH", ""))
    before = {p: sha(ROOT / p) for p in OWNED}
    # 各文件只复制一次；解析/执行均在快照下进行，不读取随后变化的生产源。
    for dirname in ["src", "tests"]:
        target = snapshot / dirname
        target.mkdir()
        for source in (ROOT / dirname).iterdir():
            if source.is_file() and source.suffix in [".v", ".vh", ".hex"]:
                shutil.copy2(source, target / source.name)
    cases = []
    if "guide" in selected:
        for beats in args.beats:
            cases.append((f"guide_B{beats}", "tb_piano_roll_guide",
                          [f"-Ptb_piano_roll_guide.TEST_BEAT_SAMPLES={beats}"],
                          ["src/piano_roll_score.v", "src/piano_roll_guide.v"],
                          "PIANO_ROLL_GUIDE_TEST_PASS"))
    nongraphics = [str(p.relative_to(snapshot)) for p in sorted((snapshot / "src").glob("*.v"))
                   if p.name != "top.v" and not p.name.startswith(("hdmi_", "tmds_", "video_"))]
    if "monitor" in selected:
        cases.append(("held_monitor", "tb_piano_held_monitor", [], nongraphics,
                      "PIANO_HELD_MONITOR_TEST_PASS"))
    if "legacy" in selected:
        for name, marker in [("tb_song_rhythm", "SONG_RHYTHM_TEST_PASS"),
                             ("tb_song_library", "SONG_LIBRARY_TEST_PASS"),
                             ("tb_midi_audio_integration", "MIDI_AUDIO_INTEGRATION_TEST_PASS")]:
            cases.append((name, name, [], nongraphics, marker))

    def run(argv):
        started = time.monotonic()
        record = {"argv": list(map(str, argv)), "cwd": str(snapshot)}
        try:
            proc = subprocess.run(record["argv"], cwd=snapshot, env=env, capture_output=True,
                                  text=True, encoding="utf-8", errors="replace", timeout=args.timeout)
            record.update(exit_code=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)
        except subprocess.TimeoutExpired:
            record.update(exit_code=None, timed_out=True)
        record["elapsed_seconds"] = round(time.monotonic()-started, 3)
        return record

    def test(case):
        label, top, params, sources, marker = case
        binary = out / (label+".vvp")
        argv = [tool / "iverilog.exe", "-g2012", "-I", "src", "-I", "tests", "-s", top,
                *params, "-o", binary, *sources, "tests/"+top+".v"]
        compile_result = run(argv)
        record = {"case": label, "compile": compile_result, "passed": False}
        if compile_result["exit_code"] == 0:
            execution = run([tool / "vvp.exe", binary])
            record["run"] = execution
            log = execution.get("stdout", "")+execution.get("stderr", "")
            record["passed"] = execution["exit_code"] == 0 and marker in log and "FATAL:" not in log
        (out / (label+".json")).write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
        print(label, "PASS" if record["passed"] else "FAIL", flush=True)
        if not record["passed"]:
            print(json.dumps(record, ensure_ascii=False, indent=2), flush=True)
        return record

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(test, cases))
    stable = before == {p: sha(ROOT / p) for p in OWNED}
    snapshot_match = all(sha(snapshot / p) == digest for p, digest in before.items()
                         if not p.startswith("scripts/"))
    report = {"passed": all(r["passed"] for r in results) and stable and snapshot_match,
              "sources_sha256": before, "owned_sources_stable": stable,
              "snapshot_matches_owned_hashes": snapshot_match,
              "snapshot_sources_sha256": {str(p.relative_to(snapshot)): sha(p)
                                          for p in (snapshot / "src").iterdir()},
              "tests": results, "hardware_tested": False, "flashed": False,
              "gowin_synthesis_or_pnr": False,
              "boundary": "RTL simulation only; display/top integration owned by main; no hardware or flashing"}
    destination = out / "summary.json"
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("report:", destination, flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
