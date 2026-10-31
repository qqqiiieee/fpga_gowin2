"""No-compile timing witness for the unchanged V038 ESP source.

This is an explicit reduced Python scheduling/parser model, NOT execution of the
C++ Core and NOT a board measurement. Guards bind its relevant predicates to the
reviewed source. native_loop_latency_repro.cpp is the actual-Core counterpart,
provided but deliberately not compiled/executed per user instruction.
"""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT/'esp32_phone/bridge_core.h'
core = CORE.read_text(encoding='utf-8')
for guard in [
    'uint32_t(now-lastPoll)<120', 'if(uint32_t(now-lastPoll)<120) return;',
    'lastPoll=now; start(get,now);', 'uint32_t(now-telemetry.captureStart)>=500',
    'if (used && uint32_t(now-last)>=20) used=0;',
    'if(b[7]&0x80 || b[8]>1 || b[9]>3) return false;']:
    assert guard in core, ('Reviewed predicate changed; re-audit model', guard)


class Model:
    def __init__(self, feature='supported'):
        self.now = 1000
        self.last_poll = 0
        self.last_ack = self.now
        self.last_start = 0
        self.start = 0
        self.started = self.active = self.validating = False
        self.next = 16
        self.snapshots = self.aborted = self.rx = 0
        self.feature, self.last_probe, self.probes = feature, 0, 0
        self.pending = None
        self.tick()

    def abort(self):
        self.aborted += int(self.active)
        self.active = self.validating = False
        self.next = 16

    def tick(self):
        assert self.now-self.last_ack < 1500  # healthy UART, before timeout check
        if self.active and self.now-self.start >= 500:
            self.abort()
        if self.feature == 'unavailable' and self.now-self.last_probe >= 1000 and self.now-self.last_poll < 120:
            self.last_probe = self.now
            self.probes += 1
            self.pending = 31
        elif self.active:
            self.pending = self.next
        elif self.feature == 'supported' and self.now-self.last_poll < 120 and (not self.started or self.now-self.last_start >= 200):
            self.active = self.started = True
            self.start = self.last_start = self.now
            self.next = self.pending = 16
        elif self.now-self.last_poll >= 120:
            self.last_poll = self.now
            self.pending = 0  # regular GET; chosen parameter immaterial here

    def step(self, gap):
        self.now += gap
        if self.pending is not None:
            p, self.pending = self.pending, None
            self.last_ack = self.now
            self.rx += 1
            if p == 31:
                self.feature = 'supported'
            elif p >= 16:
                if self.now-self.start >= 500:
                    self.abort()
                elif self.validating:
                    self.snapshots += 1
                    self.active = self.validating = False
                elif p < 30:
                    self.next += 1
                else:
                    self.validating, self.next = True, 22
        self.tick()


def parser_witness(split_gap):
    # Exact v1 framing/XOR and relevant Parser.feed logic, with read timestamps.
    frame = [0x5a,0xa5,1,0,0,15,0x38,0x38,0,0,40]
    xor = 0
    for v in frame[2:11]: xor ^= v
    frame.append(xor)
    buf, last, accepted = [], 0, 0
    for i, value in enumerate(frame):
        now = 1 if i < 6 else 1+split_gap
        if buf and now-last >= 20: buf = []
        last = now
        if not buf:
            if value == 0x5a: buf.append(value)
        elif len(buf) == 1:
            if value == 0xa5: buf.append(value)
            else: buf = [value] if value == 0x5a else []
        else:
            buf.append(value)
            if len(buf) == 12:
                accepted += int(buf == frame)
                buf = []
    return accepted


cases = []
for gap in [5, 30, 32, 120, 150]:
    m = Model()
    for _ in range(300): m.step(gap)
    assert (m.snapshots > 0) if gap <= 30 else m.snapshots == 0
    if gap == 32: assert m.aborted > 0
    if gap >= 120: assert not m.started and m.aborted == 0
    cases.append(dict(loop_gap_ms=gap, accepted_acks=m.rx, linked=True, synced=True,
                      snapshots=m.snapshots, aborted=m.aborted, ever_started=m.started))
m = Model()
for _ in range(3): m.step(5)
assert m.active
m.step(600)
assert m.aborted == 1 and m.snapshots == 0
for _ in range(40): m.step(5)
assert m.snapshots > 0
assert parser_witness(5) == 1 and parser_witness(50) == 0
retry = Model(feature='unavailable')
for _ in range(300): retry.step(120)
assert retry.probes == 0 and retry.feature == 'unavailable'
# The reported FPGA statuses do not trip the actual common ACK-field guard.
assert all((flags & 0x80) == 0 for flags in (0x38,0x78))
report = dict(model_checks_passed=True, model_only=True, actual_cpp_core_executed=False,
    cpp_repro_compiled=False, hardware_access=False, production_code_modified=False,
    core_sha256=hashlib.sha256(CORE.read_bytes()).hexdigest(), cases=cases,
    isolated_600ms_http_stall=dict(aborted=1, recovered_after_fast_loops=True),
    parser_split_ack_model=dict(wire_response_complete_by_ms=2.2,
        prefix_drained_at_ms=1, suffix_drained_at_ms=51, accepted_frames=0,
        same_bytes_5ms_drain_gap_accepted_frames=1),
    unavailable_reprobe_at_120ms_loop=dict(capability_requests=retry.probes, feature=retry.feature),
    numeric_common_flags_0x38_0x78_not_rejected=True,
    status_note='USB debug flags and phone_status_exact are different mappings. ADS fault/stale does not itself invalidate a UART ACK.')
destination = ROOT/'validation/read_only_loop_audit.json'
destination.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
print(json.dumps(report, indent=2))
