"""Offline wire-peer tests. No pyserial installation or device is needed.

The peer decodes byte offsets itself; it never calls production frame helpers.
Golden wire vectors also pin down field order independently of the peer.
"""
import functools
import json
import operator
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import touch_calibrate as tc


def wire_reply(seq, *, raw=0, touch_keys=0, keys=0, diag2=0, diag3=1, status=0, version=9):
    fields = [0x5A, 0xA5, version, seq, status]
    for word in (keys, raw, touch_keys, diag2, diag3):
        fields.extend((word & 255, word >> 8))
    fields.append(functools.reduce(operator.xor, fields[2:], 0))
    return bytes(fields)


class Clock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, duration):
        self.now += duration


class WirePeer:
    """A small byte-stream peer with its own strict request acceptance rules."""
    def __init__(self, clock, *, raw_values=(), chunk=256, write_chunk=16, transform=None):
        self.clock = clock
        self.raw_values = iter(raw_values)
        self.chunk, self.write_chunk, self.transform = chunk, write_chunk, transform
        self.incoming, self.outgoing = bytearray(), bytearray()
        self.packets, self.centers = [], {}
        self.timeout, self.write_timeout = 0.01, 0.2
        self.closed, self.query_count = False, 0

    def write(self, data):
        count = min(self.write_chunk, len(data))
        if not count:
            return 0
        self.incoming.extend(data[:count])
        while len(self.incoming) >= 16:
            packet = bytes(self.incoming[:16])
            del self.incoming[:16]
            assert packet[:2] == b"\xa5\x5a"
            assert functools.reduce(operator.xor, packet[2:], 0) == 0
            assert packet[3] in (0x80, 0x81)
            seq = packet[2]
            self.packets.append(packet)
            if packet[3] == 0x80:
                assert packet[4:15] == b"\0" * 11
                self.query_count += 1
                raw = next(self.raw_values, 0)
                response = wire_reply(seq, raw=raw, diag3=self.query_count & 0xFFFF)
            else:
                index, value = packet[4], packet[7] + 256 * packet[8]
                assert 0 <= index < 16 and 8 <= value <= 4094
                assert packet[5:7] == b"\0\0" and packet[9:15] == b"\0" * 6
                self.centers[index] = value
                response = wire_reply(seq, diag2=index * 4096 + value, diag3=0xA100 + index)
            if self.transform:
                response = self.transform(packet, response)
            self.outgoing.extend(response)
        return count

    def read(self, count):
        if not self.outgoing:
            self.clock.sleep(self.timeout)
            return b""
        count = min(count, self.chunk)
        result = bytes(self.outgoing[:count])
        del self.outgoing[:count]
        return result

    def close(self):
        self.closed = True


def windows(centers=None, span=0):
    centers = list(centers) if centers is not None else [100 + 180 * i for i in range(16)]
    return [tc.SampleWindow(c, c, c + span, 3) for c in centers]


def calibration_samples(centers=None):
    result = []
    for item in windows(centers):
        result.extend([0, 1, 0, item.center, item.center, item.center])
    return result


class ProtocolTests(unittest.TestCase):
    def test_literal_request_vectors(self):
        self.assertEqual(tc.encode_request(0x12).hex(), "a55a1280000000000000000000000092")
        self.assertEqual(tc.encode_request(0x34, 11, 0x789).hex(), "a55a34810b0000890700000000000030")

    def test_literal_response_layout(self):
        reply = tc.parse_diagnostic(bytes.fromhex("5aa50912a034125604800089b70ba1db"))
        self.assertEqual((reply.seq, reply.status, reply.keys), (0x12, 0xA0, 0x1234))
        self.assertEqual((reply.touch_raw, reply.touch_keys, reply.diag2, reply.diag3),
                         (0x456, 0x80, 0xB789, 0xA10B))

    def test_request_bounds_and_zero_payload(self):
        for args in ((-1,), (256,), (True,), (0, -1, 100), (0, 16, 100), (0, 0, 7),
                     (0, 0, 4095), (0, None, 100), (0, 0, True), (0, 0, None)):
            with self.subTest(args=args), self.assertRaises(ValueError):
                tc.encode_request(*args)
        for index, value in ((0, 8), (15, 4094)):
            packet = tc.encode_request(255, index, value)
            self.assertEqual(packet[4] & 0xF0, 0)
            self.assertEqual(packet[5:7] + packet[9:15], b"\0" * 8)

    def test_reject_version_xor_length_and_raw(self):
        good = wire_reply(0)
        bad_xor = good[:-1] + bytes([good[-1] ^ 1])
        for data in (wire_reply(0, version=8), wire_reply(0, version=10), bad_xor,
                     good[:15], good + b"x", wire_reply(0, raw=4096), b"xx" + good[2:]):
            with self.subTest(data=data.hex()), self.assertRaises(tc.ProtocolError):
                tc.parse_diagnostic(data)

    def test_stream_fragmentation_corruption_embedded_header_and_noise(self):
        stream = tc.DiagnosticStream()
        bad = bytearray(wire_reply(1))
        bad[-1] ^= 1
        data = b"noise\x5a" + bytes(bad) + wire_reply(2, version=8) + wire_reply(3) + wire_reply(4)
        replies = []
        for byte in data:
            replies.extend(stream.feed(bytes([byte])))
        self.assertEqual([r.seq for r in replies], [3, 4])
        self.assertGreaterEqual(stream.bad_frames, 2)
        stream.feed(b"x" * 10000 + b"\x5a")
        self.assertEqual(stream.buffer, b"\x5a")
        self.assertEqual(stream.feed(wire_reply(5)[1:])[0].seq, 5)
        # Invalid candidate contains the beginning of the next valid packet.
        self.assertEqual(stream.feed(b"\x5a\xa5\x09\x01" + wire_reply(6))[0].seq, 6)


class TransactionTests(unittest.TestCase):
    def client(self, **kwargs):
        clock = Clock()
        peer = WirePeer(clock, **kwargs)
        client = tc.DiagnosticClient(peer, 0.2, clock=clock.monotonic, sleep=clock.sleep)
        return client, peer, clock

    def test_complete_query_and_write_with_partial_reads_and_writes(self):
        client, peer, _ = self.client(raw_values=[1234], chunk=1, write_chunk=3)
        self.assertEqual(client.query().touch_raw, 1234)
        result = client.write_center(15, 4094)
        self.assertEqual((result.diag2, result.diag3), (0xFFFE, 0xA10F))
        self.assertEqual(peer.centers, {15: 4094})
        self.assertEqual([p[3] for p in peer.packets], [0x80, 0x81])

    def test_wrong_seq_bad_xor_old_ack_then_good_reply(self):
        def transform(packet, response):
            bad = response[:-1] + bytes([response[-1] ^ 1])
            return wire_reply(99) + bad + wire_reply(packet[2], version=8) + response
        client, _, _ = self.client(transform=transform, chunk=3)
        self.assertEqual(client.query().seq, 0)
        self.assertEqual(client.ignored_seq, 1)
        self.assertGreaterEqual(client.stream.bad_frames, 2)

    def test_timeout_for_silence_wrong_seq_and_old_version_never_success(self):
        for transform in (lambda p, r: b"", lambda p, r: wire_reply((p[2] + 1) & 255),
                          lambda p, r: wire_reply(p[2], version=8),
                          lambda p, r: r[:-1] + bytes([r[-1] ^ 1])):
            client, _, clock = self.client(transform=transform)
            with self.assertRaises(tc.DiagnosticTimeout):
                client.query()
            self.assertLessEqual(clock.now, 0.205)

    def test_write_ack_index_value_marker_each_verified(self):
        for overrides in ({"diag2": 0x2064, "diag3": 0xA101},
                          {"diag2": 0x1065, "diag3": 0xA101},
                          {"diag2": 0x1064, "diag3": 0xA100}):
            client, peer, _ = self.client(transform=lambda p, r: wire_reply(p[2], **overrides))
            with self.assertRaises(tc.ProtocolError):
                client.write_center(1, 100)
            self.assertEqual(len(peer.packets), 1)  # Never retry a possibly accepted write.

    def test_no_write_progress_and_seq_wrap(self):
        client, peer, _ = self.client(write_chunk=0)
        with self.assertRaises(OSError):
            client.query()
        self.assertEqual(peer.packets, [])
        client, peer, _ = self.client()
        client.seq = 255
        self.assertEqual([client.query().seq, client.query().seq], [255, 0])


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.policy = tc.Policy(samples=3, settle=0, interval=0.001)

    def test_valid_edges_and_exact_twelve_gap_with_adaptive_windows(self):
        table = windows([8 + 12 * i for i in range(15)] + [4094], span=0)
        tc.validate_centers(table, self.policy)
        self.assertEqual(tc.dynamic_tolerances(table)[:15], [3] * 15)
        self.assertEqual(tc.dynamic_tolerances(table)[-1], 32)
        table[0] = tc.SampleWindow(8, 7, 8, 3)
        tc.validate_centers(table, self.policy)

    def test_reject_incomplete_rails_close_and_attenuated_table(self):
        cases = [windows()[:15], windows([7] + [100 + i * 100 for i in range(15)]),
                 windows([4095] + [100 + i * 100 for i in range(15)]),
                 windows([100, 111] + [300 + i * 100 for i in range(14)]),
                 windows([8 + 6 * i for i in range(16)])]
        for table in cases:
            with self.subTest(table=table), self.assertRaises(tc.CalibrationError):
                tc.validate_centers(table, self.policy)

    def test_reject_noise_relative_to_gap_even_below_global_limit(self):
        table = windows([100 + 12 * i for i in range(16)], span=2)
        with self.assertRaisesRegex(tc.CalibrationError, "波动过大"):
            tc.validate_centers(table, self.policy)
        tc.validate_centers(windows([100 + 12 * i for i in range(16)], span=1), self.policy)
        with self.assertRaises(tc.CalibrationError):
            tc.summarize([100, 150, 100], self.policy)

    def test_complete_manual_rowmajor_collection_has_no_writes(self):
        clock = Clock()
        peer = WirePeer(clock, raw_values=calibration_samples())
        client = tc.DiagnosticClient(peer, clock=clock.monotonic, sleep=clock.sleep)
        prompts = []
        table, release = tc.collect_calibration(client, self.policy, prompt=prompts.append,
                                                emit=lambda text: None, sleep=clock.sleep)
        self.assertEqual([w.center for w in table], [100 + 180 * i for i in range(16)])
        self.assertEqual(len(release), 16)
        self.assertEqual(len(prompts), 32)
        self.assertIn("第2行第4列 / B / index=7", prompts[14])
        self.assertIn("第3行第4列 / C / index=11", prompts[22])
        self.assertTrue(all(p[3] == 0x80 for p in peer.packets))

    def test_no_press_no_idle_noise_and_early_cancellation_never_write(self):
        for values in ([0] * 6, [4] * 3, [0, 1, 0, 100, 200, 100]):
            clock = Clock()
            peer = WirePeer(clock, raw_values=values)
            client = tc.DiagnosticClient(peer, clock=clock.monotonic, sleep=clock.sleep)
            with self.assertRaises(tc.CalibrationError):
                tc.collect_calibration(client, self.policy, prompt=lambda s: None,
                                       emit=lambda s: None, sleep=clock.sleep)
            self.assertEqual(peer.centers, {})
        client = Mock()
        with self.assertRaises(KeyboardInterrupt):
            tc.collect_calibration(client, self.policy, prompt=Mock(side_effect=KeyboardInterrupt), sleep=lambda s: None)
        client.write_center.assert_not_called()

    def test_apply_all_sixteen_receipts_then_separate_query(self):
        clock = Clock()
        peer = WirePeer(clock, chunk=2)
        client = tc.DiagnosticClient(peer, clock=clock.monotonic, sleep=clock.sleep)
        progress = []
        result = tc.apply_centers(client, windows(), tc.SampleWindow(0, 0, 1, 3), self.policy,
                                  sleep=clock.sleep, progress=lambda r: progress.append(len(r)))
        self.assertEqual(result["writes_confirmed"], 16)
        self.assertTrue(result["query_confirmed"])
        self.assertEqual(progress, list(range(1, 17)))
        self.assertEqual(peer.centers, dict(enumerate(100 + 180 * i for i in range(16))))
        self.assertEqual(peer.packets[-1][3], 0x80)
        self.assertEqual(sum(p[3] == 0x81 for p in peer.packets), 16)

    def test_apply_guard_holds_released_by_raw_and_keys(self):
        for params in ({"raw": 4}, {"touch_keys": 1}):
            clock = Clock()
            peer = WirePeer(clock, transform=lambda p, r: wire_reply(p[2], **params))
            client = tc.DiagnosticClient(peer, clock=clock.monotonic, sleep=clock.sleep)
            with self.assertRaises(tc.ApplyError):
                tc.apply_centers(client, windows(), tc.SampleWindow(0, 0, 0, 3), self.policy, sleep=clock.sleep)
            self.assertEqual(peer.centers, {})

    def test_uncertain_write_stops_without_false_success_or_retry(self):
        def transform(packet, response):
            return b"" if packet[3] == 0x81 and packet[4] == 5 else response
        clock = Clock()
        peer = WirePeer(clock, transform=transform)
        client = tc.DiagnosticClient(peer, 0.1, clock=clock.monotonic, sleep=clock.sleep)
        with self.assertRaisesRegex(tc.ApplyError, "仅确认5/16"):
            tc.apply_centers(client, windows(), tc.SampleWindow(0, 0, 0, 3), self.policy, sleep=clock.sleep)
        self.assertEqual(set(peer.centers), set(range(6)))  # Device accepted #5; receipt was lost.


class CommandTests(unittest.TestCase):
    def run_args(self, argv, peer, clock, **kwargs):
        return tc.run_command(tc.parser().parse_args(argv), serial_factory=lambda p, t: peer,
                              clock=clock.monotonic, sleep=clock.sleep, emit=lambda s: None, **kwargs)

    def test_no_args_defaults_to_monitor_and_config_port_is_read_only(self):
        args = tc.parser().parse_args([])
        self.assertIsNone(args.command)
        clock, calls = Clock(), []
        peer = WirePeer(clock)
        with tempfile.TemporaryDirectory() as root:
            config = Path(root, "config.json")
            config.write_text('{"port":"COM77"}', encoding="utf-8")
            args = tc.parser().parse_args(["--config", str(config), "monitor", "--count", "2"])
            factory = lambda p, t: (calls.append((p, t)) or peer)
            self.assertEqual(tc.run_command(args, serial_factory=factory, clock=clock.monotonic,
                                           sleep=clock.sleep, emit=lambda s: None), 0)
            self.assertEqual(calls[0][0], "COM77")
            self.assertEqual(config.read_text(), '{"port":"COM77"}')
        self.assertTrue(peer.closed)
        self.assertEqual([p[3] for p in peer.packets], [0x80, 0x80])

    def test_list_does_not_open_port_and_port_can_precede_or_follow_command(self):
        factory = Mock()
        self.assertEqual(tc.run_command(tc.parser().parse_args(["--list"]), serial_factory=factory,
                                       enumerate_fn=lambda: [], emit=lambda s: None), 0)
        factory.assert_not_called()
        for argv in (["--port", "COM42", "monitor"], ["monitor", "--port", "COM42"]):
            self.assertEqual(tc.parser().parse_args(argv).port, "COM42")

    def test_save_only_exports_hex_without_apply_and_refuses_existing_output(self):
        clock = Clock()
        peer = WirePeer(clock, raw_values=calibration_samples())
        with tempfile.TemporaryDirectory() as root:
            output = Path(root, "capture")
            code = self.run_args(["calibrate", "--port", "COM8", "--output-dir", str(output),
                                  "--samples", "3", "--settle", "0"], peer, clock, prompt=lambda s: None)
            self.assertEqual(code, 0)
            report = json.loads((output / "touch_calibration.json").read_text(encoding="utf-8"))
            self.assertEqual(report["apply"]["status"], "not_requested")
            self.assertFalse(report["firmware_programmed"])
            self.assertEqual([int(x, 16) for x in (output / "touch_centers.hex").read_text().splitlines()],
                             report["centers"])
            before = (output / "touch_centers.hex").read_bytes()
            with self.assertRaises(FileExistsError):
                self.run_args(["calibrate", "--port", "COM8", "--output-dir", str(output)], peer, clock)
            self.assertEqual((output / "touch_centers.hex").read_bytes(), before)
        self.assertEqual(peer.centers, {})
        self.assertTrue(peer.closed)

    def test_full_command_apply_roundtrip_and_failure_is_recorded(self):
        for fail in (False, True):
            def transform(packet, response):
                if fail and packet[3] == 0x81 and packet[4] == 3:
                    return wire_reply(packet[2], diag2=0, diag3=0)
                return response
            clock = Clock()
            peer = WirePeer(clock, raw_values=calibration_samples(), transform=transform, chunk=3)
            with tempfile.TemporaryDirectory() as root:
                output = Path(root, "capture")
                argv = ["calibrate", "--port", "COM8", "--output-dir", str(output),
                        "--samples", "3", "--settle", "0", "--apply"]
                if fail:
                    with self.assertRaises(tc.ApplyError):
                        self.run_args(argv, peer, clock, prompt=lambda s: None)
                else:
                    self.assertEqual(self.run_args(argv, peer, clock, prompt=lambda s: None), 0)
                report = json.loads((output / "touch_calibration.json").read_text(encoding="utf-8"))
                self.assertEqual(report["apply"]["status"], "unconfirmed" if fail else "confirmed")
                self.assertEqual(report["apply"]["writes_confirmed"], 3 if fail else 16)
                self.assertEqual(report["apply"]["query_confirmed"], not fail)
            self.assertTrue(peer.closed)

    def test_saved_json_is_accepted_by_driver_generator_and_hex_matches_exactly(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root, "capture")
            tc.save_calibration(output, windows(), [tc.SampleWindow(0, 0, 0, 3)] * 16, tc.Policy())
            regenerated = Path(root, "regenerated.hex")
            result = subprocess.run([sys.executable, "-B", "-S", str(tc.ROOT / "scripts" / "generate_touch_centers.py"),
                                     "--calibration", str(output / "touch_calibration.json"),
                                     "--output", str(regenerated)], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertEqual(regenerated.read_bytes(), (output / "touch_centers.hex").read_bytes())
            self.assertEqual(len(regenerated.read_text().splitlines()), 16)

    def test_all_writes_acknowledged_but_final_query_lost_is_unconfirmed(self):
        clock = Clock()
        peer = WirePeer(clock, raw_values=calibration_samples())
        peer.transform = lambda p, r: b"" if p[3] == 0x80 and len(peer.centers) == 16 else r
        with tempfile.TemporaryDirectory() as root:
            output = Path(root, "capture")
            with self.assertRaisesRegex(tc.ApplyError, "仅确认16/16"):
                self.run_args(["calibrate", "--port", "COM8", "--output-dir", str(output),
                               "--samples", "3", "--settle", "0", "--timeout", "0.1", "--apply"],
                              peer, clock, prompt=lambda s: None)
            report = json.loads((output / "touch_calibration.json").read_text(encoding="utf-8"))
            self.assertEqual(report["apply"]["status"], "unconfirmed")
            self.assertEqual(report["apply"]["writes_confirmed"], 16)
            self.assertFalse(report["apply"]["query_confirmed"])
        self.assertTrue(peer.closed)

    def test_partial_capture_never_exports_or_writes_and_closes(self):
        clock = Clock()
        peer = WirePeer(clock, raw_values=calibration_samples()[:6] + [4] * 3)
        with tempfile.TemporaryDirectory() as root:
            output = Path(root, "capture")
            with self.assertRaises(tc.CalibrationError):
                self.run_args(["calibrate", "--port", "COM8", "--output-dir", str(output),
                               "--samples", "3", "--settle", "0", "--apply"], peer, clock, prompt=lambda s: None)
            self.assertFalse(output.exists())
        self.assertEqual(peer.centers, {})
        self.assertTrue(peer.closed)

    def test_import_help_and_unit_do_not_require_serial(self):
        code = ("import sys; sys.path.insert(0, sys.argv[1]); sys.modules['serial']=None; "
                "import touch_calibrate as t; assert len(t.encode_request(0))==16; t.main(['--help'])")
        process = subprocess.run([sys.executable, "-B", "-S", "-c", code, str(tc.ROOT / "tools")],
                                 capture_output=True, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr.decode(errors="replace"))


if __name__ == "__main__":
    unittest.main()
