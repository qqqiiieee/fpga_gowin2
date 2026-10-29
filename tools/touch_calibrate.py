"""V018 GVS/MCP3208 diagnostics and interactive calibration (no FPGA programming).

Only diagnostic flags 0x80/0x81 are sent. They neither select nor renew remote mode.
pyserial is imported only when opening/listing ports; protocol/tests use stdlib.
The module's 3V3 supply connection is user-confirmed, not physically tested here.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import importlib
import json
from pathlib import Path
import statistics
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
LABELS = ("1", "2", "3", "A", "4", "5", "6", "B",
          "7", "8", "9", "C", "*", "0", "#", "D")
BAUD = 115200


class ProtocolError(ValueError):
    pass


class DiagnosticTimeout(TimeoutError):
    pass


class CalibrationError(ValueError):
    pass


class ApplyError(RuntimeError):
    pass


def checked_int(value, low, high, name):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{name} 必须是 {low}..{high} 的整数")
    return value


def xor_bytes(data):
    result = 0
    for byte in data:
        result ^= byte
    return result


def encode_request(seq, index=None, value=None):
    """16 bytes; unspecified payload is always zero (including velocity)."""
    checked_int(seq, 0, 255, "seq")
    packet = bytearray(16)
    packet[:4] = bytes((0xA5, 0x5A, seq, 0x80))
    if index is not None:
        checked_int(index, 0, 15, "cal_index")
        checked_int(value, 8, 4094, "cal_value")
        packet[3], packet[4] = 0x81, index
        packet[7:9] = value.to_bytes(2, "little")
    elif value is not None:
        raise ValueError("cal_value 不能缺少 cal_index")
    packet[15] = xor_bytes(packet[2:15])
    return bytes(packet)


@dataclass(frozen=True)
class Diagnostic:
    seq: int
    status: int
    keys: int
    touch_raw: int
    touch_keys: int
    diag2: int
    diag3: int


def parse_diagnostic(packet):
    if len(packet) != 16 or packet[:3] != b"\x5a\xa5\x09":
        raise ProtocolError("诊断帧必须是 16 bytes、5A A5、版本 09；08 ACK 不能替代")
    if xor_bytes(packet[2:15]) != packet[15]:
        raise ProtocolError("诊断帧 XOR 错误")
    words = [int.from_bytes(packet[i:i + 2], "little") for i in (5, 7, 9, 11, 13)]
    if words[1] > 4095:
        raise ProtocolError("touch_raw 超出 12 bit")
    return Diagnostic(packet[3], packet[4], *words)


class DiagnosticStream:
    """Bounded stream synchronizer, including embedded headers after bad XOR."""
    def __init__(self):
        self.buffer = bytearray()
        self.bad_frames = 0

    def feed(self, data):
        self.buffer.extend(data)
        replies = []
        while self.buffer:
            offset = self.buffer.find(b"\x5a\xa5")
            if offset < 0:
                self.buffer[:] = b"\x5a" if self.buffer.endswith(b"\x5a") else b""
                break
            del self.buffer[:offset]
            if len(self.buffer) < 16:
                break
            try:
                reply = parse_diagnostic(bytes(self.buffer[:16]))
            except ProtocolError:
                self.bad_frames += 1
                del self.buffer[0]
            else:
                del self.buffer[:16]
                replies.append(reply)
        return replies


class DiagnosticClient:
    """One outstanding transaction. No retry of uncertain calibration writes."""
    def __init__(self, serial, timeout=0.8, *, clock=time.monotonic, sleep=time.sleep):
        if not 0 < timeout <= 60:
            raise ValueError("timeout 必须在 (0, 60] 秒")
        self.serial, self.timeout = serial, timeout
        self.clock, self.sleep = clock, sleep
        self.seq = 0
        self.stream = DiagnosticStream()
        self.ignored_seq = 0

    def _exchange(self, index=None, value=None):
        seq = self.seq
        packet = encode_request(seq, index, value)
        self.seq = (seq + 1) & 255
        deadline = self.clock() + self.timeout
        # Only leftovers from a previous transaction are discarded, never device settings.
        self.stream.buffer.clear()
        sent = 0
        while sent < len(packet):
            remaining = deadline - self.clock()
            if remaining <= 0:
                raise DiagnosticTimeout("发送超时；写入状态未知，请勿假定未执行")
            self.serial.write_timeout = remaining
            count = self.serial.write(packet[sent:])
            if not isinstance(count, int) or not 0 < count <= len(packet) - sent:
                raise OSError("串口短写无进展；停止，写入状态未知")
            sent += count
        while self.clock() < deadline:
            remaining = deadline - self.clock()
            self.serial.timeout = min(0.05, remaining)
            chunk = self.serial.read(256)
            for reply in self.stream.feed(chunk):
                if reply.seq != seq:
                    self.ignored_seq += 1
                    continue
                if self.clock() > deadline:
                    break
                return reply
            if not chunk:
                self.sleep(min(0.002, max(0.0, deadline - self.clock())))
        raise DiagnosticTimeout(
            f"未收到匹配 seq={seq} 的版本09诊断（坏帧={self.stream.bad_frames}，"
            f"错序号={self.ignored_seq}）。检查端口、接线及启用 DIAG_ENABLE 的固件；"
            "仅有08 ACK不算成功。")

    def query(self):
        return self._exchange()

    def write_center(self, index, value):
        reply = self._exchange(index, value)
        if reply.diag2 != ((index << 12) | value) or reply.diag3 != (0xA100 | index):
            raise ProtocolError(
                f"写ACK不匹配 index={index}, value={value}："
                f"diag2=0x{reply.diag2:04X}, diag3=0x{reply.diag3:04X}；"
                "运行时中心可能已改变")
        return reply


@dataclass(frozen=True)
class Policy:
    samples: int = 24
    interval: float = 0.03
    settle: float = 0.25
    max_noise: int = 8
    min_separation: int = 12
    release_tolerance: int = 3
    release_delta: int = 4
    guard_samples: int = 3

    def __post_init__(self):
        checked_int(self.samples, 3, 10000, "samples")
        checked_int(self.guard_samples, 3, 1000, "guard_samples")
        for name in ("max_noise", "release_tolerance"):
            checked_int(getattr(self, name), 0, 4094, name)
        checked_int(self.min_separation, 12, 4094, "min_separation")
        checked_int(self.release_delta, 1, 4094, "release_delta")
        if not 0.001 <= self.interval <= 10 or not 0 <= self.settle <= 60:
            raise ValueError("interval 必须在 [0.001,10]，settle 在 [0,60] 秒")


@dataclass(frozen=True)
class SampleWindow:
    center: int
    low: int
    high: int
    count: int


def summarize(values, policy):
    if len(values) < 3:
        raise CalibrationError("稳定采样至少需要3个原始码")
    for value in values:
        checked_int(value, 0, 4095, "touch_raw")
    low, high = min(values), max(values)
    if high - low > policy.max_noise:
        raise CalibrationError(f"采样噪声跨度 {high - low} > {policy.max_noise}；保持手指稳定并检查共地")
    return SampleWindow(int(round(statistics.median(values))), low, high, len(values))


def capture_window(client, policy, *, sleep=time.sleep, count=None, released=None):
    values = []
    for index in range(policy.samples if count is None else count):
        if index:
            sleep(policy.interval)
        reply = client.query()
        if released is not None:
            ensure_released(reply, released, policy)
        values.append(reply.touch_raw)
    return summarize(values, policy)


def validate_centers(windows, policy):
    if len(windows) != 16:
        raise CalibrationError("必须完整采集16键；不会写入部分标定表")
    for i, item in enumerate(windows):
        if (not 8 <= item.center <= 4094 or item.low < 4 or item.high > 4094):
            raise CalibrationError(f"位置{i}({LABELS[i]})接近零/满量程；检查供电、分压和CH0")
        if item.count < 3 or not item.low <= item.center <= item.high or item.high - item.low > policy.max_noise:
            raise CalibrationError(f"位置{i}采样数量、范围或噪声不合格")
        for j in range(i):
            other = windows[j]
            if (abs(item.center - other.center) < policy.min_separation
                    or max(item.low, other.low) <= min(item.high, other.high)):
                raise CalibrationError(f"位置{j}({LABELS[j]})与{i}({LABELS[i]})中心太近或噪声区间重叠")
    for i, (item, tolerance) in enumerate(zip(windows, dynamic_tolerances(windows))):
        if 2 * (item.high - item.low) >= tolerance:
            raise CalibrationError(f"位置{i}波动过大：跨度{item.high - item.low}，动态容差{tolerance}；"
                                   "跨度必须小于容差的一半（明显小于邻档gap/4）")


def dynamic_tolerances(windows):
    return [max(2, min(32, min(abs(item.center - other.center)
                              for j, other in enumerate(windows) if j != i) // 4))
            for i, item in enumerate(windows)]


def collect_calibration(client, policy, *, prompt=input, emit=print, sleep=time.sleep):
    windows, releases = [], []
    for index, label in enumerate(LABELS):
        place = f"第{index // 4 + 1}行第{index % 4 + 1}列 / {label} / index={index}"
        prompt(f"[{place}] 先松开全部触摸键，稳定后按 Enter：")
        sleep(policy.settle)
        release = capture_window(client, policy, sleep=sleep)
        if release.high >= 4:
            raise CalibrationError("松开原始码必须<4；检查仍按住、CH0接线或前端偏置，不写中心")
        if releases and abs(release.center - releases[0].center) > policy.release_tolerance:
            raise CalibrationError("松开基线漂移或仍有按键；停止采集，不写中心")
        releases.append(release)
        prompt(f"[{place}] 按住该实际位置；保持按住，用另一只手按 Enter 开始采样：")
        sleep(policy.settle)
        held = capture_window(client, policy, sleep=sleep)
        if min(abs(held.low - release.center), abs(held.high - release.center)) < policy.release_delta or (
                held.low <= release.center <= held.high):
            raise CalibrationError(f"位置{index}按住与松开太近；未检测到可信按键")
        # Reject rails/separation immediately, while still requiring all 16 before writing.
        windows.append(held)
        for i, item in enumerate(windows):
            if not 8 <= item.center <= 4094 or item.low < 4 or item.high > 4094:
                raise CalibrationError(f"位置{i}接近零/满量程；不写中心")
        for other in windows[:-1]:
            if (abs(held.center - other.center) < policy.min_separation
                    or max(held.low, other.low) <= min(held.high, other.high)):
                raise CalibrationError(f"位置{index}中心太近或区间重叠；按实际位置重新采集")
        emit(f"已采集 {index + 1}/16：{label} center={held.center}，范围={held.low}..{held.high}")
    validate_centers(windows, policy)
    return windows, releases


def ensure_released(reply, release, policy):
    if (reply.touch_raw >= 4 or abs(reply.touch_raw - release.center) > policy.release_tolerance
            or reply.touch_keys != 0):
        raise CalibrationError("运行时写入要求保持全松：原始码偏离松开基线或touch_keys非零；停止写入")


def apply_centers(client, windows, release, policy, *, sleep=time.sleep, progress=None):
    """Verify every write receipt, then query. ACK does not read back the whole table."""
    validate_centers(windows, policy)
    receipts = []
    try:
        for index, window in enumerate(windows):
            capture_window(client, policy, sleep=sleep, count=policy.guard_samples, released=release)
            reply = client.write_center(index, window.center)
            ensure_released(reply, release, policy)
            receipts.append(asdict(reply))
            if progress:
                progress(receipts[:])
        # Query is a fresh 0x80 transaction, not reuse of the last write ACK.
        capture_window(client, policy, sleep=sleep, count=policy.guard_samples, released=release)
    except (OSError, ValueError, RuntimeError) as exc:
        raise ApplyError(
            f"运行时写入未完成：仅确认{len(receipts)}/16项。表可能部分更新，"
            "请保持全松；排障后重新完整标定/应用。原因：" + str(exc)) from exc
    return {"status": "confirmed", "writes_confirmed": 16, "query_confirmed": True,
            "receipts": receipts, "runtime_only": True,
            "verification": "16 matching index/value write ACKs + released query; no table-readback command"}


def save_calibration(output_dir, windows, releases, policy):
    validate_centers(windows, policy)
    folder = Path(output_dir)
    # New directory only: never overwrite existing captures, source or firmware.
    folder.mkdir(parents=True, exist_ok=False)
    report = {"schema": "v018.touch-calibration.1", "schema_version": 1,
              "status": "measured_calibration", "hardware_measured": True,
              "runtime_calibration_required": False,
              "measurement_note": "逐键手动确认后经UART09采集原始码；不代表模块供电或模拟电压已用仪表实测",
              "created_utc": datetime.now(timezone.utc).isoformat(),
              "protocol": 9, "baud": BAUD, "labels_rowmajor": list(LABELS),
              "row_major_keys": list(LABELS),
              "centers": [item.center for item in windows],
              "samples": [asdict(item) for item in windows],
              "dynamic_tolerances": dynamic_tolerances(windows),
              "release_samples": [asdict(item) for item in releases], "policy": asdict(policy),
              "hex_intended_project_path": "src/touch_centers.hex",
              "hex_format": "16 rowmajor unsigned 12-bit words; 3 hexadecimal digits per line",
              "apply": {"status": "not_requested", "writes_confirmed": 0, "query_confirmed": False},
              "firmware_programmed": False}
    (folder / "touch_centers.hex").write_text(
        "".join(f"{item.center:03x}\n" for item in windows), encoding="ascii")
    write_report(folder, report)
    return report


def write_report(folder, report):
    Path(folder, "touch_calibration.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def load_pyserial():
    try:
        return importlib.import_module("serial")
    except ImportError as exc:
        # Some handoff packages keep pyserial alongside the tool, not site-packages.
        for path in (ROOT / "runtimepyserial", ROOT / "tools" / "runtimepyserial"):
            if (path / "serial" / "__init__.py").is_file():
                sys.path.insert(0, str(path))
                return importlib.import_module("serial")
        raise RuntimeError("需要 pyserial：使用项目含pyserial的Python，或 python -m pip install pyserial；单元测试无需它") from exc


def list_ports():
    load_pyserial()
    ports = importlib.import_module("serial.tools.list_ports")
    return [{"port": p.device, "description": p.description, "hwid": p.hwid} for p in ports.comports()]


def open_serial(port, timeout):
    serial = load_pyserial()
    return serial.Serial(port=port, baudrate=BAUD, bytesize=serial.EIGHTBITS,
                         parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
                         timeout=min(0.05, timeout), write_timeout=timeout,
                         xonxoff=False, rtscts=False, dsrdtr=False)


def configured_port(path):
    try:
        port = json.loads(Path(path).read_text(encoding="utf-8-sig")).get("port")
    except (OSError, ValueError, AttributeError) as exc:
        raise ValueError("读取device_config失败；请显式传 --port 或 --config") from exc
    if not isinstance(port, str) or not port.strip():
        raise ValueError("device_config未提供port；请使用 --port")
    return port.strip()


def parser():
    result = argparse.ArgumentParser(description="GVS触摸诊断/标定：默认monitor，绝不隐式写中心或烧录")

    def common(target, suppressed=False):
        default = argparse.SUPPRESS if suppressed else None
        target.add_argument("--port", default=default, help="例如COM8；缺省读取device_config当前值")
        target.add_argument("--config", type=Path, default=argparse.SUPPRESS if suppressed else ROOT / "device_config.json")
        target.add_argument("--timeout", type=float, default=argparse.SUPPRESS if suppressed else 0.8)
        target.add_argument("--list", action="store_true", default=argparse.SUPPRESS if suppressed else False,
                            help="只枚举，不打开串口")

    common(result)
    commands = result.add_subparsers(dest="command")
    monitor = commands.add_parser("monitor", help="只发0x80查询；Ctrl+C结束")
    common(monitor, True)
    monitor.add_argument("--count", type=int, default=0, help="0=持续观察")
    monitor.add_argument("--interval", type=float, default=0.1)
    calibrate = commands.add_parser("calibrate", help="按实际位置完整采集16键，默认只保存")
    common(calibrate, True)
    calibrate.add_argument("--output-dir", type=Path, required=True, help="新的输出目录（必须不存在）")
    calibrate.add_argument("--apply", action="store_true", help="采集全部合格后显式写运行时表并验证ACK")
    for name in Policy.__dataclass_fields__:
        value = getattr(Policy(), name)
        calibrate.add_argument("--" + name.replace("_", "-"), type=type(value), default=value)
    return result


def run_command(args, *, serial_factory=open_serial, enumerate_fn=list_ports,
                prompt=input, emit=print, clock=time.monotonic, sleep=time.sleep):
    if args.list:
        emit(json.dumps(enumerate_fn(), ensure_ascii=False, indent=2))
        return 0
    policy = None
    if args.command == "calibrate":
        policy = Policy(**{name: getattr(args, name) for name in Policy.__dataclass_fields__})
        if args.output_dir.exists():
            raise FileExistsError("输出目录已存在；请指定新目录，避免覆盖原数据")
    else:
        if getattr(args, "count", 0) < 0 or not 0.001 <= getattr(args, "interval", 0.1) <= 10:
            raise ValueError("count不能为负；interval必须在[0.001,10]秒")
    if not 0 < args.timeout <= 60:
        raise ValueError("timeout必须在(0,60]秒")
    port = args.port or configured_port(args.config)
    serial = serial_factory(port, args.timeout)
    try:
        client = DiagnosticClient(serial, args.timeout, clock=clock, sleep=sleep)
        if args.command != "calibrate":
            count = 0
            while True:
                reply = client.query()
                emit(f"raw={reply.touch_raw:4d} touch_keys=0x{reply.touch_keys:04X} "
                     f"keys=0x{reply.keys:04X} status=0x{reply.status:02X} "
                     f"diag2=0x{reply.diag2:04X} diag3=0x{reply.diag3:04X} seq={reply.seq}")
                count += 1
                if getattr(args, "count", 0) and count >= args.count:
                    return 0
                sleep(getattr(args, "interval", 0.1))
        emit("按实际4×4位置采集；商家B/C重印不作电压表依据。每次只按一个触摸键。")
        windows, releases = collect_calibration(client, policy, prompt=prompt, emit=emit, sleep=sleep)
        report = save_calibration(args.output_dir, windows, releases, policy)
        emit(f"16项采集合格，已保存：{args.output_dir.resolve()}；尚未写入运行时中心。")
        if not args.apply:
            return 0
        report["apply"]["status"] = "awaiting_release"
        write_report(args.output_dir, report)
        try:
            prompt("--apply：松开全部触摸键并在写入期间保持全松，按 Enter 开始：")
            sleep(policy.settle)
            report["apply"]["status"] = "in_progress"
            write_report(args.output_dir, report)

            def progress(receipts):
                report["apply"].update(writes_confirmed=len(receipts), receipts=receipts)
                write_report(args.output_dir, report)

            report["apply"] = apply_centers(client, windows, releases[0], policy, sleep=sleep, progress=progress)
        except (Exception, KeyboardInterrupt) as exc:
            report["apply"].update(status="unconfirmed", query_confirmed=False, error=str(exc) or "用户中断")
            write_report(args.output_dir, report)
            raise
        write_report(args.output_dir, report)
        emit("运行时中心已确认16/16写ACK，随后全松query通过；未烧录，断电持久性未验证。")
        return 0
    finally:
        serial.close()


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        return run_command(args)
    except KeyboardInterrupt:
        print("已中断；若处于--apply中，运行时表可能部分更新。", file=sys.stderr)
        return 130
    except (OSError, ValueError, RuntimeError, EOFError) as exc:
        print("失败：" + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
