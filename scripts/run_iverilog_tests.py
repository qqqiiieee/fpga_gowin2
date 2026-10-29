"""Offline Icarus RTL regression, using immutable input copies and per-case logs.

No downloads, hardware access, Vivado, Gowin builds, or global PATH changes.
Use --list to inspect cases. UI oracle generation additionally needs Pillow;
--oracle-python can select an existing Python interpreter containing Pillow.
"""
from __future__ import annotations

import argparse
import ast
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GOWIN = Path("D:/Gowin_V1.9.12.04_x64_win/Gowin/Gowin_V1.9.12.04_x64")
CORE = ["tb_synth_equivalence", "tb_audio_hdmi_equivalence", "tb_reliable_controls",
        "tb_reliable_cadence", "tb_remote_link", "tb_instrument_telemetry", "tb_wave_scope",
        "tb_oscillator_test_control", "tb_oscillator_audio", "tb_oscillator_integration",
        "tb_menu_top", "tb_tmds_encoder", "tb_video_timing", "tb_hdmi_link"]
BOUNDARIES = ["tb_handoff_selector_ghost", "tb_handoff_selector_source",
              "tb_handoff_audio_return", "tb_handoff_audio_first_tick", "tb_handoff_ui_hold_1",
              "tb_handoff_ui_hold_0", "tb_handoff_ui_hold_200000", "tb_handoff_diag_exit",
              "tb_handoff_production_return"]
EXTRAS = {
    "tb_synth_equivalence": ["legacy_shared_synth.v", "legacy_diagnostic_frequency.v"],
    "tb_audio_hdmi_equivalence": ["baseline_audio_top.v", "baseline_instrument_audio.v"],
    "tb_reliable_cadence": ["mock_ads1115.v"],
    "tb_remote_top": ["legacy_top.v", "legacy_audio_controls.v", "mock_ads1115_optional.v"],
    "tb_hdmi_normal_miter": ["golden_dashboard.v"],
    "tb_dashboard_resource_equivalence": ["fixtures/v015_dashboard_reference.v"],
    "tb_tmds_encoder": ["fixtures/iverilog_tmds_startup.v"],
    "tb_instrument_telemetry": ["fixtures/iverilog_telemetry_startup.v"],
}
FAILURE = re.compile(r"(?im)^\s*(?:FATAL:|ERROR:|Fatal:)|\b\w*_TEST_FAIL\b")


@dataclass
class Case:
    top: str
    group: str
    name: str = ""
    params: dict = field(default_factory=dict)
    plusargs: tuple = ()
    expected_failure: str = ""
    marker: str = ""

    def __post_init__(self):
        self.name = self.name or self.top
        self.marker = self.marker or self.top.removeprefix("tb_").upper() + "_TEST_PASS"


def catalog():
    cases = [Case(t, "core") for t in CORE]
    cases += [Case("tb_keypad_physical_map", "keypad"),
              Case("tb_performance_keys", "keypad"), Case("tb_noise_selectors", "keypad"),
              # 新生产语义单独断言；历史bench继续使用默认16，绝不改写旧预期。
              Case("tb_timbre2_keypad", "keypad"), Case("tb_timbre2_inputs", "keypad"),
              Case("tb_keypad_physical_map", "keypad", "keypad_old_row_map_negative",
                   expected_failure="S5 event counts")]
    for beat in [0, 1, 3, 7, 16, 100, 46875]:
        cases.append(Case("tb_song_library", "song", f"tb_song_library_b{beat}",
                          {"TEST_BEAT_SAMPLES": beat, "FULL_TIMING": int(beat != 46875)}))
    for beat in [1, 3, 16, 46875]:
        cases.append(Case("tb_song_guide", "song", f"tb_song_guide_b{beat}",
                          {"TEST_BEAT_SAMPLES": beat}))
    cases.append(Case("tb_song_pause", "song"))
    cases += [Case("tb_instrument_ui_control", "ui"), Case("tb_menu_cdc", "ui"),
              Case("tb_menu_preview", "ui", plusargs=("CHECKS_ONLY",))]
    cases += [Case(t, "boundaries") for t in BOUNDARIES]
    # These potentially long display comparisons are explicit opt-ins. The
    # coordinating display agent may already be running them independently.
    cases += [Case("tb_ui_lookup_equivalence", "display"), Case("tb_timbre2_ui", "display"),
              Case("tb_dashboard_resource_equivalence", "display")]
    return cases


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def find_tool(explicit, name, project):
    if explicit:
        candidate = explicit.expanduser().resolve()
        if candidate.is_dir():
            candidate /= name + (".exe" if os.name == "nt" else "")
        if not candidate.is_file():
            raise FileNotFoundError(f"Missing {name}: {candidate}")
        return candidate
    executable = name + (".exe" if os.name == "nt" else "")
    candidates = [project / "tools/vendor/iverilog-v12/app/bin" / executable]
    candidates += sorted((project / "tools/vendor").glob(f"*/bin/{executable}"))
    candidates += sorted((project / "tools/vendor").glob(f"*/app/bin/{executable}"))
    found = shutil.which(name)
    if found:
        candidates.append(Path(found))
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise FileNotFoundError(f"No {name}; specify --{name}. No tools are installed automatically.")


def command(argv, work, label, timeout, env):
    log = work / (label + ".log")
    record = {"argv": [str(a) for a in argv], "cwd": str(work), "timeout_seconds": timeout}
    started = time.monotonic()
    with log.open("wb") as output:
        try:
            proc = subprocess.Popen(record["argv"], cwd=work, env=env,
                                    stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT)
            try:
                record["returncode"] = proc.wait(timeout=timeout)
                record["timed_out"] = False
            except subprocess.TimeoutExpired:
                # iverilog may spawn ivl/ivlpp. End its process tree as well.
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                                   capture_output=True, timeout=15)
                else:
                    proc.kill()
                proc.wait(timeout=15)
                record.update(returncode=proc.returncode, timed_out=True)
        except OSError as exc:
            record.update(returncode=None, timed_out=False, launch_error=str(exc))
    record.update(elapsed_seconds=round(time.monotonic() - started, 3), log=str(log))
    write_json(work / (label + ".command.json"), record)
    return record, log.read_text(encoding="utf-8", errors="replace")


def keypad_include(cst, negative):
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", cst.read_text(encoding="utf-8-sig"), flags=re.S)
    lines = ["// Private Icarus fixture: validated against the snapshotted CST."]
    for kind, letter, pins in [("rows", "R", ["T11", "M14", "T12", "J14"]),
                               ("cols", "C", ["P11", "R11", "M15", "J16"])]:
        entries = re.findall(r'IO_LOC\s+"matrix_' + kind + r'\[(\d+)\]"\s+([A-Z]\d+)\s*;', text)
        if len(entries) != 4 or len({p for _, p in entries}) != 4:
            raise ValueError(f"Incomplete/duplicate matrix {kind} constraints: {entries}")
        mapping = {pin: int(i) for i, pin in entries}
        indices = [mapping[p] for p in pins]
        if indices != [0, 1, 2, 3]:
            raise ValueError(f"Physical {kind} wires disagree with CST: {indices}")
        if negative and kind == "rows":
            indices = [0, 2, 1, 3]
        lines += [f"`define CST_PHYSICAL_{letter}{i+1} {n}" for i, n in enumerate(indices)]
    return "\n".join(lines) + "\n"


def ui_oracle(work):
    """Reuse only the independent oracle definitions, never the XSim driver."""
    from PIL import Image, ImageDraw
    source = work / "inputs/menu_tests.py"
    tree = ast.parse(source.read_text(encoding="utf-8-sig"))
    names = {"PALETTE", "SCENES", "GLYPHS"}
    nodes = []
    for node in tree.body:
        if isinstance(node, (ast.ClassDef, ast.FunctionDef)) and node.name in {"Oracle", "color"}:
            nodes.append(node)
        elif isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in names
                                                  for t in node.targets):
            nodes.append(node)
    namespace = {"Image": Image, "ImageDraw": ImageDraw, "json": json, "re": re}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), namespace)
    count = namespace["Oracle"](work).artifacts(work)
    print(f"INDEPENDENT_UI_ORACLE_READY vectors={count}", flush=True)


def source_selection(case, work):
    top = case.top
    rtl = sorted((work / "src").glob("*.v"))
    if top == "tb_ui_lookup_equivalence":
        rtl = []
    elif top in {"tb_dashboard_resource_equivalence", "tb_timbre2_ui"}:
        rtl = [work / "src" / (n + ".v") for n in ["hdmi_instrument_dashboard", "hdmi_ui_font"]]
    elif top == "tb_timbre2_inputs":
        # 使用真实生产输入模块及其依赖，保持下方keypad组的单模块历史隔离。
        rtl = [work / "src" / (n + ".v") for n in [
            "instrument_inputs", "matrix_keypad", "remote_debug_link", "headphone_mute_guard",
            "ads1115_reader", "i2c_byte_master", "i2c_bus_recovery", "slider_controls", "pressure_adaptive"]]
    elif top.startswith("tb_song_"):
        rtl = [work / "src/song_guide.v"]
    elif case.group == "keypad":
        rtl = [work / "src/matrix_keypad.v"]
    elif top == "tb_menu_preview":
        rtl = [work / "src" / (n + ".v") for n in ["hdmi_instrument_dashboard", "hdmi_ui_font"]]
    elif top == "tb_menu_cdc":
        # This existing bench already defines test-only hdmi_clocks/hdmi_tx.
        rtl = [p for p in rtl if p.stem not in {"hdmi_clocks", "hdmi_tx"}]
    filename = ("tb_handoff_boundaries" if top.startswith("tb_handoff_") else
                "tb_hdmi_test_preview" if top == "tb_hdmi_test_cdc" else top)
    bench = work / "tests" / (filename + ".v")
    sources = [work / "tests/fixtures/iverilog_timescale.v", *rtl, bench,
               *(work / "tests" / n for n in EXTRAS.get(top, []))]
    return sources, bench


def run_case(case, run, snapshot, args, iv, vvp, env):
    work = run / "cases" / case.name
    work.mkdir(parents=True)
    result = {"top": case.top, "group": case.group, "status": "FAIL", "stage": "fixtures",
              "directory": str(work), "marker": case.marker, "parameters": case.params,
              "plusargs": list(case.plusargs), "adaptations": [], "commands": []}
    started = time.monotonic()
    try:
        for name in ["src", "tests"]:
            shutil.copytree(snapshot / name, work / name)
        if (work / "tests/fixtures").is_dir():
            shutil.copytree(work / "tests/fixtures", work / "fixtures")
        vectors = work / "tests/tmds_vectors.hex"
        if vectors.is_file():
            shutil.copy2(vectors, work / vectors.name)
        if case.top == "tb_keypad_physical_map":
            (work / "keypad_cst_map.vh").write_text(
                keypad_include(work / "src/multi_tone.cst", bool(case.expected_failure)), encoding="ascii")
            result["adaptations"].append("Generated physical CST map; row 2/3 swap only in negative case")
        sources, bench = source_selection(case, work)
        if case.top == "tb_audio_hdmi_equivalence":
            # XSim原驱动通过xelab --timescale 1ns/1ps提供默认时间单位。
            # 此旧bench自身没有timescale，Icarus的独立源文件会退回秒单位，
            # 使27MHz时钟和Gowin PLL模型不匹配。仅在隔离副本补相同时间基准；
            # 不修改任何输入向量、比较、超时数值或生产RTL。
            text = bench.read_text(encoding="utf-8-sig")
            if "`timescale" not in text:
                bench.write_text("`timescale 1ns/1ps\n" + text, encoding="utf-8")
                result["adaptations"].append("Legacy audio/HDMI bench explicitly uses XSim's 1ns/1ps default timebase")
        if case.top in {"tb_performance_keys", "tb_noise_selectors"}:
            text = bench.read_text(encoding="utf-8-sig")
            if ".virtual_enable(" in text or ".suppress_select(" in text or text.count(".clk(clk)") != 1:
                raise ValueError("Historical keypad tie-off assumptions changed; inspect bench")
            bench.write_text(text.replace(".clk(clk)", ".virtual_enable(1'b0),.virtual_keys(16'd0),"
                                          ".suppress_select(1'b0),.clk(clk)", 1), encoding="utf-8")
            result["adaptations"].append("Private historical bench copy: inactive virtual/suppress ports, as keypad_tests.py")
        if case.top == "tb_synth_equivalence":
            # Bench explicitly requires the same V008 stress wave for both engines,
            # but hardcodes two different paths. Correct only the private ROM input.
            words = (work / "fixtures/pressure_wave.hex").read_text(encoding="ascii").split()
            if len(words) != 32768 or any(not re.fullmatch(r"[0-9a-fA-F]{1,4}", w) for w in words):
                raise ValueError("Expected 32 x 1024 plain hex words in the V008 stress fixture")
            (work / "src/timbre_soft.hex").write_text("\n".join(words[:16384]) + "\n", encoding="ascii")
            result["adaptations"].append("Private src/timbre_soft.hex = first 16 banks of frozen pressure_wave.hex; legacy retains all 32 banks")
        if case.top == "tb_menu_preview":
            (work / "inputs").mkdir()
            for name in ["menu_layout.json", "ui_font_map.json"]:
                shutil.copy2(snapshot / "assets" / name, work / "inputs" / name)
            shutil.copy2(snapshot / "scripts/menu_tests.py", work / "inputs/menu_tests.py")
            py = args.oracle_python or Path(sys.executable)
            if not args.oracle_python and importlib.util.find_spec("PIL") is None:
                bundled = Path.home() / ".cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe"
                if bundled.is_file():
                    py = bundled
            record, output = command([py, snapshot / "scripts/run_iverilog_tests.py", "--generate-ui-oracle", work],
                                     work, "oracle", args.compile_timeout, env)
            result["commands"].append(record)
            if record["returncode"] != 0 or record["timed_out"] or "INDEPENDENT_UI_ORACLE_READY" not in output:
                raise RuntimeError("Independent UI oracle generation failed: " + output[-3000:])
            result["adaptations"].append("Independent Oracle from unchanged menu_tests.py + layout/font assets; CHECKS_ONLY")
        for index, item in enumerate(args.extra_fixture):
            source = snapshot / "extra_fixtures" / f"{index}_{item.name}"
            target = work / "extra_fixtures" / source.name
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(source, target)
            sources.append(target)
        for p in sources:
            if not p.is_file():
                raise FileNotFoundError(p)
        # Capture every input AFTER private adaptations and BEFORE simulator output.
        hashes = {p.relative_to(work).as_posix(): digest(p) for p in work.rglob("*") if p.is_file()}
        result["input_hashes"] = hashes
        result["sources"] = [p.relative_to(work).as_posix() for p in sources]
        write_json(work / "sourcehash.json", hashes)
        # The original XSim driver treats this legacy bench as Verilog, where
        # its variable named 'weak' is legal; it is a SystemVerilog keyword.
        language = "2005" if case.top == "tb_reliable_controls" else "2012"
        result["language"] = language
        flags = ["-g" + language, "-I", str(work), "-I", str(work / "src"), "-s", case.top,
                 "-o", "simulation.vvp"]
        if case.top == "tb_tmds_encoder":
            flags += ["-s", "iverilog_tmds_startup"]
            result["adaptations"].append("Pre-reset bench data settle via independent iverilog_tmds_startup top")
        if case.top == "tb_instrument_telemetry":
            flags += ["-s", "iverilog_telemetry_startup"]
            result["adaptations"].append("Pre-reset bench keys settle via independent iverilog_telemetry_startup top")
        for name, value in case.params.items():
            flags += ["-P", f"{case.top}.{name}={value}"]
        result["stage"] = "compile"
        argv = [iv, *flags, *sources]
        record, output = command(argv, work, "compile", args.compile_timeout, env)
        result["commands"].append(record)
        result["vendor_primitives"] = False
        # Enable the large vendor library only if elaboration actually reports
        # missing module types that the real gw2a library supplies.
        missing = set(re.findall(r"Unknown module type:\s*(\w+)", output))
        if missing and not record["timed_out"]:
            primitive = args.gowin_home / "IDE/simlib/gw2a/prim_sim.v"
            if primitive.is_file():
                available = set(re.findall(r"\bmodule\s+(\w+)", primitive.read_text(errors="replace")))
                if missing <= available:
                    target = work / "vendor/prim_sim.v"
                    target.parent.mkdir()
                    shutil.copy2(primitive, target)
                    result["vendor_primitives"] = True
                    result["primitive_source"] = str(primitive)
                    hashes["vendor/prim_sim.v"] = digest(target)
                    result["sources"].append("vendor/prim_sim.v")
                    write_json(work / "sourcehash.json", hashes)
                    record, output = command([iv, *flags, "-gspecify", *sources, target], work,
                                             "compile_vendor", args.compile_timeout, env)
                    result["commands"].append(record)
        if record["timed_out"] or record["returncode"] != 0:
            raise RuntimeError("Icarus compilation timed out" if record["timed_out"] else
                               "Icarus compile/elaboration failed: " + output[-3500:])
        result["stage"] = "simulate"
        record, output = command([vvp, "-i", "-n", "simulation.vvp", *("+" + a for a in case.plusargs)],
                                 work, "simulate", args.timeout, env)
        result["commands"].append(record)
        if record["timed_out"]:
            raise RuntimeError(f"Simulation exceeded {args.timeout}s; see simulate.log")
        if case.expected_failure:
            if record["returncode"] in (None, 0) or case.expected_failure not in output or case.marker in output:
                raise RuntimeError("Negative control did not reject the intended physical mapping: " + output[-2500:])
            result.update(status="EXPECTED_FAILURE_PASS", expected_failure=case.expected_failure)
        else:
            if record["returncode"] != 0 or FAILURE.search(output) or case.marker not in output:
                raise RuntimeError("Simulation assertion/tool failure or missing final PASS marker: " + output[-3500:])
            result["status"] = "PASS"
        result["pass_markers"] = [line for line in output.splitlines() if case.marker in line]
        result["input_hashes_verified_at_finish"] = all(
            (work / name).is_file() and digest(work / name) == sha for name, sha in hashes.items())
        if not result["input_hashes_verified_at_finish"]:
            raise RuntimeError("Private case inputs changed during simulation")
        result["stage"] = "complete"
    except Exception as exc:
        result["reason"] = str(exc)
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    write_json(work / "result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--group", choices=["core", "keypad", "song", "ui", "boundaries", "display", "all"], default="core")
    parser.add_argument("--tests", nargs="+", help="Explicit top/case names; does not run other cases")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--iverilog", type=Path)
    parser.add_argument("--vvp", type=Path)
    parser.add_argument("--gowin-home", type=Path, default=Path(os.environ.get("GOWIN_HOME", DEFAULT_GOWIN)))
    parser.add_argument("--output", type=Path, help="Parent for a new unique run directory")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=1200)
    parser.add_argument("--compile-timeout", type=float, default=120)
    parser.add_argument("--oracle-python", type=Path, help="Existing Python with Pillow (only needed by menu preview)")
    parser.add_argument("--extra-fixture", type=Path, action="append", default=[], help="Additional HDL source; repeatable")
    parser.add_argument("--generate-ui-oracle", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.generate_ui_oracle:
        ui_oracle(args.generate_ui_oracle.resolve())
        return 0
    if args.jobs < 1 or min(args.timeout, args.compile_timeout) <= 0:
        parser.error("jobs and timeouts must be positive")
    cases = catalog()
    if args.tests:
        selected = [c for c in cases if c.name in args.tests or c.top in args.tests]
        for name in args.tests:
            if not any(c.name == name or c.top == name for c in selected):
                if not re.fullmatch(r"tb_[A-Za-z0-9_]+", name):
                    parser.error(f"Invalid test name: {name}")
                selected.append(Case(name, "explicit", marker={
                    "tb_hdmi_live_preview": "HDMI_LIVE_PREVIEW_PASS",
                    "tb_hdmi_normal_miter": "HDMI_NORMAL_BASELINE_MITER_PASS",
                }.get(name, "")))
    else:
        selected = [c for c in cases if c.group == args.group or
                    (args.group == "all" and c.group != "display")]
    if args.list:
        for c in selected:
            print(f"{c.group:10s} {c.name:40s} top={c.top} parameters={c.params}")
        return 0
    project = args.project.resolve()
    # Resolve a matching sibling runtime when an external compiler is specified.
    iv = find_tool(args.iverilog, "iverilog", project)
    runtime = args.vvp or (iv.parent / ("vvp.exe" if os.name == "nt" else "vvp"))
    vvp = find_tool(runtime, "vvp", project)
    args.gowin_home = args.gowin_home.resolve()
    base = (args.output or project / "validation/iverilog").resolve()
    run = base / (datetime.now().strftime("run_%Y%m%d_%H%M%S_%f") + f"_{os.getpid()}")
    run.mkdir(parents=True)
    snapshot = run / "snapshot"
    snapshot.mkdir()
    report = {"status": "RUNNING", "project": str(project), "group": args.group,
              "run_directory": str(run), "started_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "RTL simulation and explicit test models only; no hardware or synthesis",
              "language": "Icarus -g2012, legacy reliable_controls -g2005; explicit -s top per case", "tests": {},
              "excluded_from_all": "display miter/lookup are opt-in; host tests are not run"}
    env = os.environ.copy()
    env["PATH"] = str(iv.parent) + os.pathsep + str(vvp.parent) + os.pathsep + env.get("PATH", "")
    try:
        for tool, path in [("iverilog", iv), ("vvp", vvp)]:
            record, output = command([path, "-V"], run, tool + "_version", 20, env)
            report[tool] = {"path": str(path), "sha256": digest(path), "version": output.splitlines()[:2]}
            if record["returncode"] != 0 or record["timed_out"]:
                raise RuntimeError(f"Cannot start {tool}: {output}")
        originals = {}
        for directory in ["src", "tests", "assets"]:
            for source in sorted((project / directory).rglob("*")):
                if source.is_file() and "__pycache__" not in source.parts:
                    rel = source.relative_to(project)
                    target = snapshot / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    data = source.read_bytes()
                    target.write_bytes(data)
                    originals[rel.as_posix()] = hashlib.sha256(data).hexdigest()
        for filename in ["run_tests.py", "keypad_tests.py", "song_tests.py", "menu_tests.py"]:
            source = project / "scripts" / filename
            target = snapshot / "scripts" / filename
            target.parent.mkdir(exist_ok=True)
            target.write_bytes(source.read_bytes())
            originals[source.relative_to(project).as_posix()] = digest(target)
        shutil.copy2(Path(__file__).resolve(), snapshot / "scripts/run_iverilog_tests.py")
        report["extra_fixtures"] = []
        for index, item in enumerate(args.extra_fixture):
            source = item.resolve()
            target = snapshot / "extra_fixtures" / f"{index}_{item.name}"
            target.parent.mkdir(exist_ok=True)
            target.write_bytes(source.read_bytes())
            report["extra_fixtures"].append({"path": str(source), "snapshot": str(target), "sha256": digest(target)})
        report["runner_sha256"] = digest(snapshot / "scripts/run_iverilog_tests.py")
        report["source_hashes"] = originals
        write_json(run / "sourcehash.json", originals)
        write_json(run / "results.json", report)
        print(f"IVERILOG_READY {iv}\nRUN_DIRECTORY {run}", flush=True)
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = {pool.submit(run_case, c, run, snapshot, args, iv, vvp, env): c for c in selected}
            for future in as_completed(futures):
                case = futures[future]
                try:
                    result = future.result()
                except Exception as exc:
                    result = {"status": "FAIL", "stage": "runner", "reason": str(exc), "top": case.top}
                report["tests"][case.name] = result
                print(f"{result['status']} {case.name}" +
                      (f" [{result.get('stage')}] {result['reason'][-700:]}" if "reason" in result else ""), flush=True)
                write_json(run / "results.json", report)
        report["counts"] = {s: sum(t["status"] == s for t in report["tests"].values())
                            for s in ["PASS", "EXPECTED_FAILURE_PASS", "FAIL"]}
        report["status"] = "FAIL" if report["counts"]["FAIL"] else "PASS"
        changed = []
        for name, sha in originals.items():
            current = project / name
            if not current.is_file() or digest(current) != sha:
                changed.append(name)
        report["live_files_changed_since_snapshot"] = changed
        report["snapshot_hashes_verified_at_finish"] = all(digest(snapshot / n) == sha for n, sha in originals.items())
        if not report["snapshot_hashes_verified_at_finish"]:
            report.update(status="FAIL", error="Snapshot inputs changed during regression")
    except Exception as exc:
        report.update(status="FAIL", error=str(exc))
        print("RUNNER_FAIL", exc, file=sys.stderr, flush=True)
    finally:
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(run / "results.json", report)
        print(f"RESULT {run / 'results.json'}\nIVERILOG_GROUP_{report['status']} {report.get('counts', {})}", flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
