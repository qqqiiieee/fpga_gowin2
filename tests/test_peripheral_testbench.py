"""纯离线测试：不导入真实serial；临时文件仅写在获准的工具目录内。

运行：python -B -m unittest discover -s tests -p test_peripheral_testbench.py -v
"""
import csv
from dataclasses import replace
import functools
import hashlib
import json
import operator
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

PROJECT = Path(__file__).resolve().parents[1]
PACKAGE = PROJECT / "tools" / "peripheral_testbench"
sys.path.insert(0, str(PROJECT / "tools"))
from peripheral_testbench import calibration, cli, core
from peripheral_testbench.simulation import SimulatedSerial
tc = core.protocol


def wire(seq=0, raw=0, mask=0, flags=128, sample_seq=1, version=9):
    # Independent byte encoder: does not use the simulator or production encoder.
    result = [90, 165, version, seq, 0, 0, 0, raw & 255, raw >> 8,
              mask & 255, mask >> 8, flags & 255, flags >> 8,
              sample_seq & 255, sample_seq >> 8]
    return bytes(result + [functools.reduce(operator.xor, result[2:], 0)])


def sample(**changes):
    defaults = dict(seq=0, raw=0, mask=0, flags=128, sample_seq=1)
    defaults.update(changes)
    return core.Sample.decode(tc.parse_diagnostic(wire(**defaults)))


class Clock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, amount):
        self.now += amount


class Peer:
    def __init__(self, clock, transform=lambda packet: wire(packet[2]), chunk=3, write_chunk=5):
        self.clock, self.transform = clock, transform
        self.chunk, self.write_chunk = chunk, write_chunk
        self.pending, self.output, self.packets = bytearray(), bytearray(), []
        self.closed = False
        self.timeout, self.write_timeout = 0.01, 0.05

    def write(self, data):
        if self.closed:
            raise OSError("device removed")
        count = min(len(data), self.write_chunk)
        self.pending.extend(data[:count])
        if len(self.pending) == 16:
            packet = bytes(self.pending)
            self.pending.clear()
            self.packets.append(packet)
            self.output.extend(self.transform(packet))
        return count

    def read(self, count):
        if not self.output:
            self.clock.sleep(self.timeout)
        result = bytes(self.output[:min(count, self.chunk)])
        del self.output[:len(result)]
        return result

    def close(self):
        self.closed = True


class FileCase(unittest.TestCase):
    def setUp(self):
        folder = PACKAGE / "_test_tmp"
        folder.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=folder)
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)


class ProtocolTests(unittest.TestCase):
    def test_query_golden_vector_and_reserved_zero(self):
        self.assertEqual(tc.encode_request(0x2A), bytes.fromhex("a55a2a800000000000000000000000aa"))
        for seq in range(256):
            packet = tc.encode_request(seq)
            self.assertEqual(packet[3], 0x80)
            self.assertEqual(packet[4:15], bytes(11))
            self.assertEqual(functools.reduce(operator.xor, packet[2:], 0), 0)

    def test_independent_wire_field_layout(self):
        result = tc.parse_diagnostic(bytes.fromhex("5aa5091200341256033412b008fefff7"))
        self.assertEqual((result.seq, result.keys, result.touch_raw, result.touch_keys,
                          result.diag2, result.diag3), (18, 0x1234, 854, 0x1234, 0x8B0, 65534))

    def test_reject_ack_bad_xor_out_of_range_and_truncated(self):
        for packet in (wire(version=8), wire(raw=4096), wire()[:-1], wire()[:-1] + b"\xff"):
            with self.assertRaises(tc.ProtocolError):
                tc.parse_diagnostic(packet)

    def test_stream_resynchronizes_garbage_corruption_and_partial_header(self):
        stream = tc.DiagnosticStream()
        bad = wire()[:-1] + b"\xff"
        self.assertEqual(stream.feed(b"noise\x5a"), [])
        self.assertEqual(stream.feed(b"\xa5" + bad[2:] + wire(3)[:7]), [])
        result = stream.feed(wire(3)[7:])
        self.assertEqual([r.seq for r in result], [3])
        self.assertGreater(stream.bad_frames, 0)
        stream.feed(b"z" * 100000)
        self.assertLessEqual(len(stream.buffer), 1)

    def test_partial_read_write_and_wrong_sequence_are_handled(self):
        clock = Clock()
        peer = Peer(clock, transform=lambda p: wire((p[2]+1) & 255) + wire(p[2]))
        client = tc.DiagnosticClient(peer, 0.1, clock=clock.monotonic, sleep=clock.sleep)
        self.assertEqual(client.query().seq, 0)
        self.assertEqual(client.ignored_seq, 1)

    def test_only_ack_or_wrong_sequence_never_connects(self):
        for transform in (lambda p: wire(p[2], version=8), lambda p: wire((p[2]+1) & 255)):
            clock = Clock()
            peer = Peer(clock, transform=transform)
            link = core.ReadOnlyLink(lambda p, t: peer, timeout=0.05,
                                     clock=clock.monotonic, sleep=clock.sleep)
            with self.assertRaises(tc.DiagnosticTimeout):
                link.connect("MOCK")
            self.assertEqual(link.state, "error")
            self.assertIsNone(link.latest)
            self.assertTrue(peer.closed)

    def test_legacy_blocked_is_not_raw_even_if_reserved_raw_bits_are_set(self):
        result = sample(flags=128 | 16 | 512 | 1024)
        self.assertTrue(result.blocked_a)
        self.assertFalse(result.blocked_b)
        self.assertIsNone(result.raw_a)
        self.assertIsNone(result.raw_b)
        self.assertFalse(result.raw_available)

    def test_new_capability_bit_gates_raw_levels(self):
        result = sample(flags=128 | 2048 | 512 | 32)
        self.assertTrue(result.raw_available)
        self.assertEqual((result.raw_a, result.raw_b), (1, 0))
        self.assertEqual((result.blocked_a, result.blocked_b), (False, True))

    def test_fault_and_valid_are_independent(self):
        self.assertTrue(sample(flags=2).fault)
        self.assertFalse(sample(flags=2).touch_valid_pulse)
        self.assertFalse(sample(flags=1).fault)
        self.assertTrue(sample(flags=1).touch_valid_pulse)

    def test_vendor_is_exact_baseline_copy(self):
        expected = "c2bac656deec662c8d77a5e1fc2bae84dfa6990cc9887578f3cd71e91c8f951d"
        self.assertEqual(hashlib.sha256(Path(tc.__file__).read_bytes()).hexdigest(), expected)


class LinkTests(unittest.TestCase):
    def test_no_implicit_open_or_blank_port(self):
        factory = Mock()
        link = core.ReadOnlyLink(factory)
        with self.assertRaises(ValueError):
            link.connect(" ")
        with self.assertRaises(RuntimeError):
            link.poll()
        factory.assert_not_called()

    def test_open_error_not_connected(self):
        link = core.ReadOnlyLink(Mock(side_effect=OSError("access denied")))
        with self.assertRaises(OSError):
            link.connect("MOCK")
        self.assertEqual(link.state, "error")
        self.assertIsNone(link.latest)

    def test_valid_zero_can_be_connected_but_not_hardware_pass(self):
        peer = SimulatedSerial()
        link = core.ReadOnlyLink(lambda p, t: peer, simulated=True)
        result = link.connect("SIM")
        self.assertFalse(result.touch_valid_pulse)
        self.assertEqual(link.state, "connected")
        self.assertEqual(peer.requests[0][3], 0x80)
        link.disconnect()
        self.assertIsNone(link.latest)
        self.assertTrue(peer.closed)

    def test_poll_timeout_clears_previous_success_and_recovers(self):
        clock = Clock()
        first = Peer(clock)
        second = Peer(clock)
        peers = iter((first, second))
        link = core.ReadOnlyLink(lambda p, t: next(peers), timeout=0.05,
                                 clock=clock.monotonic, sleep=clock.sleep)
        link.connect("MOCK")
        first.transform = lambda p: b""
        with self.assertRaises(tc.DiagnosticTimeout):
            link.poll()
        self.assertEqual(link.state, "error")
        self.assertIsNone(link.latest)
        self.assertTrue(first.closed)
        self.assertEqual(link.connect("MOCK").seq, 2)
        self.assertEqual(link.state, "connected")
        link.disconnect()

    def test_usb_disconnect_is_error_and_can_reconnect(self):
        peer = SimulatedSerial()
        link = core.ReadOnlyLink(lambda p, t: peer, simulated=True)
        link.connect("SIM")
        peer.close()
        with self.assertRaises(OSError):
            link.poll()
        self.assertEqual(link.state, "error")
        self.assertIsNone(link.latest)
        link.factory = lambda p, t: SimulatedSerial()
        link.connect("SIM")
        link.disconnect()

    def test_zero_progress_write_is_failure(self):
        clock = Clock()
        peer = Peer(clock)
        peer.write = lambda data: 0
        link = core.ReadOnlyLink(lambda p, t: peer, clock=clock.monotonic, sleep=clock.sleep)
        with self.assertRaises(OSError):
            link.connect("MOCK")
        self.assertTrue(peer.closed)


def drive_test(tool="touch", fault="none", raw_capability=False, samples=4):
    peer = SimulatedSerial(fault=fault, raw_capability=raw_capability)
    link = core.ReadOnlyLink(lambda p, t: peer, simulated=True)
    test = core.StageTest(tool, samples=samples)
    link.connect("SIM")
    while not test.complete:
        peer.set_stage(test.stages[test.index][0])
        test.begin()
        while test.active:
            test.accept(link.poll())
    link.disconnect()
    return test, peer


class StageTests(unittest.TestCase):
    def test_all_touch_phases_and_release_masks(self):
        test, peer = drive_test()
        self.assertEqual([r["stage"] for r in test.results], ["idle", "touch4", "release4", "touch5", "release5"])
        self.assertTrue(test.conclusion()["criteria_passed"])
        self.assertFalse(test.conclusion(simulated=True)["hardware_passed"])
        self.assertFalse(test.conclusion()["hardware_passed"])  # infer from evidence too
        self.assertEqual({p[3] for p in peer.requests}, {0x80})

    def test_beam_independent_switches_restore_and_no_raw_requirement(self):
        for raw_capability in (False, True):
            test, _ = drive_test("beam", raw_capability=raw_capability)
            self.assertEqual(len(test.results), 7)
            self.assertTrue(test.conclusion()["criteria_passed"])

    def test_pending_not_reused_between_stages(self):
        test = core.StageTest("touch", samples=3)
        test.accept(sample())
        self.assertEqual(test.pending, [])
        test.begin()
        for seq in range(3):
            test.accept(sample(seq=seq, sample_seq=seq))
        self.assertEqual(len(test.results), 1)
        self.assertEqual(test.pending, [])
        test.begin()
        self.assertEqual(test.pending, [])

    def test_incomplete_or_cancelled_is_never_pass(self):
        test = core.StageTest("beam", samples=3)
        self.assertEqual(test.conclusion()["status"], "incomplete")
        test.begin()
        test.accept(sample())
        test.cancel("拔线")
        self.assertFalse(test.conclusion()["criteria_passed"])
        self.assertEqual(len(test.pending), 1)
        with self.assertRaises(RuntimeError):
            test.begin()

    def test_frozen_raw_is_not_validated_by_advancing_sample_seq(self):
        test, _ = drive_test(fault="stuck")
        self.assertFalse(test.conclusion()["criteria_passed"])
        self.assertTrue(any("raw" in r for r in test.conclusion()["reasons"]))

    def test_noise_fault_and_stalled_sequence_fail(self):
        for fault in ("noise", "touch-fault", "frozen-seq"):
            test, _ = drive_test(fault=fault)
            self.assertFalse(test.conclusion()["criteria_passed"], fault)

    def test_swapped_tied_stuck_and_not_ready_beams_fail(self):
        for fault in ("swapped", "stuck", "not-ready"):
            test, _ = drive_test("beam", fault=fault)
            self.assertFalse(test.conclusion()["criteria_passed"], fault)
        test = core.StageTest("beam", samples=3)
        test.begin()
        for seq in range(3):
            test.accept(sample(seq=seq, flags=128 | 16 | 32))
        self.assertFalse(test.results[0]["passed"])

    def test_one_bad_frame_in_window_fails_instead_of_majority_vote(self):
        test = core.StageTest("beam", samples=3)
        test.begin()
        for seq in range(3):
            test.accept(sample(seq=seq, flags=128 | (16 if seq == 1 else 0)))
        self.assertFalse(test.results[0]["passed"])

    def test_request_and_sample_seq_wrap_is_accepted(self):
        test = core.StageTest("touch", samples=3)
        test.begin()
        for seq, sample_seq in ((254, 65534), (255, 65535), (0, 0)):
            test.accept(sample(seq=seq, sample_seq=sample_seq))
        self.assertTrue(test.results[0]["passed"])

    def test_changing_seq_with_rail_raw_is_failure(self):
        for raw in (0, 4095):
            test = core.StageTest("touch", samples=3)
            test.begin()
            for seq in range(3):
                test.accept(sample(seq=seq, sample_seq=seq))
            test.begin()
            for seq in range(3, 6):
                test.accept(sample(seq=seq, sample_seq=seq, raw=raw, mask=16))
            self.assertFalse(test.results[1]["passed"])

    def test_mixed_key_mask_cannot_pass_single_key_phase(self):
        test = core.StageTest("touch", samples=3)
        test.begin()
        for seq in range(3):
            test.accept(sample(seq=seq, sample_seq=seq))
        test.begin()
        for seq in range(3, 6):
            test.accept(sample(seq=seq, sample_seq=seq, raw=920, mask=16 | 32))
        self.assertTrue(test.results[1]["raw_response_ok"])
        self.assertFalse(test.results[1]["key_decode_ok"])
        self.assertFalse(test.results[1]["passed"])

    def test_overlapping_centers_reject_global_pass(self):
        test, _ = drive_test()
        test.results[3].update(center=925, low=925, high=925)
        self.assertFalse(test.conclusion()["criteria_passed"])


class EvidenceAndCliTests(FileCase):
    def test_json_csv_legacy_null_raw_and_unique_directories(self):
        test, _ = drive_test("beam")
        evidence = core.Evidence("beam", True, "SIM")
        evidence.samples.append(replace(sample(flags=128 | 16), simulated=True))
        evidence.event("disconnected", "测试停止")
        first, second = evidence.save(self.output, test), evidence.save(self.output, test)
        self.assertNotEqual(first, second)
        data = json.loads((first / "诊断报告.json").read_text(encoding="utf-8"))
        self.assertIsNone(data["samples"][0]["raw_a"])
        self.assertFalse(data["conclusion"]["hardware_passed"])
        self.assertFalse(data["hardware_measured"])
        self.assertFalse(data["calibration_applied"])
        with (first / "原始采样.csv").open(encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f))
        self.assertEqual(rows[0]["raw_a"], "")
        self.assertIn("模拟", (first / "中文结论.txt").read_text(encoding="utf-8-sig"))

    def test_cli_simulation_never_calls_real_serial_or_enumerator(self):
        args = cli.parser().parse_args(["--cli", "--simulate", "--samples", "3", "--output", str(self.output)])
        forbidden = Mock(side_effect=AssertionError("real hardware accessed"))
        with patch.object(tc, "open_serial", forbidden), patch.object(tc, "list_ports", forbidden):
            code, _, conclusion = cli.run_stages(args, emit=lambda s: None)
        self.assertEqual(code, 0)
        self.assertFalse(conclusion["hardware_passed"])
        forbidden.assert_not_called()

    def test_cli_real_requires_explicit_port(self):
        args = cli.parser().parse_args(["--cli", "--output", str(self.output)])
        factory = Mock()
        with self.assertRaises(ValueError):
            cli.run_stages(args, factory=factory)
        factory.assert_not_called()

    def test_cli_disconnect_keeps_partial_evidence_and_nonzero_exit(self):
        args = cli.parser().parse_args(["--cli", "--simulate", "--fault", "disconnect", "--output", str(self.output)])
        code, path, conclusion = cli.run_stages(args, emit=lambda s: None)
        self.assertEqual(code, 2)
        self.assertFalse(conclusion["criteria_passed"])
        data = json.loads((path / "诊断报告.json").read_text(encoding="utf-8"))
        self.assertGreater(len(data["samples"]), 0)
        self.assertTrue(any(e["kind"] == "error" for e in data["events"]))

    def test_selftest_all_positive_negative_cases_are_verified(self):
        args = cli.parser().parse_args(["--self-test", "--output", str(self.output)])
        self.assertEqual(cli.self_test(args, emit=lambda s: None), 0)
        report = next(self.output.rglob("模拟自测总报告.json"))
        data = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(len(data["cases"]), 14)
        self.assertTrue(data["all_verified"])

    def test_import_help_and_simulation_without_serial_or_development_paths(self):
        script = ("import sys; sys.path.insert(0, sys.argv[1]); sys.modules['serial']=None; "
                  "from peripheral_testbench.cli import main; "
                  "raise SystemExit(main(['--simulate','--cli','--samples','3','--output',sys.argv[2]]))")
        process = subprocess.run([sys.executable, "-B", "-S", "-c", script,
                                  str(PROJECT / "tools"), str(self.output)], capture_output=True, timeout=15)
        self.assertEqual(process.returncode, 0, process.stderr.decode(errors="replace"))

    def test_enumeration_does_not_open_port(self):
        factory = Mock()
        with patch.object(tc, "list_ports", return_value=[]), patch.object(tc, "open_serial", factory):
            self.assertEqual(cli.main(["--list-ports"]), 0)
        factory.assert_not_called()


class CalibrationTests(FileCase):
    def test_apply_only_from_explicit_argument(self):
        default = calibration.calibration_arguments("COM7", self.output / "new")
        explicit = calibration.calibration_arguments("COM7", self.output / "new", apply=True)
        self.assertNotIn("--apply", default)
        self.assertIn("--apply", explicit)
        self.assertEqual(default[:3], ["calibrate", "--port", "COM7"])

    def test_bridge_invokes_bundled_calibrator_without_auto_apply(self):
        with patch.object(tc, "run_command", return_value=0) as run:
            calibration.run_calibration("COM7", self.output / "new", prompt=lambda s: "")
        self.assertFalse(run.call_args.args[0].apply)
        with patch.object(tc, "run_command", return_value=0) as run:
            calibration.run_calibration("COM7", self.output / "new", apply=True)
        self.assertTrue(run.call_args.args[0].apply)

    def test_cancel_refuses_any_further_send(self):
        peer = Mock()
        cancelled = threading.Event()
        serial = calibration.CancellableSerial(peer, cancelled)
        serial.timeout = 0.1
        self.assertEqual(peer.timeout, 0.1)
        cancelled.set()
        with self.assertRaises(OSError):
            serial.write(tc.encode_request(0))
        peer.write.assert_not_called()

    def test_all_16_acknowledged_and_released_query_required(self):
        clock = Clock()
        def answer(p):
            if p[3] == 0x81:
                index, value = p[4], int.from_bytes(p[7:9], "little")
                return wire(p[2], flags=(index << 12) | value, sample_seq=0xA100 | index)
            return wire(p[2])
        peer = Peer(clock, answer)
        client = tc.DiagnosticClient(peer, 0.1, clock=clock.monotonic, sleep=clock.sleep)
        windows = [tc.SampleWindow(100 + 150*i, 100 + 150*i, 100 + 150*i, 3) for i in range(16)]
        result = tc.apply_centers(client, windows, tc.SampleWindow(0, 0, 0, 3), tc.Policy(samples=3), sleep=clock.sleep)
        self.assertEqual(result["writes_confirmed"], 16)
        self.assertTrue(result["query_confirmed"])
        self.assertEqual(peer.packets[-1][3], 0x80)

    def test_lost_write_ack_not_retried_or_claimed_success(self):
        clock = Clock()
        def answer(p):
            if p[3] == 0x81:
                if p[4] == 2:
                    return b""
                return wire(p[2], flags=(p[4] << 12) | int.from_bytes(p[7:9], "little"), sample_seq=0xA100 | p[4])
            return wire(p[2])
        peer = Peer(clock, answer)
        client = tc.DiagnosticClient(peer, 0.05, clock=clock.monotonic, sleep=clock.sleep)
        windows = [tc.SampleWindow(100 + 150*i, 100 + 150*i, 100 + 150*i, 3) for i in range(16)]
        with self.assertRaisesRegex(tc.ApplyError, "仅确认2/16"):
            tc.apply_centers(client, windows, tc.SampleWindow(0, 0, 0, 3), tc.Policy(samples=3), sleep=clock.sleep)
        self.assertEqual([p[4] for p in peer.packets if p[3] == 0x81], [0, 1, 2])


class GuiTests(FileCase):
    def setUp(self):
        super().setUp()
        import tkinter as tk
        from peripheral_testbench.gui import TestbenchApp
        self.root = tk.Tk()
        self.root.withdraw()
        args = cli.parser().parse_args(["--simulate", "--samples", "3", "--interval", "0.02", "--timeout", "0.05",
                                       "--output", str(self.output)])
        self.forbidden = Mock(side_effect=AssertionError("real serial access"))
        self.app = TestbenchApp(self.root, args, enumerate_fn=self.forbidden, factory=self.forbidden)

    def tearDown(self):
        if self.root.winfo_exists():
            self.app.close()
            deadline = time.monotonic() + 2
            while self.app.worker is not None and time.monotonic() < deadline:
                self.root.update()
                time.sleep(0.01)
            try:
                self.root.destroy()
            except Exception:
                pass

    def pump_until(self, condition):
        deadline = time.monotonic() + 3
        while not condition() and time.monotonic() < deadline:
            self.root.update()
            time.sleep(0.005)
        self.assertTrue(condition(), self.app.status.get())

    def test_gui_simulation_stages_stop_and_no_hardware(self):
        self.app.connect()
        self.pump_until(lambda: self.app.last_frame is not None)
        for expected in range(1, 6):
            self.app.capture()
            self.pump_until(lambda: len(self.app.test.results) == expected)
        self.assertTrue(self.app.test.conclusion(simulated=True)["criteria_passed"], self.app.test.results)
        self.assertIn("不可用", self.app.live["levels"].get())
        self.assertEqual(str(self.app.cal_apply_button["state"]), "disabled")
        self.app.stop()
        self.assertIsNone(self.app.last_frame)
        self.pump_until(lambda: self.app.worker is None)
        self.assertIn("1秒", self.app.status.get())
        self.forbidden.assert_not_called()

    def test_gui_rejects_preclick_queued_samples(self):
        self.app.capture()  # disconnected click cannot start
        self.assertFalse(self.app.test.active)
        self.app.connect()
        self.pump_until(lambda: self.app.last_frame is not None)
        self.app.capture()
        self.app._sample(sample(seq=10, sample_seq=10), self.app.stage_after - 1)
        self.assertEqual(self.app.test.pending, [])

    def test_gui_timeout_clears_and_allows_reconnect(self):
        self.app.args.fault = "timeout"
        self.app.connect()
        self.pump_until(lambda: self.app.worker is None)
        self.assertIn("通信失败", self.app.status.get())
        self.assertIsNone(self.app.last_frame)
        self.assertFalse(self.app.test.conclusion(simulated=True)["criteria_passed"])
        self.app.args.fault = "none"
        self.app.connect()
        self.pump_until(lambda: self.app.last_frame is not None)
        self.assertIn("通信有效", self.app.status.get())

    def test_pause_keeps_serial_open_and_sends_nothing_until_explicit_resume(self):
        self.app.connect()
        self.pump_until(lambda: self.app.last_frame is not None)
        self.app.pause_polling()
        self.pump_until(lambda: self.app.pause_confirmed)
        sent = len(self.app.peer.requests)
        deadline = time.monotonic() + 1.1
        while time.monotonic() < deadline:
            self.root.update()
            time.sleep(0.005)
        self.assertEqual(len(self.app.peer.requests), sent)
        self.assertFalse(self.app.peer.closed)
        self.assertIsNone(self.app.last_frame)
        self.assertIn("1秒已到", self.app.status.get())
        self.assertEqual(str(self.app.capture_button["state"]), "disabled")
        self.app.pause_polling()
        self.pump_until(lambda: self.app.last_frame is not None)
        self.assertGreater(len(self.app.peer.requests), sent)
        self.assertTrue(any(e["kind"] == "poll_paused" for e in self.app.evidence.events))

    def test_beam_gui_guidance_with_new_raw_capability(self):
        from peripheral_testbench.gui import TestbenchApp
        self.root.after_cancel(self.app.timer)
        self.app.args.tool = "beam"
        self.app.args.raw_capability = True
        for child in self.root.winfo_children():
            child.destroy()
        self.app = TestbenchApp(self.root, self.app.args, factory=self.forbidden, enumerate_fn=self.forbidden)
        self.app.connect()
        self.pump_until(lambda: self.app.last_frame is not None)
        for expected in range(1, 8):
            self.app.capture()
            self.pump_until(lambda: len(self.app.test.results) == expected)
        self.assertTrue(self.app.test.conclusion()["criteria_passed"], self.app.test.results)
        self.assertIn("bit11=1", self.app.live["levels"].get())
        self.assertIsNone(self.app.cal_apply_button)

    def test_calibration_gui_prompt_and_explicit_apply_gate(self):
        self.app.mode.set(False)
        self.app._mode_changed()
        self.app.port.set("MOCK")
        def fake_run(port, output, *, apply, prompt, emit, **kwargs):
            prompt("松开全部触摸键，按 Enter")
            return 0
        for apply in (False, True):
            with patch("peripheral_testbench.gui.run_calibration", side_effect=fake_run) as run, \
                 patch("peripheral_testbench.gui.messagebox.askokcancel", return_value=True) as confirm:
                self.app.calibrate(apply)
                self.pump_until(lambda: self.app.prompt_request is not None)
                self.app.confirm_prompt()
                self.pump_until(lambda: self.app.worker is None)
            self.assertEqual(run.call_args.kwargs["apply"], apply)
            self.assertEqual(confirm.call_count, int(apply))
        self.forbidden.assert_not_called()

    def test_calibration_apply_cancelled_confirmation_never_runs(self):
        self.app.mode.set(False)
        self.app._mode_changed()
        self.app.port.set("MOCK")
        with patch("peripheral_testbench.gui.run_calibration") as run, \
             patch("peripheral_testbench.gui.messagebox.askokcancel", return_value=False):
            self.app.calibrate(True)
        run.assert_not_called()
        self.assertIsNone(self.app.worker)


if __name__ == "__main__":
    unittest.main()
