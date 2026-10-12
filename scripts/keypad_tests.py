"""Isolated keypad RTL validation; never builds the rest of the instrument."""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
VIVADO = Path(os.environ.get("XILINX_VIVADO","D:/vivado2023.2/Vivado/2023.2"))
PHYSICAL_ROWS = ("T11", "M14", "T12", "J14")
PHYSICAL_COLS = ("P11", "R11", "M15", "J16")
HISTORICAL = (
    (PROJECT / "tests/tb_performance_keys.v",
     "tb_performance_keys", "PERFORMANCE_KEYS_TEST_PASS"),
    (PROJECT / "tests/tb_noise_selectors.v",
     "tb_noise_selectors", "NOISE_SELECTORS_TEST_PASS"),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pin_mapping(cst: str) -> dict:
    # Parse actual IO_LOC statements; comments cannot define a pin assignment.
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", cst, flags=re.S)
    entries = re.findall(r'IO_LOC\s+"matrix_(rows|cols)\[(\d+)\]"\s+([A-Z]\d+)\s*;', text)
    logical: dict[str, dict[int, str]] = {"rows": {}, "cols": {}}
    for kind, index_text, pin in entries:
        index = int(index_text)
        if index in logical[kind]:
            raise ValueError(f"Duplicate matrix_{kind}[{index}] constraint")
        logical[kind][index] = pin
    result = {}
    for kind, physical in (("rows", PHYSICAL_ROWS), ("cols", PHYSICAL_COLS)):
        if set(logical[kind]) != set(range(4)) or len(set(logical[kind].values())) != 4:
            raise ValueError(f"Missing/duplicate {kind} pin constraints: {logical[kind]}")
        by_pin = {pin: index for index, pin in logical[kind].items()}
        result[kind] = [by_pin[pin] for pin in physical]
        if result[kind] != list(range(4)):
            raise ValueError(f"CST disagrees with existing physical {kind} wires: {result[kind]}")
    result["physical_row_pins"] = PHYSICAL_ROWS
    result["physical_col_pins"] = PHYSICAL_COLS
    return result


def map_include(mapping: dict) -> str:
    lines = ["// Generated from snapshot multi_tone.cst and independently fixed physical wires."]
    for kind, letter in (("rows", "R"), ("cols", "C")):
        for index, logical in enumerate(mapping[kind], 1):
            lines.append(f"`define CST_PHYSICAL_{letter}{index} {logical}")
    return "\n".join(lines) + "\n"


def vivado_environment(root: Path) -> dict[str, str]:
    env = os.environ.copy()
    paths = [root / "lib/win64.o", root / "bin/unwrapped/win64.o",
             root / "tps/mingw/6.2.0/win64.o/nt/bin",
             root / "tps/mingw/6.2.0/win64.o/nt/libexec/gcc/x86_64-w64-mingw32/6.2.0",
             root / "tps/win64/jre17.0.7_7/bin/server", root / "tps/win64/jre17.0.7_7/bin",
             root / "tps/win64/python-3.8.3", root / "tps/win64/python-3.8.3/bin"]
    env["PATH"] = os.pathsep.join(map(str, paths)) + os.pathsep + env["PATH"]
    env.update({"XILINX_VIVADO": str(root), "RDI_DATADIR": str(root / "data"),
                "RDI_APPROOT": str(root), "RDI_BINROOT": str(root / "bin"),
                "RDI_LIBDIR": str(root / "lib/win64.o"), "RDI_BINDIR": str(root / "bin"),
                "RDI_PLATFORM": "win64", "RDI_OPT_EXT": ".o", "HDI_APPROOT": str(root),
                "TCL_LIBRARY": str(root / "tps/tcl/tcl8.5")})
    return env


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=PROJECT)
    parser.add_argument("--vivado", type=Path, default=VIVADO)
    args = parser.parse_args()
    base = args.project / "validation/keypad_agent_sim"
    run_dir = base / (datetime.now().astimezone().strftime("run_%Y%m%d_%H%M%S") + f"_{os.getpid()}")
    snapshots = run_dir / "sources"
    snapshots.mkdir(parents=True)
    report = {"status": "RUNNING", "started": datetime.now().astimezone().isoformat(),
              "run_directory": str(run_dir), "tests": [], "scope": "matrix_keypad.v only"}
    log_lines: list[str] = []
    source_records: list[dict] = []

    def log(message: str) -> None:
        print(message, flush=True)
        log_lines.append(message)
        (run_dir / "results.log").write_text("\n".join(log_lines) + "\n", encoding="utf-8")

    def snapshot(source: Path, name: str | None = None) -> Path:
        data = source.read_bytes()
        destination = snapshots / (name or source.name)
        destination.write_bytes(data)
        source_records.append({"path": str(source.resolve()), "snapshot": str(destination),
                               "sha256": sha256(data), "bytes": len(data)})
        return destination

    binpath = args.vivado / "bin/unwrapped/win64.o"
    env = vivado_environment(args.vivado)

    def command(tool: str, tool_args: list[str], work: Path, label: str) -> tuple[int, str]:
        work.mkdir(parents=True, exist_ok=True)
        cmd = [str(binpath / (tool + ".exe")), *tool_args]
        log(f"RUN {label}: {tool}")
        record = {"argv": cmd, "cwd": str(work)}
        (work / (label + ".command.json")).write_text(json.dumps(record, indent=2), encoding="utf-8")
        completed = subprocess.run(cmd, cwd=work, env=env, capture_output=True, timeout=180)
        output = (completed.stdout + completed.stderr).decode("utf-8", errors="replace")
        (work / (label + ".log")).write_text(output, encoding="utf-8")
        return completed.returncode, output

    def simulate(work: Path, top: str, sources: list[Path], marker: str,
                 include: str | None = None, expected_failure: str | None = None) -> None:
        work.mkdir(parents=True, exist_ok=True)
        if include is not None:
            (work / "keypad_cst_map.vh").write_text(include, encoding="ascii")
        xvlog_args = ["-i", str(work), *map(str, sources)]
        for tool, tool_args in (("xvlog", xvlog_args),
                                ("xelab", [top, "-s", top + "_snapshot", "--timescale", "1ns/1ps", "--mt", "2"])):
            code, output = command(tool, tool_args, work, tool)
            if code:
                raise RuntimeError(f"{top} {tool} failed ({code}):\n{output[-4000:]}")
        code, output = command("xsim", [top + "_snapshot", "-runall"], work, "xsim")
        if expected_failure is None:
            if code or marker not in output or re.search(r"\bFatal:|\bFATAL|\bERROR:", output):
                raise RuntimeError(f"{top} simulation failed ({code}):\n{output[-5000:]}")
            lines = [line for line in output.splitlines() if line.startswith("PASS ") or marker in line]
            for line in lines:
                log(line)
            result = {"top": top, "status": "PASS", "marker": marker, "directory": str(work)}
        else:
            # XSim may return zero for $fatal: require the actual wrong-key
            # assertion and no final success marker, not merely a nonzero exit.
            if expected_failure not in output or marker in output:
                raise RuntimeError(f"Old-map sensitivity test did not fail as intended:\n{output[-4000:]}")
            log("PASS old R2/R3 constraint mapping is rejected by physical RTL event assertions")
            result = {"top": top, "status": "EXPECTED_FAILURE_PASS", "reason": expected_failure,
                      "directory": str(work)}
        report["tests"].append(result)

    try:
        rtl = snapshot(args.project / "src/matrix_keypad.v")
        cst = snapshot(args.project / "src/multi_tone.cst")
        tb = snapshot(args.project / "tests/tb_keypad_physical_map.v")
        snapshot(Path(__file__).resolve())
        mapping = pin_mapping(cst.read_text(encoding="utf-8-sig"))
        report["pin_mapping"] = mapping
        log("PASS CST pins -> physical rows [T11,M14,T12,J14] -> logical rows [0,1,2,3]")
        log("PASS CST columns [P11,R11,M15,J16] -> logical columns [0,1,2,3]")
        historical_sources = []
        for source, top, marker in HISTORICAL:
            original = snapshot(source, top + ".original.v")
            # Old testbenches predate virtual/suppress inputs. Tie them inactive
            # in private copies; preserve every historical assertion/stimulus.
            historical_text = original.read_text(encoding="utf-8-sig")
            if ".virtual_enable(" in historical_text or ".suppress_select(" in historical_text:
                raise ValueError(f"Historical port assumptions changed: {source}")
            historical_text = historical_text.replace(".clk(clk)",
                ".virtual_enable(1'b0),.virtual_keys(16'd0),.suppress_select(1'b0),.clk(clk)", 1)
            adapted = snapshots / (top + ".v")
            adapted.write_text(historical_text, encoding="utf-8")
            source_records.append({"path": "generated historical inactive-input tie-offs",
                                   "snapshot": str(adapted), "sha256": sha256(adapted.read_bytes()),
                                   "bytes": adapted.stat().st_size})
            historical_sources.append((adapted, top, marker))
        (run_dir / "sourcehash.json").write_text(json.dumps(source_records, indent=2), encoding="utf-8")
        simulate(run_dir / "physical", "tb_keypad_physical_map", [rtl, tb],
                 "KEYPAD_PHYSICAL_MAP_TEST_PASS", map_include(mapping))
        for source, top, marker in historical_sources:
            simulate(run_dir / top, top, [rtl, source], marker)
        old_map = dict(mapping, rows=[0, 2, 1, 3])
        simulate(run_dir / "old_row_map_negative", "tb_keypad_physical_map", [rtl, tb],
                 "KEYPAD_PHYSICAL_MAP_TEST_PASS", map_include(old_map), "S5 event counts")
        for item in source_records:
            if item["path"].startswith("generated "):
                continue
            if sha256(Path(item["path"]).read_bytes()) != item["sha256"]:
                raise RuntimeError(f"Source changed during isolated simulation: {item['path']}")
        report["source_hashes_verified_at_finish"] = True
        report["status"] = "PASS"
        log("KEYPAD_AGENT_ALL_TESTS_PASS")
    except Exception as exc:
        report["status"] = "FAIL"
        report["error"] = str(exc)
        log("FAIL " + str(exc))
    finally:
        report["finished"] = datetime.now().astimezone().isoformat()
        if not (run_dir / "sourcehash.json").exists():
            (run_dir / "sourcehash.json").write_text(json.dumps(source_records, indent=2), encoding="utf-8")
        (run_dir / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        base.mkdir(parents=True, exist_ok=True)
        (base / "latest.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"RESULT {run_dir / 'results.json'}", flush=True)
        print(f"SOURCEHASH {run_dir / 'sourcehash.json'}", flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
