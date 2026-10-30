"""离线验证入口，所有输出位于本工具目录或显式--output之内。"""
import argparse
from datetime import datetime
import io
import json
import os
from pathlib import Path
import platform
import sys
import unittest

sys.dont_write_bytecode = True
PACKAGE = Path(__file__).resolve().parent
PROJECT = PACKAGE.parents[1]
sys.path.insert(0, str(PACKAGE.parent))
sys.path.insert(0, str(PROJECT / "tests"))
from peripheral_testbench import cli
from peripheral_testbench.core import unique_folder


def main():
    parser = argparse.ArgumentParser(description="纯离线单元/GUI/阶段模拟验证，不连接设备")
    parser.add_argument("--output", type=Path, default=PACKAGE / "validation" / "runs")
    parser.add_argument("--repeat-gui", type=int, default=0)
    args = parser.parse_args()
    if not 0 <= args.repeat_gui <= 30:
        parser.error("repeat-gui需在0..30")
    output = unique_folder(args.output, "offline_validation")
    import test_peripheral_testbench as tests
    suite = unittest.defaultTestLoader.loadTestsFromModule(tests)
    unique_count = suite.countTestCases()
    for _ in range(args.repeat_gui):
        suite.addTest(tests.GuiTests("test_gui_simulation_stages_stop_and_no_hardware"))
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    (output / "unittest.log").write_text(stream.getvalue(), encoding="utf-8")
    options = cli.parser().parse_args(["--self-test", "--output", str(output / "模拟证据")])
    sim_lines = []
    sim_code = cli.self_test(options, emit=sim_lines.append)
    (output / "simulation.log").write_text("\n".join(sim_lines) + "\n", encoding="utf-8")
    data = {"created": datetime.now().astimezone().isoformat(), "python": sys.version,
            "platform": platform.platform(), "serial_opened": False, "firmware_programmed": False,
            "test_mode": "offline mocks only", "unique_tests": unique_count,
            "gui_repeats": args.repeat_gui, "tests_run": result.testsRun,
            "failures": len(result.failures), "errors": len(result.errors),
            "unit_passed": result.wasSuccessful(), "simulation_cases": 14,
            "simulation_exit_code": sim_code,
            "all_passed": result.wasSuccessful() and sim_code == 0}
    (output / "验证结果.json").write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(data, ensure_ascii=False, indent=2))
    print("证据目录：" + str(output))
    return 0 if data["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
