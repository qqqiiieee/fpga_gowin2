"""仅显式入口调用的原校准器桥接；普通检测不经过此模块的运行函数。"""
from pathlib import Path

from .vendor import touch_calibrate as tc


class CancellableSerial:
    """取消后不再发送；已发出但未收到ACK的写由原校准器记录为unconfirmed。"""
    def __init__(self, serial, cancelled):
        object.__setattr__(self, "_serial", serial)
        object.__setattr__(self, "_cancelled", cancelled)

    def __getattr__(self, name):
        return getattr(self._serial, name)

    def __setattr__(self, name, value):
        setattr(self._serial, name, value)

    def write(self, data):
        if self._cancelled.is_set():
            raise OSError("用户取消校准；已发出的写入状态以报告为准")
        return self._serial.write(data)

    def read(self, count):
        if self._cancelled.is_set():
            raise OSError("用户取消校准；未确认ACK不能当作成功")
        return self._serial.read(count)


def calibration_arguments(port, output, *, apply=False):
    if not port or not port.strip():
        raise ValueError("校准必须指定用户选择的实际串口")
    args = ["calibrate", "--port", port, "--output-dir", str(Path(output))]
    if apply:
        args.append("--apply")
    return args


def run_calibration(port, output, *, apply=False, prompt=input, emit=print, **injected):
    args = tc.parser().parse_args(calibration_arguments(port, output, apply=apply))
    return tc.run_command(args, prompt=prompt, emit=emit, **injected)
