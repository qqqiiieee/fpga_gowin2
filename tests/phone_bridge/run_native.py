"""Compile and run offline bridge tests with an existing C++17 compiler.

Search CXX/--compiler, then g++, clang++, cl. Windows can load vcvars64 from an
installed Visual Studio, discovered via its environment or vswhere. No tools
or SDKs are installed or downloaded.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent


def visual_studio_environment(env):
    """Read an existing VS developer environment without printing its contents."""
    candidates = []
    if env.get("VSINSTALLDIR"):
        candidates.append(Path(env["VSINSTALLDIR"]) / "VC/Auxiliary/Build/vcvars64.bat")
    if env.get("VCINSTALLDIR"):
        candidates.append(Path(env["VCINSTALLDIR"]) / "Auxiliary/Build/vcvars64.bat")
    program_roots = list(dict.fromkeys(env[k] for k in ("PROGRAMFILES(X86)", "PROGRAMFILES") if env.get(k)))
    locator = shutil.which("vswhere", path=env.get("PATH"))
    if not locator:
        locator = next((str(p) for base in program_roots
                        if (p := Path(base) / "Microsoft Visual Studio/Installer/vswhere.exe").is_file()), None)
    if locator:
        result = subprocess.run([locator, "-latest", "-products", "*", "-requires",
                                 "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                                 "-property", "installationPath"],
                                capture_output=True, text=True, errors="replace", timeout=30)
        if result.returncode == 0 and result.stdout.strip():
            candidates.append(Path(result.stdout.strip()) / "VC/Auxiliary/Build/vcvars64.bat")
    for base in program_roots:
        candidates.extend(sorted((Path(base) / "Microsoft Visual Studio").glob(
            "*/*/VC/Auxiliary/Build/vcvars64.bat"), reverse=True))
    batch = next((p for p in candidates if p.is_file()), None)
    if not batch:
        return None
    # cmd.exe does not use the C-runtime backslash quote rules applied to a
    # subprocess argv list. Supply one command line so spaces in VS paths work.
    cmd = subprocess.list2cmdline([env.get("COMSPEC", "cmd.exe")])
    command_line = cmd + f' /d /s /c "call "{batch}" >nul && set"'
    result = subprocess.run(command_line,
                            env=env, capture_output=True, text=True, errors="replace", timeout=60)
    if result.returncode:
        raise RuntimeError("Installed Visual Studio environment initialization failed: " + result.stderr.strip())
    loaded = dict(env)
    # This capture may contain credentials: parse it without logging it.
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator and key and not key.startswith("="):
            loaded[key.upper() if os.name == 'nt' else key] = value
    return loaded


def discover_compiler(explicit, env):
    requested = explicit or env.get("CXX")
    choices = [requested] if requested else ["g++", "clang++", "cl"]
    for name in choices:
        executable = shutil.which(name, path=env.get("PATH"))
        if not executable and Path(name).is_file():
            executable = str(Path(name).resolve())
        if executable:
            msvc = Path(executable).stem.lower() == "cl"
            if msvc and os.name == "nt" and not env.get("INCLUDE"):
                env = visual_studio_environment(env) or env
            return Path(executable).resolve(), msvc, env
    if os.name == "nt" and not requested:
        loaded = visual_studio_environment(env)
        if loaded and (executable := shutil.which("cl", path=loaded.get("PATH"))):
            return Path(executable).resolve(), True, loaded
    raise RuntimeError("No C++17 compiler found. Add g++, clang++ or cl to PATH, "
                       "or set CXX/--compiler to an installed compiler executable. Nothing was downloaded.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", help="Installed compiler executable (also accepts CXX)")
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    output = ROOT / "build"
    output.mkdir(exist_ok=True)
    temp = output / "temp"
    temp.mkdir(exist_ok=True)
    env = {k.upper() if os.name == 'nt' else k: v for k, v in os.environ.items()}
    env.update(TEMP=str(temp), TMP=str(temp), VSCMD_SKIP_SENDTELEMETRY="1")
    source = ROOT / "native_core.cpp"
    report = {"passed": False, "hardware_access": False, "downloaded_tools": False,
              "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "commands": []}

    def run(name, argv):
        argv = list(map(str, argv))
        print("RUN", name, subprocess.list2cmdline(argv), flush=True)
        start = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=args.timeout)
        log = result.stdout + result.stderr
        (output / (name + ".log")).write_text(log, encoding="utf-8")
        report["commands"].append({"name": name, "argv": argv, "exit_code": result.returncode,
                                   "seconds": round(time.monotonic() - start, 3)})
        print(log, end="" if log.endswith("\n") else "\n", flush=True)
        if result.returncode:
            raise RuntimeError(f"{name} failed with exit code {result.returncode}")
        return log

    try:
        compiler, msvc, env = discover_compiler(args.compiler, env)
        report["compiler"] = str(compiler)
        binary = output / ("native_core.exe" if os.name == "nt" else "native_core")
        if msvc:
            command = [compiler, "/nologo", "/std:c++17", "/EHsc", "/W4", "/utf-8",
                       "/Fe:" + str(binary), "/Fo:" + str(output / "native_core.obj"), source]
        else:
            # One original test call controls MSVC's assertion dialog. Stub only
            # that UI helper for other compilers; keep native_core.cpp/assert intact.
            compatibility = output / "native_host_compat.h"
            compatibility.write_text(
                "#include <stdlib.h>\n"
                "#if !defined(_MSC_VER)\n"
                "#define _set_abort_behavior(a,b) ((void)0)\n"
                "#ifndef _WRITE_ABORT_MSG\n#define _WRITE_ABORT_MSG 0\n#endif\n"
                "#ifndef _CALL_REPORTFAULT\n#define _CALL_REPORTFAULT 0\n#endif\n"
                "#endif\n", encoding="ascii")
            command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-O2", "-include",
                       compatibility, source, "-o", binary]
        run("native_compile", command)
        log = run("native_run", [binary])
        if "ALL NATIVE BRIDGE TESTS PASSED" not in log:
            raise RuntimeError("Native test exit code was zero but its completion marker was missing")
        report["passed"] = True
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        report["error"] = str(exc)
        print("NATIVE_BRIDGE_FAIL:", exc, file=sys.stderr)
    finally:
        destination = output / "native-test-result.json"
        destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("REPORT", destination, flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
