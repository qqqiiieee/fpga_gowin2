"""V028 four-key/phone RTL regression. No Gowin, board, UART device, or release writes.

Each run gets an immutable snapshot and records commands, hashes and boundaries.
The real top/audio/phone/MIDI/guide RTL is used; top tests stub hdmi_live_display.
UI assets/rendering are intentionally outside this regression's ownership.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "system": ("tb_fourphone_system", "FOURPHONE_SYSTEM_PASS", {}, 1500),
    "arbitration": ("tb_fourphone_arbitration", "FOURPHONE_ARBITRATION_PASS", {}, 360),
    **{f"buttons_d{d}": ("tb_fourphone_buttons", "FOURPHONE_BUTTONS_PASS",
                         {"TEST_DEBOUNCE": d}, 30) for d in (1, 4, 7)},
    "phone_protocol": ("tb_phone_control_link", "PHONE_CONTROL_LINK_PASS", {}, 60),
    "fx_phone": ("tb_midi_fx_phone", "MIDI_FX_PHONE_TEST_PASS", {}, 90),
    "piano_held": ("tb_piano_held_monitor", "PIANO_HELD_MONITOR_TEST_PASS", {}, 180),
    "piano_guide": ("tb_piano_roll_guide", "PIANO_ROLL_GUIDE_TEST_PASS", {"TEST_BEAT_SAMPLES": 67}, 90),
    "pcm_i2s": ("tb_pcm5102a_i2s", "PCM5102A_I2S_TEST_PASS", {}, 60),
    "midi_keyboard": ("tb_midi_keyboard", "MIDI_KEYBOARD_TEST_PASS", {}, 90),
    "note_range": ("tb_note_table_midi_range", "NOTE_TABLE_MIDI_RANGE_TEST_PASS", {}, 60),
}


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=list(CASES), action="append")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--reuse-passed-from", type=Path, action="append", default=[],
                        help="Prior summary.json; reuse only exact case RTL/bench/support hashes")
    args = parser.parse_args()
    selected = args.case or list(CASES)
    out = ROOT / "validation/fourphone" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    snapshot = out / "snapshot"
    (snapshot / "src").mkdir(parents=True)
    (snapshot / "tests").mkdir()
    tool = ROOT / "tools/vendor/iverilog-v12/app/bin"
    env = dict(os.environ, PATH=str(tool)+os.pathsep+os.environ.get("PATH", ""))
    # These files cannot be edited by a UI author without invalidating this run.
    sources = [p for p in sorted((ROOT / "src").iterdir())
               if p.is_file() and p.suffix in (".v", ".vh", ".hex")
               and not p.name.startswith(("hdmi_", "tmds_", "video_"))]
    benches = [ROOT / "tests" / (CASES[c][0]+".v") for c in selected]
    support = sorted((ROOT / "tests").glob("*.vh"))
    if "midi_keyboard" in selected:
        support.append(ROOT / "tests/tb_midi_support.v")
    if "note_range" in selected:
        support.append(ROOT / "tests/fixtures/note_table_v018.hex")
    tracked = sorted(set(sources+benches+support+[Path(__file__).resolve(),
                     ROOT / "src/multi_tone.cst", ROOT / "instrument_handoff.gprj"]))
    before = {p.relative_to(ROOT).as_posix(): digest(p) for p in tracked}
    for p in tracked:
        target = snapshot / p.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, target)
    # Pin uniqueness and project selection complement (never replace) simulation.
    cst = (snapshot / "src/multi_tone.cst").read_text(encoding="utf-8-sig")
    locs = dict(re.findall(r'IO_LOC\s+"([^"]+)"\s+([^;]+);', cst))
    expected = {"phone_uart_rx": "M14", "phone_uart_tx": "M15",
                **{f"ui_buttons_n[{i}]": p for i, p in enumerate(("T11", "P11", "T12", "R11"))}}
    pin_users = {}
    for port, pins in locs.items():
        for pin in pins.replace(",", " ").split():
            pin_users.setdefault(pin, []).append(port)
    assert all(locs.get(k) == v for k, v in expected.items()), "pin mapping mismatch"
    assert all(len(v) == 1 for v in pin_users.values()), "CST duplicate pin"
    for port in expected:
        assert re.search(r'IO_PORT\s+"'+re.escape(port)+r'"[^;]*IO_TYPE=LVCMOS33[^;]*PULL_MODE=UP[^;]*BANK_VCCIO=3.3;', cst), port
    project = ET.parse(snapshot / "instrument_handoff.gprj")
    entries = [e.attrib["path"] for e in project.findall(".//File") if e.attrib.get("enable") == "1"]
    assert entries.count("src/four_button_display_control.v") == 1
    assert "src/touch_display_control.v" not in entries
    assert len(entries) == len(set(entries)), "duplicate project source"
    top = (snapshot / "src/top.v").read_text(encoding="utf-8")
    assert "parameter TOUCH_ENABLE=0" in top and ".ui_controls(buttons_down)" in top
    assert "touch_display_control #" not in top

    def case_hashes(label):
        own = "tests/"+CASES[label][0]+".v"
        extras = [p.relative_to(ROOT).as_posix() for p in support
                  if p.suffix == ".vh" or
                  (label == "midi_keyboard" and p.name == "tb_midi_support.v") or
                  (label == "note_range" and p.name == "note_table_v018.hex")]
        return {path: value for path, value in before.items()
                if path.startswith("src/") or path == own or path in extras or path == "instrument_handoff.gprj"}

    reusable = {}
    if not args.compile_only:
        for previous_path in args.reuse_passed_from:
            previous_path = previous_path.resolve()
            previous = json.loads(previous_path.read_text(encoding="utf-8-sig"))
            old_hashes = {p.replace("\\", "/"): h for p, h in previous["source_hashes"].items()}
            if previous.get("compile_only") or not previous.get("snapshot_hashes_match"):
                continue
            for result in previous["cases"]:
                label = result["case"]
                if label not in selected or not result["passed"] or "run" not in result:
                    continue
                needed = case_hashes(label)
                if any(old_hashes.get(path) != value for path, value in needed.items()):
                    continue
                # The old full-suite hash may have changed only because a DIFFERENT
                # bench was repaired. Verify every actual case input in its saved
                # snapshot and compare to today's input before reusing that case.
                if not all(digest(previous_path.parent / "snapshot" / path) == value
                           for path, value in needed.items()):
                    continue
                result = dict(result)
                result.update(reused_from=str(previous_path), evidence_dir=str(previous_path.parent),
                              case_input_hashes=needed)
                reusable[label] = result

    def invoke(argv, limit, log_path):
        start = time.monotonic()
        record = {"argv": list(map(str, argv)), "cwd": str(snapshot), "timeout_seconds": limit}
        with log_path.open("w", encoding="utf-8") as logfile:
            try:
                run = subprocess.run(record["argv"], cwd=snapshot, env=env, stdout=logfile,
                                     stderr=subprocess.STDOUT, timeout=limit)
                record["exit_code"] = run.returncode
            except subprocess.TimeoutExpired:
                logfile.write("\nTIMEOUT\n")
                record.update(exit_code=None, timed_out=True)
        output = log_path.read_text(encoding="utf-8", errors="replace")
        record.update(elapsed_seconds=round(time.monotonic()-start, 3), log=str(log_path.relative_to(out)))
        return record, output

    def test(label):
        if label in reusable:
            print(label, "PASS (verified identical case inputs; reused)", flush=True)
            return reusable[label]
        name, marker, parameters, timeout = CASES[label]
        binary = out / (label+".vvp")
        files = [str(p.relative_to(ROOT)) for p in sources if p.suffix == ".v"]
        argv = [tool / "iverilog.exe", "-g2012", "-I", "src", "-I", "tests", "-s", name,
                *[f"-P{name}.{key}={value}" for key, value in parameters.items()],
                "-o", binary, *files, "tests/"+name+".v"]
        if label == "midi_keyboard":
            argv.append("tests/tb_midi_support.v")
        record = {"case": label, "testbench": name, "parameters": parameters, "passed": False,
                  "case_input_hashes": case_hashes(label), "evidence_dir": str(out)}
        record["compile"], _ = invoke(argv, 90, out / (label+"_compile.log"))
        if record["compile"]["exit_code"] == 0:
            if args.compile_only:
                record["passed"] = True
            else:
                record["run"], log = invoke([tool / "vvp.exe", "-i", binary], timeout, out / (label+"_run.log"))
                record["passed"] = record["run"]["exit_code"] == 0 and marker in log and not any(
                    bad in log for bad in ("FATAL:", "ERROR:", "FAIL"))
                record["result_lines"] = [line for line in log.splitlines() if "PASS" in line or "CHECKPOINT" in line]
        (out / (label+".json")).write_text(json.dumps(record, indent=2), encoding="utf-8")
        print(label, "COMPILE_PASS" if args.compile_only and record["passed"] else
              "PASS" if record["passed"] else "FAIL", flush=True)
        return record

    print("report:", out, flush=True)
    with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 3))) as pool:
        results = list(pool.map(test, selected))
    after = {p.relative_to(ROOT).as_posix(): digest(p) for p in tracked}
    snapshot_match = all(digest(snapshot / p) == value for p, value in before.items())
    report = {"passed": all(r["passed"] for r in results) and before == after and snapshot_match,
              "compile_only": args.compile_only, "full_suite": set(selected) == set(CASES),
              "cases": results, "source_hashes": before, "source_hashes_after": after,
              "source_hashes_match": before == after, "snapshot_hashes_match": snapshot_match,
              "pin_map": expected, "pin_uniqueness_and_project_selection": True,
              "gowin_synthesis_or_pnr": False, "hardware_programmed": False, "physical_validation": False,
              "boundaries": ["HDMI display replaced by passive interface stub in both top tests",
                  "system: production phone/MIDI/debug UART timing; debounce and guide/optical qualification accelerated",
                  "arbitration: phone baud/debounce/guide/test timers accelerated; real top and audio engine",
                  "arbitration diagnostic ownership entry injects only ui_test_keys; no production diagnostic key binding",
                  "I2C ADC pins pulled high without device; no physical ADC/FSR/ESP32/RF/audio/HDMI verification",
                  "No old analog-touch menu tests presented as V028 panel validation"]}
    (out / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print("FOURPHONE_REGRESSION_PASS" if report["passed"] else "FOURPHONE_REGRESSION_FAIL", len(results), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
