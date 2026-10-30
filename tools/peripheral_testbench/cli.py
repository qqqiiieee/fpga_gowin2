from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

from .core import (BEAM_WIRING, MENU_NOTICE, RAW_NOTICE, TOUCH_WIRING,
                   Evidence, ReadOnlyLink, StageTest, protocol, unique_folder)
from .simulation import SimulatedSerial

PACKAGE = Path(__file__).resolve().parent


def parser():
    result = argparse.ArgumentParser(description="电容/光束测试台：默认GUI，只读09 flag80，不烧录")
    result.add_argument("--tool", choices=("touch", "beam"), default="touch", help="touch电容 / beam光束")
    result.add_argument("--cli", action="store_true", help="终端分阶段测试；实机每阶段需按Enter")
    result.add_argument("--simulate", action="store_true", help="明显标记的纯模拟；不打开串口")
    result.add_argument("--self-test", action="store_true", help="运行两个工具的离线正/反向模拟自测")
    result.add_argument("--list-ports", action="store_true", help="仅枚举端口，不连接")
    result.add_argument("--port", help="用户明确选择的串口；无默认COM号")
    result.add_argument("--output", type=Path, default=PACKAGE / "reports", help="报告父目录，每次新建时间戳子目录")
    result.add_argument("--samples", type=int, default=8, help="每阶段3..500个新回复，默认8")
    result.add_argument("--interval", type=float, default=0.12, help="采样间隔0.02..5秒")
    result.add_argument("--timeout", type=float, default=0.8, help="查询超时0.05..5秒")
    result.add_argument("--raw-capability", action="store_true", help="模拟新版bit11 raw_available")
    result.add_argument("--smoke-gui", action="store_true", help=argparse.SUPPRESS)
    result.add_argument("--fault", choices=("none", "timeout", "disconnect", "stuck", "swapped", "not-ready",
                        "noise", "touch-fault", "frozen-seq", "bad-xor", "wrong-seq"), default="none",
                        help="模拟故障注入")
    return result


def validate(args):
    StageTest(args.tool, samples=args.samples)
    if not 0.02 <= args.interval <= 5 or not 0.05 <= args.timeout <= 5:
        raise ValueError("interval需0.02..5秒，timeout需0.05..5秒")
    if (args.fault != "none" or args.raw_capability) and not (args.simulate or args.self_test):
        raise ValueError("--fault / --raw-capability 只能用于 --simulate")


def run_stages(args, *, emit=print, prompt=input, factory=None, clock=time.monotonic, sleep=time.sleep):
    test = StageTest(args.tool, samples=args.samples)
    evidence = Evidence(args.tool, args.simulate, "SIMULATED" if args.simulate else (args.port or ""))
    peer = None
    if args.simulate:
        peer = SimulatedSerial(fault=args.fault, raw_capability=args.raw_capability, sleep=sleep)
        factory = lambda p, t: peer
    if not args.simulate and not args.port:
        raise ValueError("实机CLI需明确 --port；不会自动打开枚举端口")
    link = ReadOnlyLink(factory or protocol.open_serial, timeout=args.timeout,
                        simulated=args.simulate, clock=clock, sleep=sleep)
    code = 0
    emit("【模拟模式：无硬件，不计硬件通过】" if args.simulate else "实机只读检测；不写校准、不烧录")
    emit(MENU_NOTICE)
    emit(TOUCH_WIRING if args.tool == "touch" else BEAM_WIRING + "\n" + RAW_NOTICE)
    try:
        first = link.connect(evidence.port)
        evidence.samples.append(first)
        evidence.event("connected", "收到匹配seq的09诊断")
        while not test.complete:
            name, label = test.stages[test.index]
            emit(f"阶段 {test.index+1}/{len(test.stages)}：{label}")
            if peer:
                peer.set_stage(name)
            else:
                prompt("完成动作并保持稳定，按Enter采集：")
            test.begin()
            while test.active:
                sample = link.poll()
                evidence.samples.append(sample)
                result = test.accept(sample)
                emit(f"raw={sample.raw} mask=0x{sample.key_mask:04X} fault={int(sample.fault)} "
                     f"seq={sample.seq} sample_seq={sample.sample_seq} "
                     f"blocked A/B={int(sample.blocked_a)}/{int(sample.blocked_b)} ready={int(sample.ready)} "
                     f"rawA/B={sample.raw_a}/{sample.raw_b}")
                if result:
                    emit("本阶段判据通过" if result["passed"] else "本阶段未通过：" + "；".join(result["reasons"]))
                if test.active and not args.simulate:
                    sleep(args.interval)
    except (Exception, KeyboardInterrupt) as exc:
        test.cancel(str(exc) or "用户中断")
        evidence.event("error", str(exc) or "用户中断")
        code = 2
    finally:
        link.disconnect()
        evidence.event("disconnected", "停止轮询；等待1秒、释放后再按4/5")
    path = evidence.save(args.output, test)
    conclusion = test.conclusion(simulated=args.simulate)
    emit(conclusion["summary_zh"])
    emit("报告：" + str(path.resolve()))
    return code or (0 if conclusion["criteria_passed"] else 1), path, conclusion


def self_test(args, emit=print):
    base = unique_folder(args.output, "离线运行报告")
    cases = [("touch", "none", True, False), ("beam", "none", True, False),
             ("beam", "none", True, True), ("touch", "stuck", False, False),
             ("touch", "noise", False, False), ("touch", "frozen-seq", False, False),
             ("touch", "touch-fault", False, False), ("beam", "swapped", False, False),
             ("beam", "not-ready", False, False), ("beam", "stuck", False, False),
             ("touch", "timeout", False, False), ("beam", "disconnect", False, False),
             ("touch", "bad-xor", False, False), ("beam", "wrong-seq", False, False)]
    results = []
    for tool, fault, expected, raw_capability in cases:
        options = argparse.Namespace(**vars(args))
        options.tool, options.fault, options.simulate = tool, fault, True
        options.timeout, options.samples = 0.05, 4
        options.output, options.raw_capability = base, raw_capability
        code, path, conclusion = run_stages(options, emit=lambda _: None)
        ok = conclusion["criteria_passed"] == expected and not conclusion["hardware_passed"]
        ok = ok and ((code == 0) == expected)
        results.append({"tool": tool, "fault": fault, "raw_capability": raw_capability,
                        "expected_criteria_passed": expected, "verified": ok,
                        "exit_code": code, "report": str(path.relative_to(base))})
        emit(f"{'PASS' if ok else 'FAIL'} {tool} / {fault} / raw_available={raw_capability}")
    passed = all(row["verified"] for row in results)
    (base / "模拟自测总报告.json").write_text(json.dumps({"simulated": True,
        "hardware_tested": False, "all_verified": passed, "cases": results}, ensure_ascii=False, indent=2)
        + "\n", encoding="utf-8")
    emit(f"模拟自测 {sum(r['verified'] for r in results)}/{len(results)}；未测试硬件。报告：{base}")
    return 0 if passed else 1


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        validate(args)
        if args.list_ports:
            print(json.dumps(protocol.list_ports(), ensure_ascii=False, indent=2))
            return 0
        if args.self_test:
            return self_test(args)
        if args.cli:
            return run_stages(args)[0]
        from .gui import run_gui
        return run_gui(args)
    except (OSError, ValueError, RuntimeError, ImportError) as exc:
        print("失败：" + str(exc))
        return 2
