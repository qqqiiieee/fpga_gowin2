"""V021 Hub短回归：真实UART、公共边界、K1挂起请求、参数0兼容。

默认：1MHz快速Hub矩阵 + 原27MHz UART比例的音量/弯音旧回归。
--production 另跑完整Hub矩阵的27MHz/864clk每位配置；不运行Gowin、不安装工具。
只读取工程输入。快照和vvp写系统临时目录并自动清理，不另写validation文件。
--json把完整报告（源/工具哈希、命令、返回码、断言输出）打印为UTF-8 JSON。
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
RTL = ("src/performance_input_hub.v", "src/midi_keyboard.v", "src/midi_uart_rx.v",
       "src/optical_strum.v", "src/strum_player.v")
CASES = {
    "hub_fast": ("tb_v021_hub_safety", ("-Ptb_v021_hub_safety.CLK_HZ=1000000",)),
    "hub_27mhz": ("tb_v021_hub_safety", ("-Ptb_v021_hub_safety.CLK_HZ=27000000",)),
    "legacy_expression": ("tb_midi_expression_controls", ()),
}
FAILURE = re.compile(r"(?im)^\s*(?:FATAL:|ERROR:)|\b\w*_TEST_FAIL\b")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(argv: list, cwd: Path, timeout: int) -> dict:
    started = time.monotonic()
    result = {"argv": [str(x) for x in argv], "timeout_seconds": timeout}
    try:
        p = subprocess.run(result["argv"], cwd=cwd, capture_output=True,
                           encoding="utf-8", errors="replace", timeout=timeout, check=False)
        result.update(returncode=p.returncode, stdout=p.stdout, stderr=p.stderr)
    except subprocess.TimeoutExpired as exc:
        def decode(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
        result.update(returncode=None, timed_out=True, stdout=decode(exc.stdout), stderr=decode(exc.stderr))
    except OSError as exc:
        result.update(returncode=None, error=str(exc))
    result["elapsed_seconds"] = round(time.monotonic()-started, 3)
    return result


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--production", action="store_true")
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()
    if args.timeout<1 or args.workers<1:
        parser.error("timeout和workers必须为正整数")
    chosen = list(dict.fromkeys(args.case or
                  (["hub_fast", "legacy_expression", "hub_27mhz"] if args.production else
                   ["hub_fast", "legacy_expression"])))
    runtime = ROOT / "tools/vendor/iverilog-v12/app/bin"
    suffix = ".exe" if os.name=="nt" else ""
    iverilog, vvp = runtime / ("iverilog"+suffix), runtime / ("vvp"+suffix)
    report = {"status": "fail", "started_utc": datetime.now(timezone.utc).isoformat(),
              "tests": [], "compile_configurations": [], "source_sha256": {},
              "write_scope": "仅系统临时目录；不改生产RTL/工程清单/验证目录",
              "synthesis_run": False, "hardware_tested": False}
    started = time.monotonic()
    try:
        if not iverilog.is_file() or not vvp.is_file():
            raise FileNotFoundError("工程已有Icarus不存在；不会安装工具")
        names = set(RTL) | {"scripts/run_v021_hub_safety.py"}
        names.update(f"tests/{CASES[c][0]}.v" for c in chosen)
        report["source_sha256"] = {p: sha256(ROOT / p) for p in sorted(names)}
        report["tools"] = {"iverilog": str(iverilog), "vvp": str(vvp),
                           "iverilog_sha256": sha256(iverilog), "vvp_sha256": sha256(vvp)}
        with tempfile.TemporaryDirectory(prefix="v021_hub_safety_") as folder:
            snapshot = Path(folder)
            for name, digest in report["source_sha256"].items():
                data = (ROOT / name).read_bytes()
                if hashlib.sha256(data).hexdigest()!=digest:
                    raise RuntimeError(f"快照输入变化：{name}")
                target = snapshot / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            # 覆盖MIDI关闭分支及参数0/1展开，检查输出单驱动重接没有漏支路。
            for midi in (0,1):
                for bank in (0,1):
                    argv = [iverilog, "-g2012", "-Wall", "-s", "performance_input_hub",
                            f"-Pperformance_input_hub.MIDI_ENABLE={midi}",
                            f"-Pperformance_input_hub.CONTROL_BANK_ENABLE={bank}",
                            "-o", snapshot / f"syntax_{midi}_{bank}.vvp", *[snapshot / p for p in RTL]]
                    c = run(argv, snapshot, args.timeout)
                    report["compile_configurations"].append({"midi":midi,"bank":bank,"compile":c})

            def test(name: str) -> dict:
                top, params = CASES[name]
                output = snapshot / (name+".vvp")
                argv = [iverilog,"-g2012","-Wall","-s",top,*params,"-o",output,
                        *[snapshot / p for p in RTL],snapshot / f"tests/{top}.v"]
                result = {"name":name,"status":"fail","compile":run(argv,snapshot,args.timeout)}
                if result["compile"].get("returncode")!=0:
                    return result
                result["run"] = run([vvp,output],snapshot,args.timeout)
                execution = result["run"]
                stdout = execution.get("stdout","")
                marker = ("V021_HUB_SAFETY_TEST_PASS" if top=="tb_v021_hub_safety" else
                          "MIDI_EXPRESSION_CONTROLS_TEST_PASS")
                if execution.get("returncode")==0 and marker in stdout and not FAILURE.search(
                        stdout+execution.get("stderr","")):
                    result["status"]="pass"
                return result

            with ThreadPoolExecutor(max_workers=min(args.workers,len(chosen))) as executor:
                report["tests"] = list(executor.map(test,chosen))
        report["source_stable"] = all((ROOT / p).is_file() and sha256(ROOT / p)==digest
                                      for p,digest in report["source_sha256"].items())
        if (report["source_stable"] and all(t["status"]=="pass" for t in report["tests"]) and
                all(c["compile"].get("returncode")==0 for c in report["compile_configurations"])):
            report["status"]="pass"
    except (OSError, RuntimeError) as exc:
        report["error"]=repr(exc)
    report["elapsed_seconds"]=round(time.monotonic()-started,3)
    report["finished_utc"]=datetime.now(timezone.utc).isoformat()
    if args.json:
        print(json.dumps(report,ensure_ascii=False,indent=2))
    else:
        for item in report["tests"]:
            print("CASE",item["name"],item["status"].upper())
            for phase in ("compile","run"):
                if phase in item:
                    print(item[phase].get("stdout","").strip())
                    if item[phase].get("stderr"):
                        print(item[phase]["stderr"].strip())
        if report.get("error"):
            print(report["error"])
        print("V021_HUB_SAFETY",report["status"].upper(),
              "source_stable="+str(report.get("source_stable")),
              "hub_sha256="+report["source_sha256"].get("src/performance_input_hub.v",""),
              "seconds="+str(report["elapsed_seconds"]))
    return 0 if report["status"]=="pass" else 1


if __name__=="__main__":
    sys.exit(main())
