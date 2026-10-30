"""构建用户指定的独立PC工具包；从不改写固件/开发源码。"""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil

PACKAGE = Path(__file__).resolve().parent
PROJECT = PACKAGE.parents[1]
TARGET = Path(r"D:\Gowin_project\调试工具\2026-10-30_V021_电容与光束测试")
FILES = ("__init__.py", "__main__.py", "run.py", "core.py", "cli.py", "gui.py",
         "calibration.py", "simulation.py", "launch.cmd", "电容测试.cmd", "光束测试.cmd",
         "README.md", "run_validation.py")


def manifest():
    files = []
    for path in sorted(TARGET.rglob("*")):
        if path.is_file() and path.name != "文件清单.json" and "__pycache__" not in path.parts:
            files.append({"path": str(path.relative_to(TARGET)), "bytes": path.stat().st_size,
                          "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    (TARGET / "文件清单.json").write_text(json.dumps({"created": datetime.now().astimezone().isoformat(),
        "type": "PC peripheral test tools; not a firmware release", "firmware_programmed": False,
        "files": files}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return len(files)


def main():
    expected = Path(r"D:\Gowin_project\调试工具\2026-10-30_V021_电容与光束测试").resolve()
    if TARGET.resolve() != expected:
        raise RuntimeError("交付目录不在授权的精确路径")
    target_package = TARGET / "tools" / "peripheral_testbench"
    target_package.mkdir(parents=True, exist_ok=True)
    for name in FILES:
        shutil.copy2(PACKAGE / name, target_package / name)
    for name in ("vendor", "runtimepyserial"):
        shutil.copytree(PACKAGE / name, target_package / name, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    tests = TARGET / "tests"
    tests.mkdir(exist_ok=True)
    shutil.copy2(PROJECT / "tests" / "test_peripheral_testbench.py", tests / "test_peripheral_testbench.py")
    shutil.copy2(PACKAGE / "README.md", TARGET / "先读我_使用说明.md")
    for label, tool in (("电容测试", "touch"), ("光束测试", "beam")):
        (TARGET / (label + ".cmd")).write_bytes(
            ('@echo off\r\ncall "%~dp0tools\\peripheral_testbench\\launch.cmd" ' + tool + ' %*\r\n').encode("ascii"))
    validation = TARGET / "验证记录"
    validation.mkdir(exist_ok=True)
    runs = sorted((PACKAGE / "validation" / "runs").glob("*"))
    if runs:
        shutil.copytree(runs[-1], validation / "工程离线验证", dirs_exist_ok=True)
    if (PACKAGE / "validation" / "screenshots").is_dir():
        shutil.copytree(PACKAGE / "validation" / "screenshots", validation / "界面截图", dirs_exist_ok=True)
    print(str(TARGET))
    print("Manifest files:", manifest())


if __name__ == "__main__":
    main()
