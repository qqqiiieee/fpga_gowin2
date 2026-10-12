"""Offline tests only: no real serial, audio, capture or programming calls."""
from datetime import datetime, timedelta, timezone
import ctypes
import json
import math
from pathlib import Path
import struct
import unittest
from unittest.mock import Mock, patch

import remote_control as rc


DEVICE = dict(port='COM8', instance_id=r'FTDIBUS\VID_0403+PID_6010+FACTORYAIOT_PRO&2\0000',
              service='FTDIPORT', present_started=True, name='USB Serial Port (COM8)')


def ack_bytes(seq, flags=0, keys=0, adc=(0, 0, 0, 0), version=8):
    body = struct.pack('<2sBBBH4H', b'\x5a\xa5', version, seq, flags, keys, *adc)
    check = 0
    for value in body[2:15]:
        check ^= value
    return body + bytes([check])


class FakeClock:
    def __init__(self):
        self.now = 0.

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(0., seconds)

    def wall(self):
        return (datetime(2026, 10, 12, tzinfo=timezone.utc) + timedelta(seconds=self.now)).isoformat()


class FakeSerial:
    def __init__(self, clock, reply=None, chunk=256):
        self.clock, self.reply, self.chunk = clock, reply, chunk
        self.received, self.writes = bytearray(), []
        self.closed = False

    def write(self, packet):
        self.writes.append((self.clock.now, packet))
        _, seq, flags, keys, velocity, *adc = struct.unpack('<2sBBHB4H', packet[:15])
        data = (self.reply(len(self.writes), seq, flags, keys, adc) if self.reply
                else ack_bytes(seq, flags, keys, adc))
        if data is not None:
            self.received.extend(data)

    def read(self, count, timeout):
        if not self.received:
            self.clock.sleep(timeout)
            return b''
        count = min(count, self.chunk)
        data = bytes(self.received[:count])
        del self.received[:count]
        return data

    def close(self):
        self.closed = True


class ProtocolTests(unittest.TestCase):
    def test_current_installed_ftser2k_driver_is_recognized(self):
        self.assertTrue(rc.verified_ftdi(DEVICE | {'service': 'FTSER2K'}))
        self.assertFalse(rc.verified_ftdi(DEVICE | {'service': 'FTSER2K', 'present_started': False}))
        self.assertFalse(rc.verified_ftdi(DEVICE | {'service': 'unknown_driver'}))

    def test_golden_input_layout_and_xor(self):
        self.assertEqual(rc.encode_packet(0x12, 7, 0x8005, 201, (1234, 26400, 0, 1)).hex(),
                         'a55a12070580c9d204206700000100c9')
        self.assertEqual(len(rc.encode_packet(255)), 16)

    def test_input_bounds(self):
        for kwargs in ({'seq': -1}, {'seq': 256}, {'seq': True}, {'flags': 8},
                       {'keys': 65536}, {'velocity': -1}, {'adc': (0, 0, 0, 26401)},
                       {'adc': (-1, 0, 0, 0)}, {'adc': (0, 0, 0)}, {'adc': (0., 0, 0, 0)}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                rc.encode_packet(**({'seq': 0} | kwargs))

    def test_slider_mapping_and_bounds(self):
        self.assertEqual([rc.slider_adc(x) for x in (0, 128, 255)], [0, 13252, 26400])
        for value in (-1, 256, math.nan, True):
            with self.assertRaises(ValueError):
                rc.slider_adc(value)

    def test_ack_status_bits_and_echo(self):
        ack = rc.parse_ack(ack_bytes(255, 0xff, 0x8001, (0, 6000, 26400, 13252)))
        self.assertEqual((ack['version'], ack['seq'], ack['keys']), (8, 255, 0x8001))
        self.assertEqual(ack['adc'], [0, 6000, 26400, 13252])
        self.assertEqual(ack['device_status'], 0xf8)
        self.assertTrue(all(ack[name] for name in rc.STATUS_BITS.values()))

    def test_ack_rejects_bad_version_length_crc_and_adc(self):
        good = ack_bytes(2)
        for packet in (good[:-1], good + b'x', b'xx' + good[2:], ack_bytes(2, version=9),
                       good[:-1] + bytes([good[-1] ^ 1]), ack_bytes(2, flags=1, adc=(26401, 0, 0, 0))):
            with self.subTest(packet=packet.hex()), self.assertRaises(ValueError):
                rc.parse_ack(packet)

    def test_inactive_adc_retains_unsigned_physical_codes(self):
        raw = (65535, 32768, 26401, 65534)
        ack = rc.parse_ack(ack_bytes(1, flags=0x18, keys=0x8000, adc=raw))
        self.assertEqual(ack['adc'], list(raw))
        self.assertFalse(ack['active'])
        with self.assertRaises(ValueError):
            rc.parse_ack(ack_bytes(1, flags=1, adc=raw))

    def test_stream_noise_corruption_fragmentation_and_resync(self):
        stream = rc.AckStream()
        damaged = bytearray(ack_bytes(1))
        damaged[-1] ^= 1
        good = ack_bytes(2)
        self.assertEqual(stream.feed(b'noise' + bytes(damaged) + good[:7]), [])
        frames = stream.feed(good[7:])
        self.assertEqual([ack['seq'] for _, ack in frames], [2])
        self.assertGreaterEqual(stream.bad_frames, 1)
        self.assertEqual(stream.feed(ack_bytes(3) + ack_bytes(4))[-1][1]['seq'], 4)

    def test_partial_timeout_retains_only_possible_header(self):
        stream = rc.AckStream()
        stream.feed(ack_bytes(1)[:8])
        stream.discard_partial()
        self.assertEqual(stream.buffer, b'')
        stream.feed(b'garbage\x5a')
        self.assertEqual(stream.feed(ack_bytes(2)[1:])[0][1]['seq'], 2)

    def test_key_numbers_mask_empty_and_bounds(self):
        self.assertEqual(rc.keys_mask('1,3,16'), 0x8005)
        self.assertEqual(rc.keys_mask(''), 0)
        for text in ('0', '17', '1,', 'foo'):
            with self.assertRaises(ValueError):
                rc.keys_mask(text)


class SessionTests(unittest.TestCase):
    def execute(self, argv, reply=None, chunk=256, device=None, serial=None):
        clock = FakeClock()
        serial = serial or FakeSerial(clock, reply, chunk)
        factory = Mock(return_value=serial)
        result = rc.run_command(rc.parser().parse_args(argv),
                                enumerate_fn=lambda: [DEVICE if device is None else device],
                                serial_factory=factory, clock=clock.monotonic,
                                sleep=clock.sleep, wall=clock.wall)
        return result, serial, clock, factory

    def test_list_never_opens_any_device(self):
        result, serial, _, factory = self.execute(['list'])
        factory.assert_not_called()
        self.assertFalse(serial.closed)
        self.assertTrue(result['devices'][0]['verified_ftdi'])

    def test_play_disabled_first_finally_release_and_keepalive(self):
        result, serial, _, _ = self.execute(['play', '--port', 'COM8', '--keys', '1,3',
                                           '--velocity', '255', '--volume', '128',
                                           '--pitch-position', '128', '--seconds', '.4'], chunk=3)
        self.assertEqual(result['exit_code'], 0)
        self.assertTrue(serial.closed and result['release']['confirmed'])
        packets = [p for _, p in serial.writes]
        self.assertEqual(packets[0], rc.encode_packet(0))
        self.assertEqual(packets[-1][3:15], rc.encode_packet(0)[3:15])
        active = [(t, p) for t, p in serial.writes if p[3] & 1]
        self.assertEqual(len(active), 4)
        for (a, _), (b, _) in zip(active, active[1:]):
            self.assertAlmostEqual(b - a, .1)
        self.assertEqual(active[0][1][4:7], b'\x05\x00\xff')
        self.assertEqual(struct.unpack('<4H', active[0][1][7:15]), (0, 0, 13252, 13252))

    def test_status_waits_30ms_allows_old_keys_and_decodes_stale(self):
        def reply(number, seq, flags, keys, adc):
            return ack_bytes(seq, 0x18, 5 if number == 1 else 2, (123, 0, 0, 0))
        result, serial, _, _ = self.execute(['status', '--port', 'COM8'], reply)
        self.assertEqual(result['exit_code'], 0)
        self.assertEqual(result['handshake']['keys'], 5)
        self.assertEqual(result['echo']['keys'], 2)
        self.assertTrue(result['echo']['effectiveadc_stale'])
        self.assertGreaterEqual(serial.writes[1][0] - serial.writes[0][0], .03)
        self.assertTrue(all(p[3] == 0 for _, p in serial.writes))
        self.assertIn('do not verify finger motion', result['note'])

    def test_handshake_failure_never_enables_and_still_releases(self):
        result, serial, _, _ = self.execute(['play', '--port', 'COM8'],
            lambda number, seq, flags, keys, adc: ack_bytes(seq, version=9 if number == 1 else 8))
        self.assertEqual(result['exit_code'], 1)
        self.assertTrue(all(p[3] == 0 for _, p in serial.writes))
        self.assertTrue(serial.closed and result['release']['confirmed'])

    def test_inactive_echo_not_compared_to_request_zeros(self):
        result, serial, _, _ = self.execute(['status', '--port', 'COM8'],
            lambda n, seq, flags, keys, adc: ack_bytes(seq, 0x18, 0x8000, (65535, 32768, 26401, 65534)))
        self.assertEqual(result['exit_code'], 0)
        self.assertEqual(result['echo']['adc'], [65535, 32768, 26401, 65534])
        self.assertTrue(result['release']['confirmed'] and serial.closed)

    def test_valid_xor_but_wrong_active_keys_or_adc_fails(self):
        for kind in ('keys', 'adc'):
            def reply(n, seq, flags, keys, adc):
                if flags & 1:
                    if kind == 'keys':
                        keys ^= 2
                    else:
                        adc = list(adc)
                        adc[0] = 1
                return ack_bytes(seq, flags, keys, adc)
            result, serial, _, _ = self.execute(['play', '--port', 'COM8'], reply)
            with self.subTest(kind=kind):
                self.assertEqual(result['exit_code'], 1)
                bad = [r for r in result['packets'] if r['request']['flags'] & 1]
                self.assertGreaterEqual(len(bad), 2)
                self.assertTrue(all(r['outcome'] == 'echo_mismatch' for r in bad))
                self.assertTrue(result['release']['confirmed'] and serial.closed)

    def test_wrong_seq_ignored_and_wrong_flags_fail_handshake(self):
        for kind in ('seq', 'flags'):
            def reply(number, seq, flags, keys, adc):
                return ack_bytes((seq + 1) & 255 if number == 1 and kind == 'seq' else seq,
                                 1 if number == 1 and kind == 'flags' else flags)
            result, serial, _, _ = self.execute(['play', '--port', 'COM8'], reply)
            self.assertEqual(result['exit_code'], 1)
            self.assertTrue(all(p[3] == 0 for _, p in serial.writes))

    def test_two_consecutive_failures_stop_while_sending_keepalive(self):
        result, serial, _, _ = self.execute(['play', '--port', 'COM8', '--seconds', '10'],
            lambda n, seq, flags, keys, adc: None if flags & 1 else ack_bytes(seq))
        self.assertEqual(result['exit_code'], 1)
        active = [t for t, p in serial.writes if p[3] & 1]
        self.assertLess(active[-1], .8)
        self.assertTrue(serial.closed and result['release']['confirmed'])

    def test_release_timeout_not_claimed_as_success(self):
        result, serial, _, _ = self.execute(['play', '--port', 'COM8', '--seconds', '.1'],
            lambda n, seq, flags, keys, adc: None if n > 1 and not flags & 1 else ack_bytes(seq, flags, keys, adc))
        self.assertEqual(result['exit_code'], 1)
        self.assertFalse(result['release']['confirmed'])
        self.assertEqual(result['release']['watchdog_expected_seconds'], 1)
        self.assertIn('NOT confirmed', result['release']['note'])
        self.assertTrue(serial.closed)

    def test_primary_write_error_and_release_write_error_both_recorded(self):
        def reply(n, seq, flags, keys, adc):
            if n > 1:
                raise OSError('primary failure' if flags & 1 else 'release failure')
            return ack_bytes(seq)
        result, serial, _, _ = self.execute(['play', '--port', 'COM8'], reply)
        self.assertEqual(result['error'], 'primary failure')
        self.assertEqual(result['release']['error'], 'release failure')
        self.assertFalse(result['release']['confirmed'])
        self.assertTrue(serial.closed)

    def test_keyboard_interrupt_still_sends_disabled_and_closes(self):
        def reply(n, seq, flags, keys, adc):
            if flags & 1:
                raise KeyboardInterrupt()
            return ack_bytes(seq)
        result, serial, _, _ = self.execute(['play', '--port', 'COM8'], reply)
        self.assertEqual(result['exit_code'], 130)
        self.assertTrue(result['release']['confirmed'] and serial.closed)
        self.assertEqual(serial.writes[-1][1][3], 0)

    def test_strike_calibrates_pulses_and_clears_pressure(self):
        result, serial, _, _ = self.execute(['strike', '--port', 'COM8', '--pad', '1'])
        active = [(t, struct.unpack('<4H', p[7:15])) for t, p in serial.writes if p[3] & 1]
        pulse = [(t, adc) for t, adc in active if adc[1] != 0]
        self.assertEqual(len(pulse), 1)
        self.assertGreaterEqual(pulse[0][0], .5)
        self.assertEqual(pulse[0][1], (0, 6000, 26400, 13252))
        self.assertAlmostEqual(result['pressure_pulse_seconds'], .03)
        cleared = next((t, adc) for t, adc in active if t > pulse[0][0])
        self.assertAlmostEqual(cleared[0] - pulse[0][0], .03)
        self.assertEqual(cleared[1][1], 0)

    def test_sweep_endpoints_keys_and_channel_mapping(self):
        for control, index in (('volume', 2), ('pitch', 3)):
            result, serial, _, _ = self.execute(['sweep', '--port', 'COM8', '--control', control,
                                               '--start', '32', '--end', '224', '--seconds', '1'])
            packets = [p for _, p in serial.writes if p[3] & 1]
            values = [struct.unpack('<4H', p[7:15])[index] for p in packets]
            self.assertEqual((values[0], values[-1]), (rc.slider_adc(32), rc.slider_adc(224)))
            self.assertEqual(values, sorted(values))
            self.assertTrue(all(p[4:6] == b'\x01\x00' for p in packets))
            self.assertEqual(result['exit_code'], 0)

    def test_quiet_empty_keys_and_mask(self):
        for selector in (['--keys', ''], ['--mask', '0x8001']):
            result, serial, _, _ = self.execute(['play', '--port', 'COM8', '--zero', '--park-i2c',
                                               '--seconds', '.1'] + selector)
            packet = serial.writes[1][1]
            self.assertEqual(packet[3], 7)
            self.assertEqual(int.from_bytes(packet[4:6], 'little'), 0 if selector[0] == '--keys' else 0x8001)
            self.assertEqual(serial.writes[-1][1][3], 0)

    def test_ten_second_log_bounded_preserves_final_release(self):
        result, serial, clock, _ = self.execute(['play', '--port', 'COM8', '--seconds', '10'])
        self.assertEqual(len(result['packets']), 100)
        self.assertEqual(result['packet_count'], 102)
        self.assertEqual(result['omitted_packets'], 2)
        self.assertEqual(result['packets'][-1]['phase'], 'finally_release')
        self.assertEqual(result['packets'][-1]['outcome'], 'acknowledged')
        self.assertAlmostEqual(serial.writes[-1][0], 10.)
        json.dumps(result)

    def test_json_log_and_explicit_release(self):
        with patch.object(Path, 'write_text') as write:
            path = Path(__file__).parent / 'not-created.json'
            result, serial, _, _ = self.execute(['release', '--port', 'COM8', '--log', str(path)])
            saved = json.loads(write.call_args.args[0])
            self.assertTrue(saved['release']['confirmed'])
            self.assertTrue(saved['packets'][0]['host_timestamp'])
            self.assertTrue(saved['packets'][-1]['response']['host_timestamp'])
            self.assertTrue(all(p[3] == 0 for _, p in serial.writes))

    def test_invalid_inputs_before_enumeration_or_open(self):
        cases = [('play', 'seconds', float('nan')), ('play', 'seconds', 10.1),
                 ('play', 'volume', 256), ('play', 'pitch_position', -1),
                 ('play', 'keys', '17'), ('play', 'mask', 65536),
                 ('strike', 'seconds', .5), ('strike', 'strength', 26401),
                 ('sweep', 'end', 256), ('play', 'port', r'\\.\COM8')]
        for command, field, value in cases:
            argv = [command, '--port', 'COM8']
            if command == 'strike':
                argv += ['--pad', '0']
            if command == 'sweep':
                argv += ['--control', 'volume']
            args = rc.parser().parse_args(argv)
            setattr(args, field, value)
            enumerate_fn, factory = Mock(), Mock()
            with self.subTest(field=field), self.assertRaises(ValueError):
                rc.run_command(args, enumerate_fn=enumerate_fn, serial_factory=factory)
            enumerate_fn.assert_not_called()
            factory.assert_not_called()

    def test_unknown_com0com_bluetooth_and_disconnected_refused(self):
        for change in ({'instance_id': r'ROOT\COM0COM\0000'}, {'name': 'Bluetooth Serial'},
                       {'service': 'com0com'}, {'present_started': False},
                       {'instance_id': r'FTDIBUS\VID_1234+PID_6010+FAKE\0000'}):
            factory = Mock()
            with self.subTest(change=change), self.assertRaises(ValueError):
                rc.run_command(rc.parser().parse_args(['status', '--port', 'COM8']),
                               enumerate_fn=lambda: [DEVICE | change], serial_factory=factory)
            factory.assert_not_called()

    def test_active_send_gated_before_handshake(self):
        clock = FakeClock()
        serial = FakeSerial(clock)
        controller = rc.Controller(serial, clock.monotonic, clock.sleep, clock.wall)
        with self.assertRaises(RuntimeError):
            controller.send((1, 1, 127, (0, 0, 0, 0)), 'unsafe')
        self.assertEqual(serial.writes, [])


class WindowsTransportTests(unittest.TestCase):
    def api(self, flags=0):
        api = Mock()
        api.CreateFileW.return_value = 123
        def get_state(handle, pointer):
            ctypes.cast(pointer, ctypes.POINTER(rc.DCB)).contents.flags = flags
            return 1
        api.GetCommState.side_effect = get_state
        api.SetCommState.return_value = api.SetCommTimeouts.return_value = api.CloseHandle.return_value = 1
        return api

    def test_preserves_dtr_rts_sets_115200_8n1_and_closes(self):
        api = self.api((1 << 4) | (1 << 12) | (1 << 8))
        observed = []
        def capture(handle, pointer):
            dcb = ctypes.cast(pointer, ctypes.POINTER(rc.DCB)).contents
            observed.append((dcb.baud, dcb.bytesize, dcb.parity, dcb.stopbits, dcb.flags))
            return 1
        api.SetCommState.side_effect = capture
        with patch.object(rc.os, 'name', 'nt'), patch.object(rc.C, 'WinDLL', return_value=api, create=True):
            serial = rc.WindowsSerial('COM8')
            serial.close()
            serial.close()
        self.assertEqual(observed, [(115200, 8, 0, 0, 1 | (1 << 4) | (1 << 12))])
        self.assertEqual(ctypes.sizeof(rc.DCB), 28)
        self.assertEqual(ctypes.sizeof(rc.Timeouts), 20)
        self.assertEqual(api.CreateFileW.call_args.args[0], r'\\.\COM8')
        api.CloseHandle.assert_called_once_with(123)

    def test_automatic_line_mode_rejected_and_handle_closed(self):
        api = self.api(2 << 12)
        with patch.object(rc.os, 'name', 'nt'), patch.object(rc.C, 'WinDLL', return_value=api, create=True):
            with self.assertRaises(OSError):
                rc.WindowsSerial('COM8')
        api.SetCommState.assert_not_called()
        api.CloseHandle.assert_called_once_with(123)


if __name__ == '__main__':
    unittest.main()
