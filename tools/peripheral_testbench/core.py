"""与 GUI 无关的诊断、阶段判据和证据导出。所有默认请求均为 flag=80。"""
from __future__ import annotations

import csv
from dataclasses import asdict, dataclass
from datetime import datetime
import json
from pathlib import Path
import statistics
import time
import uuid

from .vendor import touch_calibrate as protocol

MENU_NOTICE = ("V021：每次09诊断轮询都会暂停菜单约0.5秒。恢复菜单前点击“停止轮询（保留连接）”或“停止检测 / 断开”，"
               "等待至少1秒，松开全部触摸键，再按4/5并抬手切页。")
TOUCH_WIRING = ("G/V/S 键盘：S 经10k/10k分压接 MCP3208 CH0，共地，ADC参考2.5V。"
                "固件中心为估算值，未经实物标定；raw折算电压也只是估算。")
BEAM_WIRING = ("SEN0503 两对：TX各2线、RX各3线，四端都供3.3V并共地；"
               "RX OUT A=P8、B=P9，各自10k上拉3.3V。开机两束通光至少200ms学习基线；"
               "若后来才补接TX电源，须整板重启并保持两束通光。")
RAW_NOTICE = ("diag2 bit4/5 是相对开机学习基线的 blocked，并非真实电平。"
              "仅 bit11=1 才显示 bit9 rawA / bit10 rawB；V021通常不提供真实电平。")


def now_iso():
    return datetime.now().astimezone().isoformat(timespec="milliseconds")


def unique_folder(base, prefix):
    path = Path(base) / (datetime.now().strftime("%Y-%m-%d_%H%M%S_%f")
                         + "_" + prefix + "_" + uuid.uuid4().hex[:6])
    path.mkdir(parents=True, exist_ok=False)
    return path


@dataclass(frozen=True)
class Sample:
    timestamp: str
    elapsed: float
    seq: int
    sample_seq: int
    raw: int
    key_mask: int
    keys: int
    fault: bool
    touch_valid_pulse: bool
    blocked_a: bool
    blocked_b: bool
    ready: bool
    raw_available: bool
    raw_a: int | None
    raw_b: int | None
    diag2: int
    status: int
    simulated: bool

    @classmethod
    def decode(cls, reply, *, simulated=False, elapsed=0.0):
        flags = reply.diag2
        available = bool(flags & (1 << 11))
        return cls(now_iso(), round(elapsed, 6), reply.seq, reply.diag3,
                   reply.touch_raw, reply.touch_keys, reply.keys, bool(flags & 2),
                   bool(flags & 1), bool(flags & 16), bool(flags & 32),
                   bool(flags & 128), available,
                   (flags >> 9) & 1 if available else None,
                   (flags >> 10) & 1 if available else None,
                   flags, reply.status, simulated)


class ReadOnlyLink:
    """成功收到匹配09才叫 connected；任一通信异常立即清除最新值并关闭。"""
    def __init__(self, factory=protocol.open_serial, *, timeout=0.8,
                 clock=time.monotonic, sleep=time.sleep, simulated=False):
        self.factory, self.timeout, self.clock, self.sleep = factory, timeout, clock, sleep
        self.simulated = simulated
        self.serial = self.client = self.latest = None
        self.state, self.error, self.port = "disconnected", "", ""
        self.started = clock()
        self.last_seq = -1  # retain transaction sequence across a reconnect

    def connect(self, port):
        if not port or not port.strip():
            raise ValueError("请先选择端口；工具不会自动扫描或尝试打开其他端口。")
        if self.serial is not None:
            raise RuntimeError("请先停止检测 / 断开")
        self.state, self.error, self.port = "connecting", "", port
        self.started = self.clock()
        try:
            self.serial = self.factory(port, self.timeout)
            self.client = protocol.DiagnosticClient(self.serial, self.timeout,
                                                     clock=self.clock, sleep=self.sleep)
            self.client.seq = (self.last_seq + 1) & 255
            return self.poll()
        except Exception as exc:
            self._fail(exc)
            raise

    def poll(self):
        if self.client is None:
            raise RuntimeError("未连接；没有有效诊断数据")
        try:
            reply = self.client.query()
            self.last_seq = reply.seq
            self.latest = Sample.decode(reply, simulated=self.simulated,
                                        elapsed=self.clock() - self.started)
            self.state, self.error = "connected", ""
            return self.latest
        except Exception as exc:
            if self.client is not None:
                self.last_seq = (self.client.seq - 1) & 255
            self._fail(exc)
            raise

    def _fail(self, exc):
        self.error = str(exc)
        self.disconnect()
        self.state = "error"

    def disconnect(self):
        serial, self.serial, self.client = self.serial, None, None
        self.latest = None
        self.state = "disconnected"
        if serial is not None:
            try:
                serial.close()
            except Exception as exc:
                self.error = "关闭串口异常：" + str(exc)


TOUCH_STAGES = (("idle", "全部松开，保持稳定"),
                ("touch4", "仅按住实际第2行第1列：4"),
                ("release4", "松开4，全部释放"),
                ("touch5", "仅按住实际第2行第2列：5"),
                ("release5", "松开5，全部释放"))
BEAM_STAGES = (("clear", "两束通光，确认无遮挡"),
               ("a", "仅遮挡A，B保持通光"),
               ("restore_a", "恢复两束通光"),
               ("b", "仅遮挡B，A保持通光"),
               ("restore_b", "恢复两束通光"),
               ("both", "同时遮挡A和B"),
               ("restore_both", "最后恢复两束通光"))
BEAM_EXPECTED = ((False, False), (True, False), (False, False),
                 (False, True), (False, False), (True, True), (False, False))


class StageTest:
    """每阶段由人确认动作后开始，之后的 N 个新回复构成证据；不复用旧值。"""
    def __init__(self, tool, *, samples=8, max_noise=8):
        if tool not in ("touch", "beam") or type(samples) is not int or not 3 <= samples <= 500:
            raise ValueError("tool需为touch/beam；阶段样本数需为3..500")
        if not 0 <= max_noise <= 4095:
            raise ValueError("max_noise需在0..4095")
        self.tool, self.count, self.max_noise = tool, samples, max_noise
        self.stages = TOUCH_STAGES if tool == "touch" else BEAM_STAGES
        self.results, self.pending = [], []
        self.active, self.aborted = False, ""

    @property
    def index(self):
        return len(self.results)

    @property
    def complete(self):
        return self.index == len(self.stages)

    @property
    def instruction(self):
        return "全部阶段已完成，可导出或重新开始" if self.complete else self.stages[self.index][1]

    def begin(self):
        if self.complete or self.active or self.aborted:
            raise RuntimeError("阶段已完成、正在采集或被中断；需要重新开始整套测试")
        self.pending, self.active = [], True

    def cancel(self, reason):
        self.active = False
        self.aborted = reason

    def accept(self, sample):
        if not self.active:
            return None
        self.pending.append(sample)
        if len(self.pending) < self.count:
            return None
        result = self._evaluate(self.pending)
        self.results.append(result)
        self.pending, self.active = [], False
        return result

    def _evaluate(self, samples):
        key, label = self.stages[self.index]
        reasons = []
        if len({s.seq for s in samples}) < 2:
            reasons.append("请求seq未变化，诊断证据不可信")
        raws = [s.raw for s in samples]
        low, high, center = min(raws), max(raws), statistics.median(raws)
        raw_ok, mask_ok = True, True
        if self.tool == "touch":
            if len({s.sample_seq for s in samples}) < 2:
                reasons.append("sample_seq未推进，可能采样停滞；推进本身也不证明ADC正常")
                raw_ok = False
            if high - low > self.max_noise:
                reasons.append(f"raw波动跨度{high-low}超过{self.max_noise}")
                raw_ok = False
            if key in ("touch4", "touch5"):
                expected = 1 << (4 if key == "touch4" else 5)
                if low < 8 or high > 4094:
                    reasons.append("按下raw未离开空闲/接近零或满量程；检查CH0、分压、参考电压")
                    raw_ok = False
                if not all(s.key_mask == expected for s in samples):
                    reasons.append(f"键mask未稳定识别为0x{expected:04X}；估算中心可能需要16键标定")
                    mask_ok = False
            else:
                if high >= 4:
                    reasons.append("释放raw应小于4；检查仍按住/偏置/CH0")
                    raw_ok = False
                if not all(s.key_mask == 0 for s in samples):
                    reasons.append("释放后键mask未清零")
                    mask_ok = False
                if self.results and abs(center - self.results[0]["center"]) > 3:
                    reasons.append("释放基线漂移超过3码")
                    raw_ok = False
            if any(s.fault for s in samples):
                reasons.append("touch fault=1：键解码/采样异常；raw响应不能替代解码通过")
                mask_ok = False
        else:
            expected = BEAM_EXPECTED[self.index]
            if not all(s.ready for s in samples):
                reasons.append("光束ready未始终为1：保持通光后整板重启，检查两对TX/RX供电")
            if not all((s.blocked_a, s.blocked_b) == expected for s in samples):
                reasons.append(f"遮挡不符：期望A={int(expected[0])} B={int(expected[1])}；"
                               "检查对准、独立供电、P8/P9和各自10k上拉")
        return {"stage": key, "label": label, "count": len(samples),
                "passed": not reasons, "reasons": reasons, "raw_response_ok": raw_ok,
                "key_decode_ok": mask_ok, "center": center, "low": low, "high": high,
                "samples": [asdict(s) for s in samples]}

    def conclusion(self, *, simulated=False):
        simulated = simulated or any(s["simulated"] for r in self.results for s in r["samples"])
        simulated = simulated or any(s.simulated for s in self.pending)
        reasons = [reason for r in self.results for reason in r["reasons"]]
        distinct = True
        if self.tool == "touch" and self.complete:
            a, b = self.results[1], self.results[3]
            if abs(a["center"] - b["center"]) < 12 or max(a["low"], b["low"]) <= min(a["high"], b["high"]):
                reasons.append("4与5的raw中心间隔不足12码或区间重叠；不能证明两键独立可辨")
                distinct = False
        if self.aborted:
            reasons.append("测试中断：" + self.aborted)
        complete = self.complete and not self.aborted
        passed = complete and not reasons
        status = "passed" if passed else ("failed" if complete else "incomplete")
        prefix = "【模拟】仅验证软件流程，不能算硬件通过。" if simulated else "【实机诊断】"
        summary = prefix + ("全部阶段判据通过。" if passed else
                            ("阶段判据未通过。" if complete else "阶段未完成，不能判定通过。"))
        if reasons:
            summary += "；".join(dict.fromkeys(reasons))
        summary += (" sample_seq推进不证明ADC正常；touch_valid只是单周期脉冲。"
                    if self.tool == "touch" else " 验证基于blocked/ready，不推断真实电平极性。")
        return {"status": status, "criteria_passed": passed,
                "hardware_passed": passed and not simulated,
                "scope": "释放/4/释放/5/释放" if self.tool == "touch" else "两束通光/A/B/双遮挡及恢复",
                "raw_response_ok": complete and distinct and all(r["raw_response_ok"] for r in self.results)
                                   if self.tool == "touch" else None,
                "key_decode_ok": complete and all(r["key_decode_ok"] for r in self.results)
                                 if self.tool == "touch" else None,
                "summary_zh": summary, "reasons": reasons,
                "completed_stages": self.index, "total_stages": len(self.stages)}


class Evidence:
    """导出CSV全部诊断、JSON阶段证据和中文结论；目录永不覆盖。"""
    def __init__(self, tool, simulated=False, port=""):
        self.tool, self.simulated, self.port = tool, simulated, port
        self.created = now_iso()
        self.samples, self.events = [], []

    def event(self, kind, detail):
        self.events.append({"timestamp": now_iso(), "kind": kind, "detail": detail})

    def save(self, base, test):
        path = unique_folder(base, ("模拟_" if self.simulated else "实机_") + self.tool)
        report = {"schema": "v021.peripheral-testbench.1", "created": self.created,
                  "exported": now_iso(), "tool": self.tool, "simulated": self.simulated,
                  "hardware_measured": bool(self.samples) and not self.simulated,
                  "port": self.port, "baud": 115200, "protocol": "09 / 16字节 / flag80只读",
                  "firmware_programmed": False, "calibration_applied": False,
                  "notes": [MENU_NOTICE, TOUCH_WIRING, BEAM_WIRING, RAW_NOTICE,
                            "touch_valid为单周期；sample_seq只说明数字采样流程活动。"],
                  "policy": {"samples_per_stage": test.count, "max_noise": test.max_noise,
                             "idle_raw_exclusive_max": 4, "minimum_center_separation": 12},
                  "conclusion": test.conclusion(simulated=self.simulated),
                  "stages": test.results, "pending_samples": [asdict(s) for s in test.pending],
                  "samples": [asdict(s) for s in self.samples], "events": self.events}
        (path / "诊断报告.json").write_text(json.dumps(report, ensure_ascii=False, indent=2)
                                             + "\n", encoding="utf-8")
        with (path / "原始采样.csv").open("w", newline="", encoding="utf-8-sig") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(Sample.__dataclass_fields__))
            writer.writeheader()
            writer.writerows(asdict(s) for s in self.samples)
        (path / "中文结论.txt").write_text(report["conclusion"]["summary_zh"] + "\n\n"
            + MENU_NOTICE + "\n" + RAW_NOTICE + "\n未烧录；本报告未写校准。\n", encoding="utf-8-sig")
        return path
