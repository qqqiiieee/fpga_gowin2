"""V017双音色独立回归：冻结V016、逐拍miter、全点ROM及PT8211解码。

仅写 validation/dual_timbre_agent；不调用生成器、通用runner、Gowin或发布脚本。
每次把输入复制到唯一运行目录，以免并行主agent修改源文件时混用两个版本。
默认每个编译/仿真进程timeout=900秒；运行日志、SHA256和断言覆盖统计全部保留。
默认从包内fixture逆重命名并核对冻结源哈希，不依赖旧开发目录。
--baseline可选地再检查原V016目录；只有完整六例+两个负对照才更新latest_results。
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RENAMES = {"wavetable_synth": "v016_wavetable_synth_reference",
           "instrument_audio": "v016_instrument_audio_reference",
           "voice_allocator": "v016_voice_allocator_reference"}
# 固定的是接收任务时从旧目录读取的字节哈希，不允许运行时自动刷新参考。
PINNED = {
    "wavetable_synth.v": "5a900dbc3cd6c9a80211522f43745ba18c50df3eb2243e6d05f56902416c24b7",
    "instrument_audio.v": "baef753e3895326d15142e4da61ef0879a1e905173fcc20f4b890210bb93a50b",
    "voice_allocator.v": "cb948797b44b88ebc87d2316c2d8141900f664d676b5bc104dac1ca36ac5b507",
}
HELPER_PINNED = {
    "note_table.v": "6597f860e7119b0996317ad3da524787efc4328aa4e887338c7aa2f0aaf21541",
    "oscillator_test_frequencies.v": "7b751337ab88d4b30a97db7d5e5e7b81212eb61d591ca9991e0eac30c23d56e0",
    "drum_voice.v": "f8d81a9da85d9994ecb77513031a46f91697a60e2cafe1d063a7d750a6040dc2",
    "snare_voice.v": "b4680c709dd84e32218299d1cff151507c20920379c4a37524b95405bcf81ed5",
    "audio_mix.v": "d2db0747ecf1f5488dd9f0a2b66b0bbc8e745d6fdfec4a34969210ed3192c546",
    "dc_blocker.v": "746d834986dcec68e28de5e65d29c9c11f066fd20b406998cb8bbe351534c13f",
    "audio_cleanup.v": "ed7a263a0ae96a060108a58a836c536115b2c4da2b5b9b66042ef20e9f9858b9",
    "audio_controls.v": "00b5054606645d861a07e416e9b81b3430b8f647a5cd12846335d330a7e41040",
    "pt8211_driver.v": "167e6619b3c7cbdb5fbd2b8e8e5c8f8415bac8d552d6717aedbbeb118ef19922",
}
HELPERS = list(HELPER_PINNED)
REFERENCE_ROM_PINNED = {
    "timbre_soft.hex": "9d003d4551c86f6b13fe45f2cd48d727bf716962feb6de29eed81ae39e19f253",
    "timbre_odd_half.hex": "1f117905008b0553eb82fbe8a306d94273484e2ad66ba490cd673c36d1cad1c8",
    "test_sine.hex": "99a7d0a335cd1fe5a62ade4188773927f226e86149a7cc1d923230c53ffc40a4",
}
ROM_NAMES = ["timbre_soft.hex", "timbre_odd_half.hex", "test_sine.hex", "timbre_dual.hex", "timbre_dual_half.hex"]
BENCHES = ["tb_dual_timbre_rom.v", "tb_dual_timbre_synth.v", "tb_dual_timbre_audio.v", "tb_dual_timbre_compat.v"]
CASES = {
    "rom": ("tb_dual_timbre_rom", {}),
    "synth": ("tb_dual_timbre_synth", {}),
    "compat": ("tb_dual_timbre_compat", {}),
    "audio_lowpass": ("tb_dual_timbre_audio", {"LOWPASS": 1, "REDUCED": 1}),
    "audio_bypass": ("tb_dual_timbre_audio", {"LOWPASS": 0, "REDUCED": 1}),
    "audio_compat": ("tb_dual_timbre_audio", {"LOWPASS": 1, "REDUCED": 0}),
}
FAILURE = re.compile(r"(?im)^\s*(?:FATAL:|ERROR:)|\b\w*_TEST_FAIL\b")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rename_only(data, reverse=False):
    """只替换module声明及模块实例化的类型名，保留注释、空白、换行和逻辑字节。"""
    pairs = ((target, source) for source, target in RENAMES.items()) if reverse else RENAMES.items()
    for source, target in pairs:
        data = re.sub(rb"(?m)^(\s*(?:module\s+)?)" + source.encode() + rb"(?=\s*(?:#|\())",
                      lambda match: match[1] + target.encode(), data)
    return data


def packaged_reference_hashes():
    """在内存中逆重命名，不写回fixture；恢复字节必须精确命中固定源SHA256。"""
    source_hashes, fixture_hashes, restored = {}, {}, {}
    for name, pinned in PINNED.items():
        fixture = ROOT / "tests/fixtures" / (RENAMES[Path(name).stem] + ".v")
        data = fixture.read_bytes()
        original = rename_only(data, reverse=True)
        actual = hashlib.sha256(original).hexdigest()
        if actual != pinned or rename_only(original) != data:
            raise RuntimeError("包内冻结参考逆重命名后不符合V016源哈希: " + fixture.name)
        source_hashes[name] = actual
        fixture_hashes[fixture.name] = hashlib.sha256(data).hexdigest()
        restored[name] = original
    return source_hashes, fixture_hashes, restored


def validate_references(baseline_arg, report):
    source_hashes, fixture_hashes, restored = packaged_reference_hashes()
    report["baseline_source_hashes"] = source_hashes
    report["fixture_hashes"] = fixture_hashes
    # 共用helper和基准ROM也固定包内字节，默认无需访问任何原工程路径。
    for name, pinned in {**HELPER_PINNED, **REFERENCE_ROM_PINNED}.items():
        if digest(ROOT / "src" / name) != pinned:
            raise RuntimeError("包内共用helper/基准ROM不符合V016哈希: " + name)
    report["shared_helper_hashes"] = dict(HELPER_PINNED)
    report["reference_rom_hashes"] = dict(REFERENCE_ROM_PINNED)
    if baseline_arg is None:
        report["baseline_mode"] = "packaged_fixtures_reverse_rename_sha256"
        report["baseline_directory"] = None
        report["baseline_hashes_before"] = source_hashes
        return None

    # 只有用户显式传入--baseline，才读取旧src并记录其全目录前后哈希。
    baseline = baseline_arg.resolve() / "src"
    if not baseline.is_dir():
        raise FileNotFoundError("显式--baseline目录中没有src: " + str(baseline))
    report["baseline_mode"] = "explicit_directory_and_packaged_fixtures"
    report["baseline_directory"] = str(baseline)
    report["baseline_hashes_before"] = {str(p.relative_to(baseline)): digest(p)
                                        for p in baseline.rglob("*") if p.is_file()}
    for name, original in restored.items():
        if (baseline / name).read_bytes() != original:
            raise RuntimeError("显式旧目录源文件与包内冻结参考恢复字节不同: " + name)
    for name in [*HELPERS, *REFERENCE_ROM_PINNED]:
        if (ROOT / "src" / name).read_bytes() != (baseline / name).read_bytes():
            raise RuntimeError("共用helper/基准ROM与显式旧目录不同: " + name)
    return baseline


def read_hex(path, size):
    # 这些生产hex应为每项16位，无X/Z、地址伪指令或注释；拒绝宽度和长度错误。
    tokens = path.read_text(encoding="ascii").split()
    if len(tokens) != size or any(not re.fullmatch(r"[0-9a-fA-F]{4}", token) for token in tokens):
        raise ValueError(f"ROM长度/16位字格式错误: {path}, words={len(tokens)}, expected={size}")
    return [int(token, 16) for token in tokens]


def find_tool(explicit, name):
    executable = name + (".exe" if os.name == "nt" else "")
    choices = [Path(explicit)] if explicit else [ROOT / "tools/vendor/iverilog-v12/app/bin" / executable]
    if not explicit and shutil.which(name):
        choices.append(Path(shutil.which(name)))
    for path in choices:
        path = path / executable if path.is_dir() else path
        if path.is_file():
            return path.resolve()
    raise FileNotFoundError(f"找不到{name}，请指定--{name}；脚本不会安装工具")


def command(argv, cwd, log, timeout):
    argv = list(map(str, argv))
    started = time.monotonic()
    env = os.environ.copy()
    temp = cwd / "temp"
    temp.mkdir(exist_ok=True)
    env.update(TMP=str(temp), TEMP=str(temp))
    with log.open("wb") as output:
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                stdout=output, stderr=subprocess.STDOUT)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True, timeout=15)
            else:
                proc.kill()
            proc.wait(timeout=15)
            raise TimeoutError(f"进程超过{timeout}s: {argv[0]}，日志{log}")
    text = log.read_text(encoding="utf-8", errors="replace")
    return {"argv": argv, "cwd": str(cwd), "log": str(log), "timeout_seconds": timeout,
            "returncode": code, "elapsed_seconds": round(time.monotonic() - started, 3)}, text


def source_list(work):
    return ([work / "src" / name for name in [*PINNED, *HELPERS]] +
            [work / "tests/fixtures" / (name + ".v") for name in RENAMES.values()] +
            [work / "tests" / name for name in BENCHES])


def run_case(name, top, params, work, iverilog, vvp, timeout, expect_failure=False):
    output = work / (name + ".vvp")
    argv = [iverilog, "-g2012", "-Wall", "-s", top, "-o", output]
    argv += [f"-P{top}.{key}={value}" for key, value in params.items()]
    argv += source_list(work)
    record = {"top": top, "parameters": params, "status": "RUNNING", "commands": []}
    comp, comp_text = command(argv, work, work / (name + "_compile.log"), timeout)
    record["commands"].append(comp)
    if comp["returncode"] != 0:
        raise RuntimeError(f"{name}编译失败\n{comp_text[-5000:]}")
    sim, sim_text = command([vvp, output], work, work / (name + "_simulation.log"), timeout)
    record["commands"].append(sim)
    marker = top.removeprefix("tb_").upper() + "_TEST_PASS"
    if expect_failure:
        # 编译失败、超时或找不到文件不算变异被测试检测；必须命中实际断言。
        if sim["returncode"] == 0 or "FATAL:" not in sim_text or "watchdog" in sim_text or "ERROR:" in sim_text:
            raise RuntimeError(f"{name}错误变体没有被断言拒绝\n{sim_text[-4000:]}")
        record["status"] = "EXPECTED_FAILURE"
        record["assertion"] = next(line for line in sim_text.splitlines() if "FATAL:" in line)
    else:
        if sim["returncode"] != 0 or FAILURE.search(sim_text) or marker not in sim_text:
            raise RuntimeError(f"{name}仿真失败\n{sim_text[-5000:]}")
        line = next(line for line in sim_text.splitlines() if marker in line)
        record["status"] = "PASS"
        record["coverage_line"] = line
        record["coverage"] = {key: int(value) for key, value in re.findall(r"(\w+)=([0-9]+)(?=\s|$)", line)}
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, help="可选V016工程根目录；默认仅使用包内冻结参考的逆重命名SHA256")
    parser.add_argument("--output-dir", type=Path, help="可选独立运行目录，必须位于validation/dual_timbre_agent内且尚不存在")
    parser.add_argument("--iverilog", type=Path)
    parser.add_argument("--vvp", type=Path)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--tests", choices=list(CASES), nargs="+", default=list(CASES))
    parser.add_argument("--skip-mutations", action="store_true", help="仅开发定位时跳过两个故意破坏的负对照")
    args = parser.parse_args()
    output_root = (ROOT / "validation/dual_timbre_agent").resolve()
    run = args.output_dir.resolve() if args.output_dir else output_root / ("run_" + str(time.time_ns()))
    if run == output_root or not run.is_relative_to(output_root):
        parser.error("--output-dir必须是validation/dual_timbre_agent内的新子目录")
    full_suite = set(args.tests) == set(CASES) and not args.skip_mutations
    run.mkdir(parents=True)
    report = {"status": "RUNNING", "started_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "Icarus RTL only; no synthesis/PnR/programming/physical audio claim",
              "run": str(run), "timeout_seconds": args.timeout, "full_suite": full_suite,
              "jobs": args.jobs, "tests": {}, "mutations": {}}
    started = time.monotonic()

    def save():
        (run / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("DUAL_TIMBRE_RUN " + str(run), flush=True)
    try:
        iverilog = find_tool(args.iverilog, "iverilog")
        vvp = find_tool(args.vvp or iverilog.with_name("vvp.exe" if os.name == "nt" else "vvp"), "vvp")
        report["tools"] = {"iverilog": str(iverilog), "vvp": str(vvp)}
        baseline = validate_references(args.baseline, report)

        tracked = [ROOT / "src" / name for name in [*PINNED, *HELPERS, *ROM_NAMES]]
        tracked += [ROOT / "tests/fixtures" / (name + ".v") for name in RENAMES.values()]
        tracked += [ROOT / "tests" / name for name in BENCHES]
        tracked += [ROOT / "src/instrument_audio_top.v"]
        report["source_hashes"] = {}
        for path in tracked:
            relative = path.relative_to(ROOT)
            dest = run / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, dest)
            report["source_hashes"][relative.as_posix()] = digest(dest)
        top_text = (run / "src/instrument_audio_top.v").read_text(encoding="utf-8-sig")
        if not re.search(r"instrument_audio\s*#\s*\([^;]*\.REDUCED_TIMBRES\s*\(\s*1\s*\)", top_text):
            raise RuntimeError("生产audio top没有显式启用REDUCED_TIMBRES(1)")
        report["production_top_reduced"] = True
        old16 = read_hex(run / "src/timbre_soft.hex", 16384)
        full = read_hex(run / "src/timbre_dual.hex", 2048)
        half = read_hex(run / "src/timbre_dual_half.hex", 1024)
        read_hex(run / "src/test_sine.hex", 1024)
        for bank, source_bank in enumerate((1, 7)):
            for index in range(1024):
                expected = old16[source_bank * 1024 + index]
                stored = half[bank * 512 + (index if index < 512 else (-index) & 511)]
                rebuilt = stored if index < 512 else (-stored) & 65535
                if full[bank * 1024 + index] != expected or rebuilt != expected:
                    raise RuntimeError(f"ROM原样重建不等 bank={bank} old={source_bank} index={index}")
            if full[bank * 1024] != 0 or full[bank * 1024 + 512] != 0:
                raise RuntimeError("奇对称端点必须为0")
        report["rom"] = {"status": "PASS", "mapping": {"0": 1, "1": 7}, "points_compared": 2048,
                         "full_words": 2048, "packed_words": 1024, "test_sine_unchanged": True}
        save()
        print("ROM_PREFLIGHT_PASS points=2048 frozen_modules=3 helpers=9", flush=True)
        # 独立测试可以并行；每个案例有不同的输出和日志文件。
        errors = []
        with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as executor:
            pending = {executor.submit(run_case, name, *CASES[name], run, iverilog, vvp, args.timeout): name
                       for name in args.tests}
            for future in as_completed(pending):
                name = pending[future]
                try:
                    record = future.result()
                    report["tests"][name] = record
                    print(record["coverage_line"], flush=True)
                except Exception as exc:
                    errors.append(name)
                    report["tests"][name] = {"status": "FAIL", "error": str(exc)}
                    print("DUAL_TIMBRE_CASE_FAIL " + name + " " + str(exc), flush=True)
                save()
        if errors:
            raise RuntimeError("未通过: " + ", ".join(errors))
        if not args.skip_mutations:
            # 负对照证明断言会拒绝真正的起音和波表错误，不能把“无声相等”算成功。
            for name in ("wrong_attack", "swapped_packed_banks"):
                mutant = run / "mutations" / name
                for folder in ("src", "tests"):
                    shutil.copytree(run / folder, mutant / folder)
                if name == "wrong_attack":
                    source = mutant / "src/wavetable_synth.v"
                    data = source.read_bytes()
                    replacement, count = re.subn(rb"DUAL_PROFILE\s*\?\s*\(timbre==0\s*\?\s*8'd1\s*:\s*8'd8\)",
                                                 b"DUAL_PROFILE ? (timbre==0 ? 8'd1 : 8'd1)", data)
                    if count != 1:
                        raise RuntimeError("无法定位DUAL_PROFILE起音表达式，未执行负对照")
                    source.write_bytes(replacement)
                    top = "tb_dual_timbre_synth"
                else:
                    source = mutant / "src/timbre_dual_half.hex"
                    words = source.read_text(encoding="ascii").split()
                    source.write_text("\n".join(words[512:] + words[:512]) + "\n", encoding="ascii")
                    top = "tb_dual_timbre_rom"
                record = run_case(name, top, {}, mutant, iverilog, vvp, args.timeout, expect_failure=True)
                report["mutations"][name] = record
                print("DUAL_TIMBRE_MUTATION_REJECTED " + name + " " + record["assertion"], flush=True)
                save()
        report["source_hashes_after"] = {str(path.relative_to(ROOT)).replace("\\", "/"): digest(path) for path in tracked}
        if baseline is None:
            report["baseline_hashes_after"] = packaged_reference_hashes()[0]
        else:
            report["baseline_hashes_after"] = {str(p.relative_to(baseline)): digest(p)
                                              for p in baseline.rglob("*") if p.is_file()}
        report["baseline_unchanged"] = report["baseline_hashes_after"] == report["baseline_hashes_before"]
        report["live_inputs_unchanged"] = report["source_hashes_after"] == report["source_hashes"]
        if not report["baseline_unchanged"] or not report["live_inputs_unchanged"]:
            raise RuntimeError("测试期间输入或冻结来源发生变化，请对新快照重跑")
        report["status"] = "PASS"
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        save()
        # 单项smoke或显式输出目录不能覆盖已完成的完整回归证据。
        if full_suite and args.output_dir is None:
            (output_root / "latest_results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(("DUAL_TIMBRE_ALL_PASS " if full_suite else "DUAL_TIMBRE_SELECTED_PASS ") + str(run), flush=True)
        return 0
    except Exception as exc:
        report["status"] = "FAIL";report["error"] = str(exc)
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        save()
        print("DUAL_TIMBRE_VALIDATION_FAIL " + str(exc), file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
