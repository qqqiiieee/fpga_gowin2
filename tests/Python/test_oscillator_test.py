"""Fake controller, acquisition and verification only; never open real devices."""
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import wave

import oscillator_test as ot
import remote_control as rc
from test_remote_control import FakeClock, FakeSerial, DEVICE, ack_bytes
from support import record_wav

HERE = Path(__file__).resolve().parent
NAME = '麦克风 (USB-Audio)'


class FakeRecorder:
    def __init__(self, folder, name, args, seconds, *, clock, ready=True,
                 fail=False, progress=True, stall=False, delay=.02):
        self.clock, self.origin, self.seconds = clock, clock(), seconds
        self.wav, self.deadline = (folder/(name+'.wav')).resolve(), clock()+seconds+8
        self.ready_ok, self.fail, self.progress, self.stall, self.delay = ready, fail, progress, stall, delay
        self.aborted = False
        self.ready_info = dict(capture_started_monotonic=self.origin, capture_started_epoch=1791763200+self.origin,
                               acquisition_ready_monotonic=self.origin+delay, wave_start_call_seconds=.001,
                               acquisition_progress_verified=progress, acquisition_progress_bytes=3840,
                               device_id=args.device_id, device_name=args.device_name)

    def check(self):
        if self.clock() >= self.deadline-1e-9:
            raise TimeoutError('fake bounded supervisor deadline')

    def ready(self):
        return self.ready_info if self.ready_ok and self.clock() >= self.origin+self.delay else None

    def done(self):
        self.check()
        return not self.stall and self.clock() >= self.origin+self.seconds

    def finish(self):
        if self.fail:
            raise RuntimeError('fake short capture')
        with wave.open(str(self.wav), 'wb') as wav:
            wav.setnchannels(2); wav.setsampwidth(2); wav.setframerate(48000)
            wav.writeframes(bytes(round(self.seconds*48000)*4))

    def abort(self):
        self.aborted = True


class OrchestrationTests(unittest.TestCase):
    def args(self, folder, independence=False):
        args = ot.parser().parse_args(['--port', 'COM8', '--device-id', '2', '--device-name', NAME,
            '--manifest', str(folder/'release.json'), '--output-dir', str(folder)]+
            (['--independence'] if independence else []))
        ot.validate(args)
        return args

    def run_fake(self, folder, *, independence=False, reply=None, verify=None, devices=None,
                 inputs=None, recorder_options=None, serial_error=None):
        clock = FakeClock()
        serial = FakeSerial(clock, reply=reply)
        recorders, chronology = [], []
        def verifier(*args):
            chronology.append('verify')
            if verify:
                return verify(*args)
            return dict(verified=True, read_only=True)
        def serial_factory(port):
            chronology.append('open_serial')
            if serial_error:
                raise serial_error
            return serial
        def record_factory(folder, name, args, seconds, **kw):
            chronology.append('record_'+name)
            recorder = FakeRecorder(folder, name, args, seconds, **kw, **(recorder_options or {}))
            recorders.append(recorder)
            return recorder
        report = ot.acquire(self.args(folder, independence), folder, verify_fn=verifier,
            enumerate_fn=lambda: [DEVICE] if devices is None else devices,
            audio_fn=lambda: [{'id': 2, 'name': NAME, 'channels': 2}] if inputs is None else inputs,
            serial_factory=serial_factory, recorder_factory=record_factory,
            clock=clock.monotonic, sleep=clock.sleep, wall_fn=clock.wall)
        return report, serial, recorders, chronology, clock

    def test_plan_only_has_no_reads_writes_devices_or_processes(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp, redirect_stdout(io.StringIO()) as out:
            args = ['--port', 'COM8', '--device-id', '2', '--device-name', NAME,
                    '--manifest', str(Path(tmp)/'absent.json'), '--output-dir', tmp, '--plan-only']
            with patch.object(ot, 'acquire') as acquire, patch.object(ot.subprocess, 'run') as run, \
                    patch.object(ot.rc, 'enumerate_ports') as ports, patch.object(ot, 'audio_inputs') as audio, \
                    patch.object(Path, 'read_text') as read:
                self.assertEqual(ot.main(args), 0)
                for mock in (acquire, run, ports, audio, read):
                    mock.assert_not_called()
            plan = json.loads(out.getvalue())
            self.assertEqual(plan['protocol_version'], 8)
            self.assertEqual(plan['full_bank_wav_seconds'], 8)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_invalid_inputs_fail_before_device_calls(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            for change in ({'port': 'COM0'}, {'port': 'Bluetooth'}, {'device_id': -1},
                           {'device_name': 'Realtek microphone'}):
                args = self.args(Path(tmp))
                for key, value in change.items():
                    setattr(args, key, value)
                with self.assertRaises(ValueError):
                    ot.validate(args)

    def test_main_capture_exact_arm_hold_zero_wait_full_8_and_final_cleanup(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, recorders, order, _ = self.run_fake(Path(tmp))
            self.assertTrue(report['success'], report.get('error'))
            self.assertTrue(report['release_ack_verified'])
            self.assertTrue(report['exit']['s16_echo_verified'])
            self.assertTrue(serial.closed)
            self.assertTrue(all(r.aborted for r in recorders))
            self.assertEqual(order[:3], ['verify', 'open_serial', 'record_bank_native'])
            events = report['events']
            arm = next(e for e in events if e['phase'] == 'arm_exact_S13_S15')
            released = next(e for e in events if e['phase'] == 'arm_keys_release')
            self.assertEqual(arm['request']['keys'], 0x5000)
            self.assertGreaterEqual(arm['host_monotonic'], recorders[0].origin+.02)
            self.assertAlmostEqual(released['host_monotonic']-arm['host_monotonic'], 2.2)
            self.assertAlmostEqual(report['bank_native_start_seconds']-
                                   (released['host_monotonic']-recorders[0].origin), .1)
            with wave.open(report['wav'], 'rb') as wav:
                self.assertEqual(wav.getnframes(), 48000*8)
            self.assertTrue(Path(report['wav']).is_absolute())
            self.assertFalse(report['fpga_test_state_verified'])
            self.assertFalse(report['physical_controls_verified'])
            s16 = next(e for e in events if e['phase'] == 'finally_S16_exit')
            disabled = next(e for e in events if e['phase'] == 'finally_disabled_release')
            self.assertEqual(s16['request']['keys'], 0x8000)
            self.assertGreaterEqual(disabled['host_monotonic']-s16['host_monotonic'], .08-1e-8)
            self.assertEqual(disabled['request']['flags'], 0)

    def test_entire_captures_keep_100ms_alive_and_retain_sequence_wrap_events(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, recorders, _, clock = self.run_fake(Path(tmp), independence=True)
            self.assertTrue(report['success'], report.get('error'))
            self.assertEqual([r.seconds for r in recorders], [11, 32.6])
            self.assertLess(clock.now, 50)
            self.assertGreater(len(report['events']), 400)
            self.assertEqual(report['packet_count'], len(report['events']))
            for recorder in recorders:
                times = [t for t, _ in serial.writes if recorder.origin <= t <= recorder.origin+recorder.seconds]
                gaps = [b-a for a, b in zip([recorder.origin]+times, times+[recorder.origin+recorder.seconds])]
                self.assertLessEqual(max(gaps), .10001)
            pulses = [e for e in report['events'] if e['request']['keys'] == 0x20]
            self.assertEqual(len(pulses), 1)
            self.assertEqual(report['independence_timing']['source'], 'waveInStart+protocol08_echo')
            self.assertIn(0, [e['seq'] for e in report['events'][250:]])

    def test_manifest_failure_never_enumerates_opens_or_captures(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            args = self.args(Path(tmp))
            verify = Mock(side_effect=RuntimeError('wrong UserCode'))
            ports, audio, serial, recorder = Mock(), Mock(), Mock(), Mock()
            report = ot.acquire(args, Path(tmp), verify_fn=verify, enumerate_fn=ports,
                                audio_fn=audio, serial_factory=serial, recorder_factory=recorder)
            self.assertFalse(report['success'])
            for mock in (ports, audio, serial, recorder):
                mock.assert_not_called()

    def test_wrong_ftdi_or_exact_audio_identity_blocks_open(self):
        cases = [dict(devices=[]), dict(devices=[DEVICE|{'service': 'Bluetooth'}]),
                 dict(inputs=[{'id': 2, 'name': NAME+' changed', 'channels': 2}]),
                 dict(inputs=[{'id': 2, 'name': NAME, 'channels': 1}]),
                 dict(inputs=[{'id': 1, 'name': NAME, 'channels': 2}])]
        for case in cases:
            with tempfile.TemporaryDirectory(dir=HERE) as tmp:
                report, serial, recorders, _, _ = self.run_fake(Path(tmp), **case)
                self.assertFalse(report['success']); self.assertEqual(serial.writes, [])
                self.assertEqual(recorders, [])

    def test_absent_progress_or_late_readiness_never_sends_arm(self):
        for options in ({'ready': False}, {'progress': False}, {'delay': .4}):
            with tempfile.TemporaryDirectory(dir=HERE) as tmp:
                report, serial, recorders, _, _ = self.run_fake(Path(tmp), recorder_options=options)
                self.assertFalse(report['success'])
                self.assertFalse(any(e['request']['keys'] == 0x5000 for e in report['events']))
                self.assertTrue(report['release_ack_verified'])
                self.assertTrue(serial.closed); self.assertTrue(recorders[0].aborted)

    def test_short_capture_failure_still_s16_then_disabled_and_closes(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, recorders, _, _ = self.run_fake(Path(tmp), recorder_options={'fail': True})
            self.assertFalse(report['success'])
            self.assertTrue(report['exit']['s16_attempted'])
            self.assertTrue(report['release_ack_verified']); self.assertTrue(serial.closed)
            self.assertTrue(recorders[0].aborted)

    def test_worker_stall_stops_before_40s_and_cleans_up(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, recorders, _, clock = self.run_fake(Path(tmp), recorder_options={'stall': True})
            self.assertFalse(report['success']); self.assertLess(clock.now, 20)
            self.assertTrue(report['release_ack_verified']); self.assertTrue(serial.closed)
            self.assertTrue(recorders[0].aborted)

    def test_two_lost_active_acks_stop_and_confirm_final_disabled(self):
        def reply(count, seq, flags, keys, adc):
            return None if flags & 1 else ack_bytes(seq, flags, keys, adc)
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, recorders, _, clock = self.run_fake(Path(tmp), reply=reply)
            self.assertFalse(report['success']); self.assertLess(clock.now, 2)
            self.assertGreaterEqual(report['failed_active_requests'], 2)
            self.assertTrue(report['exit']['s16_attempted']); self.assertTrue(report['release_ack_verified'])
            self.assertFalse(report['exit']['s16_echo_verified'])
            self.assertTrue(serial.closed); self.assertTrue(recorders[0].aborted)

    def test_one_lost_keepalive_is_tolerated(self):
        lost = False
        def reply(count, seq, flags, keys, adc):
            nonlocal lost
            if flags & 1 and keys == 0 and not lost:
                # Avoid losing the explicit arm-release event: lose a later
                # periodic zero-key packet in the full-bank capture.
                if count > 30:
                    lost = True
                    return None
            return ack_bytes(seq, flags, keys, adc)
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, _, _, _, _ = self.run_fake(Path(tmp), reply=reply)
            self.assertTrue(report['success'], report.get('error')); self.assertTrue(lost)
            self.assertEqual(report['failed_active_requests'], 1)

    def test_release_failure_is_not_success_or_test_state_confirmation(self):
        def reply(count, seq, flags, keys, adc):
            return None if count > 3 and flags == 0 else ack_bytes(seq, flags, keys, adc)
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, _, _, _ = self.run_fake(Path(tmp), reply=reply)
            self.assertFalse(report['success']); self.assertFalse(report['release_ack_verified'])
            self.assertFalse(report['fpga_test_state_verified']); self.assertTrue(serial.closed)
            self.assertFalse(report['exit']['watchdog_verified'])

    def test_write_failure_cleanup_still_attempts_disabled(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            clock = FakeClock(); serial = FakeSerial(clock)
            original = serial.write
            def write(packet):
                if int.from_bytes(packet[4:6], 'little') == 0x5000:
                    raise OSError('fake write failure')
                original(packet)
            serial.write = write
            report = ot.acquire(self.args(Path(tmp)), Path(tmp), verify_fn=lambda *a: {},
                enumerate_fn=lambda: [DEVICE], audio_fn=lambda: [{'id': 2, 'name': NAME, 'channels': 2}],
                serial_factory=lambda port: serial, recorder_factory=FakeRecorder,
                clock=clock.monotonic, sleep=clock.sleep, wall_fn=clock.wall)
            self.assertFalse(report['success']); self.assertTrue(report['release_ack_verified'])
            self.assertTrue(serial.closed)

    def test_handshake_failure_never_sends_active_keys(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, recorders, _, _ = self.run_fake(Path(tmp), reply=lambda *a: None)
            self.assertFalse(report['success']); self.assertEqual(recorders, [])
            self.assertTrue(all(packet[3] == 0 for _, packet in serial.writes))
            self.assertFalse(report['exit']['s16_attempted']); self.assertTrue(serial.closed)

    def test_failed_s16_write_still_confirms_disabled_but_not_success(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            clock = FakeClock(); serial = FakeSerial(clock)
            original = serial.write
            def write(packet):
                if int.from_bytes(packet[4:6], 'little') == 0x8000:
                    raise OSError('fake S16 write failure')
                original(packet)
            serial.write = write
            report = ot.acquire(self.args(Path(tmp)), Path(tmp), verify_fn=lambda *a: {},
                enumerate_fn=lambda: [DEVICE], audio_fn=lambda: [{'id': 2, 'name': NAME, 'channels': 2}],
                serial_factory=lambda port: serial, recorder_factory=FakeRecorder,
                clock=clock.monotonic, sleep=clock.sleep, wall_fn=clock.wall)
            self.assertFalse(report['success']); self.assertTrue(report['release_ack_verified'])
            self.assertFalse(report['exit']['s16_echo_verified']); self.assertTrue(serial.closed)

    def test_two_mismatched_ack_echoes_stop_capture_and_release(self):
        def reply(count, seq, flags, keys, adc):
            return ack_bytes(seq, flags, keys ^ 1 if flags & 1 else keys, adc)
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, recorders, _, clock = self.run_fake(Path(tmp), reply=reply)
            self.assertFalse(report['success']); self.assertLess(clock.now, 2)
            self.assertTrue(report['release_ack_verified']); self.assertTrue(serial.closed)
            self.assertTrue(recorders[0].aborted)
            self.assertGreaterEqual(report['failed_active_requests'], 2)

    def test_active_bit7_synth_overrun_latches_stops_and_finally_releases(self):
        reported = False
        def reply(count, seq, flags, keys, adc):
            nonlocal reported
            if flags & 1 and not reported:
                reported = True
                return ack_bytes(seq, flags | 0x80, keys, adc)
            return ack_bytes(seq, flags, keys, adc)
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, recorders, _, clock = self.run_fake(Path(tmp), reply=reply)
            self.assertFalse(report['success']); self.assertEqual(report['status'], 'fail')
            self.assertTrue(report['synth_overrun_seen'])
            self.assertIn('synth_overrun', report['error'])
            self.assertIn('bit7', report['overrun_reason'])
            self.assertEqual(report['synth_overrun_event']['ack_flags'] & 0x80, 0x80)
            self.assertLess(clock.now, 1)
            self.assertTrue(report['exit']['s16_echo_verified']); self.assertTrue(report['release_ack_verified'])
            self.assertTrue(serial.closed); self.assertTrue(recorders[0].aborted)

    def test_physical_adc_fault_bit3_alone_does_not_fail_mode(self):
        def reply(count, seq, flags, keys, adc):
            return ack_bytes(seq, flags | 8, keys, adc)
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, _, _, _ = self.run_fake(Path(tmp), reply=reply)
            self.assertTrue(report['success'], report.get('error'))
            self.assertFalse(report['synth_overrun_seen'])
            self.assertTrue(report['release_ack_verified']); self.assertTrue(serial.closed)

    def test_valid_unmatched_bit7_ack_while_active_also_latches(self):
        def reply(count, seq, flags, keys, adc):
            normal = ack_bytes(seq, flags, keys, adc)
            return ack_bytes((seq+37) & 255, flags | 0x80, keys, adc)+normal if flags & 1 else normal
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, _, _, _ = self.run_fake(Path(tmp), reply=reply)
            self.assertTrue(report['synth_overrun_seen']); self.assertFalse(report['success'])
            self.assertEqual(report['status'], 'fail')
            self.assertTrue(report['release_ack_verified']); self.assertTrue(serial.closed)

    def test_overrun_on_s16_cleanup_ack_cannot_report_success(self):
        def reply(count, seq, flags, keys, adc):
            return ack_bytes(seq, flags | (0x80 if keys == ot.EXIT_KEY else 0), keys, adc)
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            report, serial, _, _, _ = self.run_fake(Path(tmp), reply=reply)
            self.assertTrue(report['synth_overrun_seen']); self.assertFalse(report['success'])
            self.assertEqual(report['status'], 'fail')
            self.assertTrue(report['exit']['s16_echo_verified']); self.assertTrue(report['release_ack_verified'])
            self.assertTrue(serial.closed)


class ManifestAndRecorderTests(unittest.TestCase):
    def test_manifest_independent_readback_is_checked_not_just_returncode(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp); firmware = folder/'release.fs'; firmware.write_bytes(b'fake offline firmware')
            manifest = folder/'release.json'
            manifest.write_text(json.dumps(dict(firmware_name='release.fs',
                usercode='0x12345678', sha256=hashlib.sha256(firmware.read_bytes()).hexdigest())), encoding='utf-8')
            def run(command, **kwargs):
                (folder/'firmware_readback.json').write_text(json.dumps(dict(read_only=True,
                    verified=True, firmware_sha256_verified=True, exit_code=0,
                    actual_usercode='0x12345678', expected_usercode='0x12345678')), encoding='utf-8')
                self.assertIn('verify_firmware.py', ' '.join(command))
                self.assertEqual(kwargs['timeout'], 20)
                return SimpleNamespace(returncode=0)
            self.assertTrue(ot.verify_manifest(manifest, folder, run=run)['verified'])
            proof = json.loads((folder/'firmware_readback.json').read_text(encoding='utf-8'))
            proof['actual_usercode'] = '0x99999999'
            (folder/'firmware_readback.json').write_text(json.dumps(proof), encoding='utf-8')
            with self.assertRaises(RuntimeError):
                ot.verify_manifest(manifest, folder, run=lambda *a, **kw: SimpleNamespace(returncode=0))

    def test_hash_failure_happens_before_readback_process(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp); (folder/'release.fs').write_bytes(b'wrong')
            manifest = folder/'release.json'
            manifest.write_text(json.dumps(dict(firmware_name='release.fs', usercode='0x12345678', sha256='0'*64)), encoding='utf-8')
            run = Mock()
            with self.assertRaises(RuntimeError):
                ot.verify_manifest(manifest, folder, run=run)
            run.assert_not_called()

    def test_native_default_8_maximum_40_finite(self):
        for value in (.1, 8, 32.6, 40):
            self.assertEqual(record_wav.checked_seconds(value), value)
        for value in (0, 40.01, 70, float('inf'), float('nan')):
            with self.assertRaises(ValueError):
                record_wav.checked_seconds(value)

    def test_parent_supervisor_kills_only_its_native_worker(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            clock = FakeClock()
            child = SimpleNamespace(poll=lambda: None, kill=Mock(), communicate=Mock(return_value=(b'', b'')))
            popen = Mock(return_value=child)
            args = SimpleNamespace(device_id=2, device_name=NAME)
            recorder = ot.Recorder(Path(tmp), 'native', args, 32.6, clock=clock.monotonic, popen=popen)
            command = popen.call_args.args[0]
            self.assertIn('--_worker', command)
            self.assertEqual(command[command.index('--seconds')+1], '32.6')
            self.assertEqual(command[command.index('--channels')+1], '2')
            clock.sleep(40.7)
            with self.assertRaises(TimeoutError):
                recorder.check()
            recorder.abort(); child.kill.assert_called_once()
            child.communicate.assert_called_once_with(timeout=3)


if __name__ == '__main__':
    unittest.main()
