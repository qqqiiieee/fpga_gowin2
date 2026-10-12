"""Isolated song-guide validation; no full-project build or hardware access."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_VIVADO = Path(os.environ.get("XILINX_VIVADO","D:/vivado2023.2/Vivado/2023.2"))
SCORES = [
    {
        "id": 0,
        "title": "Twinkle Twinkle Little Star",
        "notes": "C C G G A A G F F E E D D C G G F F E E D G G F F E E D C C G G A A G F F E E D D C".split(),
        "long_steps": [6, 13, 20, 27, 34, 41],
        "arrangement": "Original 42 notes and original one/two-beat rhythm preserved.",
    },
    {
        "id": 1,
        "title": "Ode to Joy",
        "notes": "E E F G G F E D C C D E E D D D E E F G G F E D C C D E D C C C".split(),
        "long_steps": [7, 15, 23, 31],
        "arrangement": "32-press C-major practice arrangement; rearticulate the final D/C cadence in each 16-note section.",
    },
    {
        "id": 2,
        "title": "Frere Jacques / Liang Zhi Lao Hu",
        "notes": "C D E C C D E C E F G E F G G A G F E C G A G F E C C G C C G C".split(),
        "long_steps": [10, 13, 28, 31],
        "arrangement": "Simplified one/two-beat practice rhythm. Both final C G C phrases use keyboard G4 instead of traditional lower G3.",
    },
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def vivado_environment(root: Path) -> tuple[Path, dict[str, str]]:
    binaries = root / "bin/unwrapped/win64.o"
    env = os.environ.copy()
    paths = [
        root / "lib/win64.o", binaries,
        root / "tps/mingw/6.2.0/win64.o/nt/bin",
        root / "tps/mingw/6.2.0/win64.o/nt/libexec/gcc/x86_64-w64-mingw32/6.2.0",
        root / "tps/win64/jre17.0.7_7/bin/server",
        root / "tps/win64/jre17.0.7_7/bin",
        root / "tps/win64/python-3.8.3",
        root / "tps/win64/python-3.8.3/bin",
    ]
    env["PATH"] = os.pathsep.join(map(str, paths)) + os.pathsep + env.get("PATH", "")
    env.update({
        "XILINX_VIVADO": str(root), "RDI_DATADIR": str(root / "data"),
        "RDI_APPROOT": str(root), "RDI_BINROOT": str(root / "bin"),
        "RDI_LIBDIR": str(root / "lib/win64.o"), "RDI_BINDIR": str(root / "bin"),
        "RDI_PLATFORM": "win64", "RDI_OPT_EXT": ".o", "HDI_APPROOT": str(root),
        "TCL_LIBRARY": str(root / "tps/tcl/tcl8.5"),
    })
    return binaries, env


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=PROJECT)
    parser.add_argument("--vivado", type=Path, default=DEFAULT_VIVADO)
    args = parser.parse_args()
    project = args.project.resolve()
    validation = project / "validation/song_agent_sim"
    run_dir = validation / "runs" / datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    run_dir.mkdir(parents=True, exist_ok=False)
    snapshot_dir = run_dir / "sources"
    snapshot_dir.mkdir()
    used_paths = [
        project / "src/song_guide.v",
        project / "tests/tb_song_library.v",
        project / "tests/tb_song_guide.v",
        project / "tests/tb_song_pause.v",
    ]
    source_hashes = {str(p): sha256(p) for p in used_paths}
    snapshots = {}
    for source in used_paths:
        target = snapshot_dir / source.name
        target.write_bytes(source.read_bytes())
        if sha256(target) != source_hashes[str(source)]:
            raise RuntimeError(f"Source changed while taking snapshot: {source}")
        snapshots[source.name] = target
    script_path = Path(__file__).resolve()
    source_hashes[str(script_path)] = sha256(script_path)
    frozen_file = validation / "frozen_source.json"
    frozen = (json.loads(frozen_file.read_text(encoding="utf-8-sig"))
              if frozen_file.is_file() else None)
    report = {
        "status": "RUNNING", "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "project": str(project), "run_directory": str(run_dir),
        "simulator": str(args.vivado), "language": "Verilog-2001; xvlog without -sv",
        "source_hashes": source_hashes, "source_snapshot_directory": str(snapshot_dir),
        "frozen_production_source": frozen,
        "baseline_song_sha256": "cb5178a15a71756a15f565e7b31f7609f6c14d0e83bb0318057a51fe4dafabe2",
        "physical_logical_mapping": "bit0..5 = S1..S6 = C4 D4 E4 F4 G4 A4; unchanged",
        "command_priority": "reset > UI start/restart > UI toggle > unpaused legacy restart/toggle > follow",
        "song_selection": "Latches song_id only on UI start/restart; invalid 3 falls back to 0; legacy restart retains latched song.",
        "hardware_access": False, "production_synthesis": "not run; no full-project synthesis/PnR or programming",
        "scores": [{**s, "steps": len(s["notes"]),
                    "target_beats": [2 if i in s["long_steps"] else 1 for i in range(len(s["notes"]))]}
                   for s in SCORES],
        "tests": [],
    }
    binaries, env = vivado_environment(args.vivado)

    def save() -> None:
        content = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        (run_dir / "results.json").write_text(content, encoding="utf-8")
        (validation / "results.json").write_text(content, encoding="utf-8")

    def run_tool(tool: str, arguments: list[str], cwd: Path, log_name: str,
                 timeout: int = 180) -> str:
        executable = binaries / (tool + ".exe")
        if not executable.is_file():
            raise RuntimeError(f"Missing simulator executable: {executable}")
        started = time.monotonic()
        proc = subprocess.run([str(executable), *arguments], cwd=cwd, env=env,
                              capture_output=True, timeout=timeout)
        output = (proc.stdout + proc.stderr).decode("utf-8", errors="replace")
        (cwd / log_name).write_text(output, encoding="utf-8")
        if proc.returncode:
            raise RuntimeError(f"{tool} failed with {proc.returncode}; see {cwd / log_name}")
        if re.search(r"(?:_TEST_FAIL|Fatal:|FATAL:|ERROR:)", output):
            raise RuntimeError(f"{tool} reported a failure; see {cwd / log_name}")
        return output

    try:
        save()
        if frozen and source_hashes[str(used_paths[0])] != frozen["sha256"]:
            raise RuntimeError("Production song_guide.v differs from the user-requested frozen source.")
        # Isolate compilation and snapshots from every other agent's validation.
        work = run_dir / "simulation"
        work.mkdir()
        run_tool("xvlog", [str(snapshots[p.name]) for p in used_paths], work, "compile.log")
        cases = [("tb_song_library", b, full)
                 for b, full in [(0, 1), (1, 1), (3, 1), (7, 1), (16, 1), (100, 1), (46875, 0)]]
        cases += [("tb_song_guide", b, None) for b in [1, 3, 16, 46875]]
        cases += [("tb_song_pause", None, None)]
        for top, beat, full in cases:
            case_name = top + (f"_b{beat}" if beat is not None else "")
            snapshot = case_name + "_snapshot"
            arguments = [top, "-s", snapshot, "--timescale", "1ns/1ps", "--mt", "2"]
            if beat is not None:
                arguments.extend(["--generic_top", f"TEST_BEAT_SAMPLES={beat}"])
            if full is not None:
                arguments.extend(["--generic_top", f"FULL_TIMING={full}"])
            started = time.monotonic()
            print("RUN " + case_name, flush=True)
            run_tool("xelab", arguments, work, case_name + "_elaborate.log")
            output = run_tool("xsim", [snapshot, "-runall"], work, case_name + "_simulate.log")
            expected = {"tb_song_library": "SONG_LIBRARY_TEST_PASS",
                        "tb_song_guide": "SONG_GUIDE_TEST_PASS",
                        "tb_song_pause": "SONG_PAUSE_TEST_PASS"}[top]
            markers = [line.strip() for line in output.splitlines() if expected in line]
            if not markers:
                raise RuntimeError(f"No pass marker for {case_name}; see simulation log")
            evidence = {"case": case_name, "status": "PASS", "pass_markers": markers,
                        "elapsed_seconds": round(time.monotonic()-started, 3),
                        "full_timing": full,
                        "log": str(work / (case_name + "_simulate.log"))}
            report["tests"].append(evidence)
            save()
            print(markers[-1], flush=True)
        report["source_hashes_after"] = {str(p): sha256(p) for p in [*used_paths, script_path]}
        report["tested_sources_unchanged"] = report["source_hashes_after"] == source_hashes
        if not report["tested_sources_unchanged"]:
            raise RuntimeError("Live tested source changed during validation; rerun the current source.")
        baseline_file = validation / "before_hashes.json"
        if baseline_file.is_file():
            before = json.loads(baseline_file.read_text(encoding="utf-8-sig"))
            changed = [entry["path"] for entry in before
                       if not Path(entry["path"]).is_file() or sha256(Path(entry["path"])) != entry["sha256"]]
            report["src_tests_changed_since_initial_snapshot"] = changed
            report["scope_note"] = "Other agents may edit their own files; this runner writes only its validation directory."
        report["status"] = "PASS"
        report["passed_tests"] = len(report["tests"])
        print(f"SONG_AGENT_SUITE_PASS cases={len(report['tests'])} sourcehash={source_hashes[str(used_paths[0])]}", flush=True)
        return 0
    except Exception as exc:
        report["status"] = "FAIL"
        report["error"] = str(exc)
        print(f"SONG_AGENT_SUITE_FAIL: {exc}", file=sys.stderr, flush=True)
        return 1
    finally:
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        save()


if __name__ == "__main__":
    raise SystemExit(main())
