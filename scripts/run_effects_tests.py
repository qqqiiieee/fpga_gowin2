"""共享数字效果器独立回归：使用本工程离线Icarus，不安装工具、不综合。

普通运行：python scripts/run_effects_tests.py --cases 6 --workers 2
已有长跑：python scripts/run_effects_tests.py --monitor-run <旧证据目录> --workers 3

全部中间产物放系统临时目录；只读取三个自有工程文件。生产参数不缩短：
持续27MHz时钟、288clk/sample、750000采样尾音上限；八个case总采样数固定。
新bench每2048采样刷新JSONL，partial_report.json明确区分running/pass/fail。
监视旧进程不重启、不丢已有结果：输出progress_report.json，明确区分旧bench
的吞吐估计与新bench的实际采样计数。最终consolidated_report.json保留原报告，
只有RTL规范化文本一致、八个数值case/边界任务及setup/check/sat逐字一致、
每例都实际通过时才可汇总通过。测试端优化不使旧快照结果失效；真实失败不覆盖。
原始字节SHA与规范化文本SHA分别记录，避免BOM/换行改写冒充RTL逻辑改动。
DSP/BSRAM仅为结构估计，CLS/Fmax/物理音频仍需主流程验证。
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
OWNED = ("src/audio_effects.v", "tests/tb_audio_effects.v", "scripts/run_effects_tests.py")
CASES = {0: "bit_exact_bypass", 1: "delay_impulse_decay_signed",
         2: "chorus_lfo_interpolation_reference", 3: "reverb_schroeder_reference",
         4: "boundaries_saturation", 5: "clear_reset_switch_no_x",
         6: "smoothing_latching", 7: "natural_and_full_8s_tail"}
TOTALS = {0: 67348, 1: 60442, 2: 62260, 3: 32520,
          4: 240490, 5: 109599, 6: 3260, 7: 793541}
TASKS = ("bypass_tests", "delay_tests", "chorus_tests", "reverb_tests",
         "boundary_tests", "clear_switch_tests", "smoothing_tests", "tail_tests", "setup", "check")


def utc():
    return datetime.now(timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalized(path):
    return path.read_text(encoding="utf-8-sig")


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None


def atomic_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    # Windows readers may momentarily hold a file without FILE_SHARE_DELETE.
    for attempt in range(10):
        try:
            temporary.replace(path)
            return
        except PermissionError:
            if attempt==9:
                raise
            time.sleep(0.05)


def coverage_fingerprint(path):
    text = normalized(path)
    def digest_block(pattern):
        block = re.search(pattern, text)
        if not block:
            raise ValueError("Missing coverage task/function: " + pattern)
        code = re.sub(r"/\*.*?\*/|//[^\n]*", "", block[0], flags=re.S)
        return hashlib.sha256(re.sub(r"\s+", "", code).encode()).hexdigest()
    result = {name: digest_block(r"(?ms)^\s*task\s+"+name+r"\s*;.*?^\s*endtask\b") for name in TASKS}
    result["sat"] = digest_block(r"(?ms)^\s*function\s+integer\s+sat\s*;.*?^\s*endfunction\b")
    return result


def command(argv, directory, timeout):
    start = time.monotonic()
    record = {"argv": [str(a) for a in argv], "timeout_seconds": timeout}
    try:
        result = subprocess.run(record["argv"], cwd=directory, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=timeout)
        record.update(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
    except subprocess.TimeoutExpired as exc:
        def decode(value):
            return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")
        record.update(returncode=None, timed_out=True,
                      stdout=decode(exc.stdout), stderr=decode(exc.stderr))
    record["elapsed_seconds"] = round(time.monotonic()-start, 3)
    return record


def windows_cpu_seconds(proc):
    if os.name != "nt":
        return None
    try:
        import ctypes
        from ctypes import wintypes
        times = [wintypes.FILETIME() for _ in range(4)]
        ok = ctypes.windll.kernel32.GetProcessTimes(
            wintypes.HANDLE(int(proc._handle)), *(ctypes.byref(t) for t in times))
        if ok:
            def seconds(t):
                return ((t.dwHighDateTime << 32) | t.dwLowDateTime)/10000000
            return round(seconds(times[2])+seconds(times[3]), 3)
    except (AttributeError, OSError, ValueError):
        pass
    return None


def process_alive(pid):
    if not pid or os.name!="nt":
        return None
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.windll.kernel32
    kernel.OpenProcess.restype = wintypes.HANDLE
    handle = kernel.OpenProcess(0x1000, False, int(pid))
    if not handle:
        return False
    try:
        code = wintypes.DWORD()
        return bool(kernel.GetExitCodeProcess(wintypes.HANDLE(handle), ctypes.byref(code)) and code.value==259)
    finally:
        kernel.CloseHandle(wintypes.HANDLE(handle))


def marker_result(case, result):
    stdout = result.get("stdout", "")
    marker = re.search(r"EFFECTS_TEST_PASS case=(\d+) samples=(\d+) checks=(\d+) "
                       r"worker_max_clocks=(\d+) latency_clocks=(\d+)", stdout)
    passed = (result.get("returncode")==0 and marker is not None
              and int(marker[1])==case and int(marker[2])==TOTALS[case]
              and int(marker[4])<63 and int(marker[5])==63
              and not re.search(r"(?im)^\s*(FAIL|ERROR:|FATAL:)", stdout))
    record = {"case": case, "name": CASES[case], "status": "pass" if passed else "fail", "simulation": result}
    if marker:
        record.update(samples=int(marker[2]), checks=int(marker[3]),
                      worker_max_clocks=int(marker[4]), fixed_latency_clocks=int(marker[5]))
    return record


def last_progress(path):
    try:
        with path.open("rb") as stream:
            stream.seek(0, 2)
            stream.seek(max(0, stream.tell()-4096))
            lines = stream.read().decode("utf-8").splitlines()
        for line in reversed(lines):
            try:
                return json.loads(line)
            except ValueError:
                continue
    except OSError:
        pass
    return None


def summarize(report):
    report["completed_cases"] = sorted(c for c,r in report["cases"].items() if r["status"] in ("pass", "fail"))
    report["running_cases"] = sorted(c for c,r in report["cases"].items() if r["status"]=="running")
    report["queued_cases"] = sorted(c for c,r in report["cases"].items() if r["status"]=="queued")
    report["updated_utc"] = utc()
    if any(r["status"]=="fail" for r in report["cases"].values()) or report.get("error"):
        report["status"] = "fail"
    elif report["run_active"]:
        report["status"] = "running"
    else:
        report["status"] = "pass"


def normal_run(args):
    folder = Path(tempfile.mkdtemp(prefix="audio_effects_"))
    print(f"Effects evidence directory: {folder}", flush=True)
    suffix = ".exe" if os.name=="nt" else ""
    runtime = ROOT / "tools/vendor/iverilog-v12/app/bin"
    iv, vvp = runtime/("iverilog"+suffix), runtime/("vvp"+suffix)
    start = time.monotonic()
    lock = threading.RLock()
    last_write = [0.0]
    cases = sorted(set(args.cases), reverse=True)
    report = {"status": "running", "run_active": True, "started_utc": utc(),
              "project": str(ROOT), "evidence_directory": str(folder), "sources_sha256": {},
              "tests": [], "cases": {c: {"name": CASES[c], "status": "queued", "samples_total": TOTALS[c]} for c in cases},
              "full_suite": set(cases)==set(CASES), "synthesis_run": False, "hardware_tested": False,
              "contract": {"clock_hz": 27000000, "tick_hz": 93750, "sample_period_clocks": 288,
                           "fixed_latency_clocks": 63, "fixed_latency_us": 63/27,
                           "ram_arrays": 1, "ram_words": 16384, "ram_word_bits": 16,
                           "ram_bits": 262144, "estimated_18kb_bsram": 16, "bsram_budget": 24,
                           "estimated_dsp": 0, "mapping_verified_by_synthesis": False,
                           "tail_hard_limit_samples": 750000,
                           "assertions": "event monitors over entire stable window; per-sample deadline and numerical oracle",
                           "dry": "signed PCM, bit-exact mode=0 or amount=0 at tick+63"}}
    def publish(force=False):
        with lock:
            now = time.monotonic()
            if not force and now-last_write[0]<2:
                return
            summarize(report)
            report["elapsed_seconds"] = round(now-start, 3)
            atomic_json(folder/"partial_report.json", report)
            last_write[0] = now
    try:
        if not iv.is_file() or not vvp.is_file():
            raise FileNotFoundError("Bundled project Icarus runtime missing; no tools installed")
        for relative in OWNED:
            data = (ROOT/relative).read_bytes()
            report["sources_sha256"][relative] = hashlib.sha256(data).hexdigest()
            target = folder/relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        report["coverage_fingerprint"] = coverage_fingerprint(folder/OWNED[1])
        report["tools"] = {"iverilog": str(iv), "vvp": str(vvp), "iverilog_sha256": sha(iv), "vvp_sha256": sha(vvp)}
        report["verilog2005_check"] = command([iv, "-g2005", "-Wall", "-s", "audio_effects", "-t", "null", folder/OWNED[0]], folder, 30)
        image = folder/"effects.vvp"
        report["compile"] = command([iv, "-g2012", "-Wall", "-s", "tb_audio_effects", "-o", image, folder/OWNED[0], folder/OWNED[1]], folder, 30)
        if report["compile"]["returncode"]!=0 or report["verilog2005_check"]["returncode"]!=0:
            raise RuntimeError("Icarus compile failed: "+report["compile"].get("stderr", "")+report["verilog2005_check"].get("stderr", ""))
        publish(True)
        def run_case(case):
            began = time.monotonic()
            progress = folder/f"case_{case}.progress.jsonl"
            log = folder/f"case_{case}.log"
            argv = [str(vvp), "-n", str(image), f"+CASE={case}", f"+PROGRESS={progress}"]
            timed_out = False
            with log.open("w", encoding="utf-8") as output:
                proc = subprocess.Popen(argv, cwd=folder, stdout=output, stderr=subprocess.STDOUT)
                with lock:
                    entry = report["cases"][case]
                    entry.update(status="running", pid=proc.pid, started_utc=utc(), samples_completed=0,
                                 progress_kind="exact bench sample counter", log=str(log), progress_file=str(progress))
                publish(True)
                next_print = began+30
                while proc.poll() is None:
                    elapsed = time.monotonic()-began
                    data = last_progress(progress)
                    with lock:
                        entry["elapsed_seconds"] = round(elapsed, 3)
                        if data:
                            count = data["samples"]
                            entry.update(last_bench_progress=data, samples_completed=count,
                                         percent_complete=round(100*count/TOTALS[case], 3))
                            if count and elapsed:
                                rate = count/elapsed
                                entry.update(samples_per_second=round(rate, 2), eta_seconds=round((TOTALS[case]-count)/rate, 1))
                    if time.monotonic()>=next_print:
                        print(f"CASE{case}: {entry['samples_completed']}/{TOTALS[case]} samples; ETA {entry.get('eta_seconds','?')}s", flush=True)
                        next_print = time.monotonic()+30
                    publish()
                    if elapsed>=args.timeout:
                        timed_out = True
                        proc.kill()
                        break
                    time.sleep(1)
                proc.wait()
                cpu = windows_cpu_seconds(proc)
            result = {"argv": argv, "timeout_seconds": args.timeout, "returncode": proc.returncode,
                      "elapsed_seconds": round(time.monotonic()-began, 3), "process_cpu_seconds": cpu,
                      "stdout": log.read_text(encoding="utf-8", errors="replace"), "stderr": ""}
            if timed_out:
                result["timed_out"] = True
            record = marker_result(case, result)
            with lock:
                entry.update(status=record["status"], elapsed_seconds=result["elapsed_seconds"],
                             finished_utc=utc(), eta_seconds=0 if record["status"]=="pass" else None)
                if "samples" in record:
                    entry.update(samples_completed=record["samples"], percent_complete=100 if record["status"]=="pass" else entry.get("percent_complete"))
                report["tests"].append(record)
            publish(True)
            print(f"{case} {CASES[case]}: {record['status']} ({result['elapsed_seconds']}s, CPU {cpu}s)", flush=True)
            if record["status"]!="pass":
                print(result["stdout"][-4000:], flush=True)
            return record
        with ThreadPoolExecutor(max_workers=max(1,args.workers)) as pool:
            pending = [pool.submit(run_case, case) for case in cases]
            for future in as_completed(pending):
                future.result()
        report["tests"].sort(key=lambda r:r["case"])
        report["changed_owned_sources"] = [p for p,h in report["sources_sha256"].items() if sha(ROOT/p)!=h]
        if report["changed_owned_sources"]:
            report["error"] = "Owned sources changed during run: "+str(report["changed_owned_sources"])
        report["observed_worker_max_clocks"] = max(t.get("worker_max_clocks",0) for t in report["tests"])
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
        print(report["error"], flush=True)
    report["run_active"] = False
    report["finished_utc"] = utc()
    publish(True)
    atomic_json(folder/"report.json", report)
    print(json.dumps({"status": report["status"], "report": str(folder/"report.json"), "elapsed_seconds": report["elapsed_seconds"]}), flush=True)
    return 0 if report["status"]=="pass" else 1


def monitor_run(args):
    folder = args.monitor_run.resolve()
    print(f"Monitoring existing immutable run (no restart): {folder}", flush=True)
    old_rtl, current_rtl = folder/OWNED[0], ROOT/OWNED[0]
    old_fp, current_fp = coverage_fingerprint(folder/OWNED[1]), coverage_fingerprint(ROOT/OWNED[1])
    if old_fp!=current_fp or normalized(old_rtl)!=normalized(current_rtl):
        raise RuntimeError("Cannot reuse snapshot: RTL text or numerical/boundary coverage differs")
    inventory = read_json(folder/"process_inventory.json") or []
    if isinstance(inventory,dict):
        inventory = [inventory]
    known = {int(x["case"]): x for x in inventory}
    parent_pid = next((x.get("parent_pid") for x in inventory),None)
    last_print = 0.0
    while True:
        original_final = read_json(folder/"report.json")
        original = original_final or read_json(folder/"partial_report.json")
        if not original:
            raise RuntimeError("No original report")
        ordered = list(sorted(CASES, reverse=True))
        base = datetime.fromisoformat(known[7]["started_utc"]) if 7 in known else datetime.fromisoformat(original["started_utc"])
        waiting = ordered[max(1,args.workers):]
        active = set(ordered[:max(1,args.workers)])
        starts = {c: base for c in active}
        completed = {}
        rates = []
        for item in original.get("tests",[]):
            case = item["case"]
            record = marker_result(case,item["simulation"])
            completed[case] = record
            if case in known:
                starts[case] = datetime.fromisoformat(known[case]["started_utc"])
            finished = starts.get(case,base)+timedelta(seconds=item["simulation"]["elapsed_seconds"])
            active.discard(case)
            if waiting:
                following = waiting.pop(0)
                starts[following] = finished
                active.add(following)
            if record["status"]=="pass" and record["samples"]>=10000:
                rates.append(record["samples"]/record["simulation"]["elapsed_seconds"])
        rate = statistics.median(rates) if rates else None
        now = datetime.now(timezone.utc)
        entries = {}
        for case in CASES:
            entry = {"name":CASES[case],"samples_total":TOTALS[case]}
            if case in completed:
                item = completed[case]
                entry.update(status=item["status"],samples_completed=item.get("samples"),progress_kind="confirmed pass/fail marker",
                             elapsed_seconds=item["simulation"]["elapsed_seconds"])
            elif case in active:
                began = datetime.fromisoformat(known[case]["started_utc"]) if case in known else starts[case]
                elapsed = max(0,(now-began).total_seconds())
                entry.update(status="running",started_utc=began.isoformat(),elapsed_seconds=round(elapsed,1),
                             samples_completed=None,progress_kind="estimated from completed original cases; NOT measured sample counter")
                if rate:
                    low,high = rate*0.75,rate*1.25
                    entry.update(estimated_throughput_samples_s=round(rate,2),
                                 eta_range_seconds=[round(max(0,TOTALS[case]/high-elapsed)),round(max(0,TOTALS[case]/low-elapsed))])
                    if elapsed*rate<TOTALS[case]:
                        entry.update(samples_estimated=int(elapsed*rate),percent_estimated=round(100*elapsed*rate/TOTALS[case],1))
                    else:
                        entry["estimate_note"]="Previous throughput estimate exceeded; exact sample counter unavailable in this old snapshot"
            else:
                entry.update(status="queued",samples_completed=0)
            entries[case]=entry
        text_same = normalized(old_rtl)==normalized(current_rtl)
        fp_same = old_fp==coverage_fingerprint(ROOT/OWNED[1])
        alive = process_alive(parent_pid)
        all_done = len(completed)==len(CASES)
        error = original.get("error")
        if not text_same or not fp_same:
            error="Frozen RTL text or numerical/boundary test coverage changed"
        if alive is False and not original_final:
            error="Original runner exited without final report"
        report={"status":"running","run_active":not bool(original_final),"started_utc":original["started_utc"],
                "updated_utc":utc(),"cases":entries,"tests":list(completed.values()),
                "evidence_directory":str(folder),"original_summary_status":original.get("status"),
                "original_report":str(folder/("report.json" if original_final else "partial_report.json")),
                "original_runner_pid":parent_pid,"original_runner_alive":alive,
                "rtl_normalized_text_unchanged":text_same,"numerical_and_boundary_coverage_unchanged":fp_same,
                "coverage_fingerprint":old_fp,"rtl_snapshot_sha256":sha(old_rtl),"rtl_workspace_sha256":sha(current_rtl),
                "raw_rtl_bytes_match":sha(old_rtl)==sha(current_rtl),
                "snapshot_results_policy":"Original processes use immutable original RTL+bench; test-driver/report optimizations do not restart or invalidate numerical coverage. BOM/newline differences are recorded separately.",
                "changed_owned_sources_since_original_snapshot":[p for p,h in original["sources_sha256"].items() if sha(ROOT/p)!=h],
                "synthesis_run":False,"hardware_tested":False,"full_suite":all_done}
        if error:
            report["error"]=error
        summarize(report)
        if original_final and not all_done:
            report["error"]="Original run ended with missing cases"
            report["status"]="fail"
        atomic_json(folder/"progress_report.json",report)
        if time.monotonic()-last_print>=30 or original_final:
            brief={c:{k:v for k,v in e.items() if k in ("status","samples_completed","percent_estimated","eta_range_seconds")} for c,e in entries.items()}
            print(json.dumps({"updated_utc":report["updated_utc"],"status":report["status"],"cases":brief}),flush=True)
            last_print=time.monotonic()
        if original_final or error:
            report["run_active"]=False
            report["finished_utc"]=utc()
            atomic_json(folder/"consolidated_report.json",report)
            return 0 if report["status"]=="pass" and all_done else 1
        time.sleep(5)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases",nargs="+",type=int,choices=sorted(CASES),default=sorted(CASES))
    parser.add_argument("--workers",type=int,default=2)
    parser.add_argument("--timeout",type=int,default=7200,help="host timeout only; production sample counts never shortened")
    parser.add_argument("--monitor-run",type=Path,help="attach progress reporting to an existing snapshot without restarting any case")
    args=parser.parse_args()
    return monitor_run(args) if args.monitor_run else normal_run(args)


if __name__=="__main__":
    raise SystemExit(main())
