"""无硬件的严格串口替身：只接受16字节只读80请求；不加载pyserial。"""
from __future__ import annotations

import functools
import operator
import time


def reply_frame(seq, *, raw=0, mask=0, diag2=128, sample_seq=1, version=9):
    fields = [0x5A, 0xA5, version, seq, 0]
    for word in (0, raw, mask, diag2, sample_seq):
        fields.extend((word & 255, word >> 8))
    fields.append(functools.reduce(operator.xor, fields[2:], 0))
    return bytes(fields)


class SimulatedSerial:
    def __init__(self, *, fault="none", raw_capability=False, clock=None, sleep=time.sleep):
        self.fault, self.raw_capability = fault, raw_capability
        self.clock, self.sleep = clock, sleep
        self.timeout, self.write_timeout = 0.05, 0.8
        self.closed, self.requests = False, []
        self.stage, self.counter = "idle", 0
        self.incoming, self.outgoing = bytearray(), bytearray()

    def set_stage(self, name):
        self.stage = name

    def write(self, data):
        if self.closed:
            raise OSError("模拟设备已断开")
        if self.fault == "disconnect" and self.counter >= 3:
            raise OSError("模拟USB拔出")
        self.incoming.extend(data)
        while len(self.incoming) >= 16:
            packet = bytes(self.incoming[:16])
            del self.incoming[:16]
            if (packet[:2] != b"\xa5\x5a" or packet[3] != 0x80
                    or packet[4:15] != bytes(11)
                    or functools.reduce(operator.xor, packet[2:], 0)):
                raise OSError("模拟器拒绝非只读80请求或错误帧")
            self.requests.append(packet)
            self.counter += 1
            if self.fault == "timeout":
                continue
            raw, mask = {"touch4": (920, 16), "touch5": (1180, 32)}.get(self.stage, (0, 0))
            blocked = {"a": 1, "b": 2, "both": 3}.get(self.stage, 0)
            if self.fault == "stuck":
                raw, mask, blocked = 0, 0, 0
            if self.fault == "swapped":
                blocked = ((blocked & 1) << 1) | ((blocked & 2) >> 1)
            if self.fault == "noise" and raw:
                raw += 30 * (self.counter % 2)
            flags = (0 if self.fault == "not-ready" else 128) | (blocked << 4)
            if self.fault == "touch-fault":
                flags |= 2
            # 正常模拟刻意让valid一直为0，证明它不是在线判据。
            if self.raw_capability:
                flags |= 1 << 11
                flags |= ((~blocked & 1) << 9) | (((~blocked >> 1) & 1) << 10)
            seq = (packet[2] + (1 if self.fault == "wrong-seq" else 0)) & 255
            response = reply_frame(seq, raw=raw, mask=mask, diag2=flags,
                sample_seq=7 if self.fault == "frozen-seq" else self.counter & 65535)
            if self.fault == "bad-xor":
                response = response[:-1] + bytes([response[-1] ^ 1])
            self.outgoing.extend(response)
        return len(data)

    def read(self, count):
        if self.closed:
            raise OSError("模拟设备已断开")
        if not self.outgoing:
            self.sleep(self.timeout)
            return b""
        count = min(count, 3)  # force fragmented frames
        result = bytes(self.outgoing[:count])
        del self.outgoing[:count]
        return result

    def close(self):
        self.closed = True
