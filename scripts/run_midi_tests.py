"""MIDI独立串行端到端回归；只写validation/midi_agent.json，中间产物放系统临时目录。

运行示例：py scripts/run_midi_tests.py；--case可选择单个bench，--list列出用例。
默认用本工程tools/vendor的Icarus，不调用Gowin，不烧录，不发布。
每次先复制本代理拥有的源码与测试到不可变输入快照，再并行编译/运行。
报告保存源哈希、工具哈希、完整命令、退出码、实际断言输出与未测边界。
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
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CASES = ["tb_midi_uart_rx", "tb_midi_keyboard", "tb_midi_release", "tb_midi_production"]
SOURCES = ["src/midi_uart_rx.v", "src/midi_keyboard.v", "tests/tb_midi_support.v",
           *[f"tests/{name}.v" for name in CASES], "scripts/run_midi_tests.py"]
FAILURE = re.compile(r"(?im)^\s*(?:FATAL:|ERROR:)|\b\w*_TEST_FAIL\b")


def digest(content):
    return hashlib.sha256(content).hexdigest()


def run(argv, cwd, timeout):
    started = time.monotonic()
    record = {"argv": [str(x) for x in argv], "timeout_seconds": timeout}
    try:
        process = subprocess.run(record["argv"], cwd=cwd, capture_output=True,
                                 encoding="utf-8", errors="replace", timeout=timeout)
        record.update(returncode=process.returncode, stdout=process.stdout, stderr=process.stderr)
    except subprocess.TimeoutExpired as exc:
        def readable(value):
            return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
        record.update(returncode=None, timed_out=True, stdout=readable(exc.stdout), stderr=readable(exc.stderr))
    except OSError as exc:
        record.update(returncode=None, error=str(exc))
    record["elapsed_seconds"] = round(time.monotonic()-started, 3)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if args.list:
        print("\n".join(CASES))
        return 0
    chosen = list(dict.fromkeys(args.case or CASES))
    runtime = ROOT / "tools/vendor/iverilog-v12/app/bin"
    suffix = ".exe" if os.name == "nt" else ""
    iverilog, vvp = runtime / ("iverilog"+suffix), runtime / ("vvp"+suffix)
    # Cloud Linux uses the distribution Icarus; bundled Windows binaries are excluded.
    if os.name != "nt":
        iverilog = Path(os.environ.get("IVERILOG") or shutil.which("iverilog") or "/missing/iverilog")
        vvp = Path(os.environ.get("VVP") or shutil.which("vvp") or "/missing/vvp")
    report = {
        "status": "fail", "source_stable": False, "project": str(ROOT),
        "started_utc": datetime.now(timezone.utc).isoformat(), "tests": [],
        "sources_sha256": {}, "full_suite": chosen == CASES,
        "write_scope": SOURCES + ["validation/midi_agent.json"],
        "contract": {
            "clock_hz": 27000000, "baud": 31250, "frame": "8N1",
            "hardware_path": "TINY+32 TRS Type A OUT -> BMV51M001 3.3V RX -> dedicated midi_rx",
            "usb_host": False, "melody_channel_zero_based": 0, "drum_channel_zero_based": 9,
            "fifo_depth": 16, "key_domain": [0, 127], "voice_limit_in_this_module": None,
            "handshake": "event_valid && event_ready在clk上升沿交付，背压时字段保持；panic/suppress入口明确撤销旧队列",
            "held_notes": "物理按住且已被本模块认可的主键；已松延音不包含在内",
            "release_scan_cycles_without_stall": 128,
            "release_scan_us_at_27mhz": 128/27,
            "release_backpressure": "待释放位图保留off，FIFO满时暂停扫描，串口/控制继续处理",
            "overflow": "实际新note事件无FIFO空间时sticky overflow并global panic；纯背压不报错",
            "panic": "单拍紧急全局静音；main需连接所有输入共用的音频局部reset，优先于旧事件",
            "panic_sources": ["FF", "FC", "主键通道CC120", "UART坏停止位/break", "FIFO真实溢出", "已武装ActiveSensing失联"],
            "panic_state": "清键/延音/队列/扫描；控制回默认并各打一拍valid；故障与接收计数保留",
            "parser_on_panic": "FC/CC120保留running status/实时半包；FF/链路错/溢出/超时要求新显式状态",
            "suppress": "只枚举释放已握手给下游的本来源音符，不global panic；期间音符/鼓静音，未松键禁止重触发",
            "velocity": "{v7,v7[6]}，0..255", "bend": "signed((14bit-8192)>>>5)，-256..255",
            "controllers": "PC0/1音色；CC7音量；CC1调制存7位；CC64延音；CC123清键/延音并升序off",
            "drums": "通道10；35/36 kick，38/40 snare；hit与8位力度同拍，下一拍清零",
            "active_sense_ms": 350, "active_sense": "首次FE武装；任何有效字节续期；超时panic后解除武装；参数0关闭",
            "received_count": "每个正确停止位的UART字节都计数，8位回绕，panic不清零",
            "sticky_faults": "framing_error/overflow仅rst_n清零",
            "uart_recovery": "坏帧/break后连续一位空闲高才重启；每段连续break只报一次",
            "malformed_stream": "新状态中止旧半包；system common清running status并正确消费长度；SysEx跳过，实时字节可插入"
        },
        "references": [
            {"url": "https://midi.org/summary-of-midi-1-0-messages", "verified": True,
             "note": "官方摘要ActiveSensing写300ms，本实现遵照用户参数350ms"},
            {"url": "https://web-file.midiplus.com/upload/202307/11/TINY%20%E7%94%A8%E6%88%B7%E5%86%8C.pdf", "verified": False,
             "note": "用户原链接不可读；通过厂家支持页定位下列正确中文手册"},
            {"url": "https://www.midiplus.com/upload/202307/11/TINY%20%E7%94%A8%E6%88%B7%E6%89%8B%E5%86%8C.pdf", "verified": True,
             "pdf_pages": 21, "sections": ["2.8", "2.9", "4.3"],
             "note": "Type A: Ring=MIDI4,Tip=MIDI5,Sleeve=MIDI2；旋钮默认CC93/91/71/74；Pad Bank A=36/37/38/39。通道和CC需实机配置核对。"}
        ],
        "hardware_tested": False, "gowin_started": False, "programmed_or_published": False,
        "limitations": [
            "仅独立RTL仿真；未运行整版Gowin综合/布局布线，未声称CLS/时序/亚稳态MTBF已验证。",
            "未接实体TINY/BMV51M001，未验证极性、接线、电气电平和实际键盘配置。",
            "main/inputs/audio/allocator/note_table/光电均由其他代理负责，本报告不声称它们集成通过。",
            "128槽释放4.741us仅在下游连续接收且无抢占时成立；背压会延后交付，但不会阻塞串口解析。",
            "MIDI无校验和；具有正确停止位的数据位翻转无法从8N1字节本身识别。",
            "半包在新状态/系统common/坏帧/复位时丢弃；协议未规定数据字节最大间隔，未额外添加半包空闲超时。",
            "控件在suppress期间继续解析并可产生控制valid；主键和鼓不会发起新的演奏音。"
        ]
    }
    started = time.monotonic()
    try:
        if not iverilog.is_file() or not vvp.is_file():
            raise FileNotFoundError("本工程tools/vendor下的Icarus运行时不存在")
        with tempfile.TemporaryDirectory(prefix="midi_agent_") as folder:
            snapshot = Path(folder)
            for relative in SOURCES:
                content = (ROOT / relative).read_bytes()
                report["sources_sha256"][relative] = digest(content)
                target = snapshot / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
            report["runtime"] = {"iverilog": str(iverilog), "vvp": str(vvp),
                                 "iverilog_sha256": digest(iverilog.read_bytes()),
                                 "vvp_sha256": digest(vvp.read_bytes()),
                                 "version": run([iverilog, "-V"], snapshot, 10)}

            def test(name):
                output = snapshot / (name+".vvp")
                argv = [iverilog, "-g2012", "-Wall", "-s", name, "-o", output,
                        snapshot / "src/midi_uart_rx.v", snapshot / "src/midi_keyboard.v",
                        snapshot / "tests/tb_midi_support.v", snapshot / f"tests/{name}.v"]
                compile_record = run(argv, snapshot, args.timeout)
                result = {"name": name, "status": "fail", "compile": compile_record}
                if compile_record.get("returncode") != 0:
                    return result
                execution = run([vvp, output], snapshot, args.timeout)
                result["run"] = execution
                stdout = execution.get("stdout") or ""
                combined = stdout + (execution.get("stderr") or "")
                marker = name.removeprefix("tb_").upper()+"_TEST_PASS"
                result["coverage"] = re.findall(r"^MIDI_CASE_PASS (.+)$", stdout, re.MULTILINE)
                if execution.get("returncode") == 0 and marker in stdout and not FAILURE.search(combined):
                    result["status"] = "pass"
                return result

            with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
                report["tests"] = list(executor.map(test, chosen))
            report["sources_unchanged"] = all(
                digest((ROOT / name).read_bytes()) == value
                for name, value in report["sources_sha256"].items())
            if all(item["status"] == "pass" for item in report["tests"]) and report["sources_unchanged"]:
                report["status"] = "pass"
                report["source_stable"] = report["full_suite"]
    except Exception as exc:
        report["error"] = repr(exc)
    report["elapsed_seconds"] = round(time.monotonic()-started, 3)
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    target = ROOT / "validation/midi_agent.json"
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    for item in report["tests"]:
        print(item["name"], item["status"])
        if item["status"] != "pass":
            for phase in ["compile", "run"]:
                if phase in item:
                    print(item[phase].get("stdout") or "", item[phase].get("stderr") or "")
    print("MIDI_REPORT", report["status"], str(target))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
