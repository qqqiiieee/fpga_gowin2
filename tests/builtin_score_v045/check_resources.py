"""Optional isolated guide/renderer Gowin-family mapping with local YoWASP.

This is NOT vendor synthesis, packing, place/route, timing closure or an
instrument build. It measures the two modules only, with all output ports live.
All snapshots, transformed test inputs, logs and tool caches stay in this folder.
Requires already-present tests/custom_score/tool_deps; installs nothing.
"""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TOOL = Path("D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin")


def main():
    out = HERE / "resources" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    out.mkdir(parents=True)
    env = dict(os.environ, PATH=str(TOOL) + os.pathsep + os.environ.get("PATH", ""),
               PYTHONDONTWRITEBYTECODE="1", YOWASP_CACHE_DIR=str(HERE / "yosys_cache"))
    # No imports of the dependency tree in the parent: python -B below and the
    # task-owned cache override also constrain all optional tool-side writes.
    driver = out / "driver.py"
    driver.write_text("import os, struct, sys\n"
        "os.environ.setdefault('PROCESSOR_ARCHITECTURE', 'AMD64' if struct.calcsize('P')==8 else 'x86')\n"
        f"sys.path.insert(0, {str(ROOT / 'tests/custom_score/tool_deps')!r})\n"
        "import yowasp_yosys\nraise SystemExit(yowasp_yosys.run_yosys(sys.argv[1:]))\n", encoding="utf-8")
    files = ["src/piano_roll_guide.v", "src/piano_roll_renderer.v", "src/piano_roll_score.v",
             "src/piano_builtin_score_ram.v", "src/custom_score_ram.v",
             "src/piano_builtin_score.hex", "src/piano_layout.vh", "src/piano_song_rom_v045.vh"]
    inputs = {name: (ROOT / name).read_bytes() for name in files}
    harness = (ROOT / "tests/custom_score/resource_top.v").read_text(encoding="utf-8")
    # Independent pixel/source inputs avoid optimizing away one clock-domain
    # ROM; expose ready too, because parent guide modes consume that signal.
    harness = harness.replace("output active,done,valid,countin,pulse,", "output active,done,valid,countin,pulse,ready,")
    harness = harness.replace(".expected_valid(valid),", ".expected_valid(valid),.score_ready(ready),")
    results = []
    report = dict(passed=False, vendor_synthesis=False, packing=False, timing=False,
                  production_build=False, programming=False, publication=False,
                  source_sha256={k: hashlib.sha256(v).hexdigest() for k, v in inputs.items()},
                  cases=results)
    def execute(name, argv, cwd):
        p = subprocess.run(list(map(str, argv)), cwd=cwd, env=env, capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=240)
        (cwd / f"{name}.log").write_text(p.stdout + p.stderr, encoding="utf-8")
        if p.returncode:
            raise RuntimeError(f"{name}: exit={p.returncode}; see {cwd / (name + '.log')}")
    try:
        for enabled in (0, 1):
            work = out / f"library_{enabled}"
            work.mkdir()
            for name, data in inputs.items():
                dest = work / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
            (work / "core.v").write_text(harness.replace(".CUSTOM_SCORE_ENABLE(ENABLE)",
                f".CUSTOM_SCORE_ENABLE(ENABLE),.SONG_LIBRARY_ENABLE({enabled})"), encoding="utf-8")
            # Dump actual RTL geometry rather than recreate it; Wasm frontend
            # expansion of the old nested init loops is unnecessarily costly.
            (work / "dump.v").write_text('`timescale 1ns/1ps\nmodule dump;\n'
                'piano_roll_renderer dut();\ninitial begin #1;'
                '$writememh("geometry.hex",dut.geometry);$finish;end\nendmodule\n', encoding="utf-8")
            execute("geometry_compile", [TOOL / "iverilog.exe", "-g2001", "-s", "dump", "-o", "dump.vvp",
                "src/piano_roll_renderer.v", "src/piano_roll_score.v", "dump.v"], work)
            execute("geometry_dump", [TOOL / "vvp.exe", "dump.vvp"], work)
            renderer = work / "src/piano_roll_renderer.v"
            code = renderer.read_text(encoding="utf-8")
            first = code.index("    initial begin\n")
            last = code.index("    wire [8:0] ahead=", first)
            renderer.write_text(code[:first] + '    initial $readmemh("geometry.hex",geometry);\n' + code[last:], encoding="utf-8")
            (work / "check.ys").write_text("read_verilog -I. " + " ".join(f for f in files if f.endswith(".v")) + " core.v\n"
                "hierarchy -check -top custom_score_resource_core\nproc\nopt\nmemory_dff\nmemory_collect\n"
                "write_json before_mapping.json\n"
                "synth_gowin -top custom_score_resource_core -family gw2a -noiopads -nowidelut -no-rw-check\n"
                "write_json mapped.json\nstat\n", encoding="utf-8")
            print(f"resource library={enabled}: mapping frozen modules", flush=True)
            execute("yosys", [sys.executable, "-B", driver, "-Q", "-T", "-s", "check.ys"], work)
            before = json.loads((work / "before_mapping.json").read_text())
            mapped = json.loads((work / "mapped.json").read_text())
            kinds = [c["type"] for m in before["modules"].values() for c in m.get("cells", {}).values()]
            counts = Counter(c["type"] for c in mapped["modules"]["custom_score_resource_core"]["cells"].values())
            memories = []
            for modname, module in before["modules"].items():
                for name, cell in module.get("cells", {}).items():
                    if cell["type"] == "$mem_v2":
                        p = cell["parameters"]
                        memories.append(dict(module=modname, name=name, width=int(p["WIDTH"], 2),
                            size=int(p["SIZE"], 2), synchronous_read=int(p["RD_CLK_ENABLE"], 2)))
            divmods = sum(k in ("$div", "$mod", "$divfloor", "$modfloor") for k in kinds)
            assert divmods == 0, "runtime division/modulo inferred"
            if enabled:
                builtin = [m for m in memories if "piano_builtin_score_ram" in m["module"]]
                assert builtin and all(m["size"] == 1024 and m["synchronous_read"] for m in builtin), builtin
                assert not any("piano_roll_score" in name for name in before["modules"]), "legacy decoder remains"
            results.append(dict(enabled=enabled, cell_counts=dict(counts), memories=memories,
                runtime_div_mod_cells=divmods, directory=str(work), geometry_hex_sha256=hashlib.sha256((work / "geometry.hex").read_bytes()).hexdigest()))
            print(f"resource library={enabled}: {dict(counts)}", flush=True)
        report["inputs_unchanged"] = all((ROOT / k).read_bytes() == v for k, v in inputs.items())
        report["passed"] = report["inputs_unchanged"]
    except Exception as exc:
        report["error"] = str(exc)
        raise
    finally:
        report["result_directory"] = str(out)
        text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        (out / "report.json").write_text(text, encoding="utf-8")
        (HERE / "resource_report.json").write_text(text, encoding="utf-8")
    print(f"BUILTIN_RESOURCE_PASS results={out}")


if __name__ == "__main__":
    main()
