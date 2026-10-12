"""Bounded host validation of the 32-oscillator firmware, protocol 08 unchanged.

--plan-only performs no enumeration, JTAG, serial, capture or filesystem writes.
Actual runs require an independent manifest/UserCode check before controls.
There is no programming operation in this tool.
"""
from __future__ import annotations

import argparse
from collections import deque
from datetime import datetime, timezone, timedelta
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import wave

import remote_control as rc

HERE = Path(__file__).resolve().parent
SHANGHAI = timezone(timedelta(hours=8), 'Asia/Shanghai')
ARM_KEYS = 0x5000
EXIT_KEY = 0x8000
SWEEP_KEY = 0x0020
VOICE_KEYS = {1: 0x0001, 4: 0x0002, 8: 0x0004, 16: 0x0008, 32: 0x0010}
ADC = (0, 0, rc.slider_adc(128), rc.slider_adc(128))
MAIN_NATIVE_SECONDS = 11.0
MAIN_SECONDS = 8.0
SWEEP_SECONDS = 32.6
OVERRUN_REASON = 'FPGA synth_overrun: protocol08 ACK flags bit7 observed during active control'


def wall():
    return datetime.now(timezone.utc).isoformat(timespec='microseconds')


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', required=True, help='explicit present FTDI COMn; no automatic selection')
    p.add_argument('--device-id', required=True, type=int, help='explicit current WinMM input ID')
    p.add_argument('--device-name', required=True, help='exact current WinMM USB-Audio name')
    p.add_argument('--manifest', required=True, type=Path, help='independent release manifest (firmware_name, sha256, usercode)')
    p.add_argument('--output-dir', type=Path, default=HERE/'measurements', help='existing directory; creates an exclusive run folder')
    p.add_argument('--independence', action='store_true', help='one additional 32.6 s autonomous sweep capture')
    p.add_argument('--plan-only', action='store_true', help='read-only plan; never touches devices or creates files')
    return p


def validate(args):
    args.port = args.port.upper()
    if not re.fullmatch(r'COM[1-9][0-9]*', args.port):
        raise ValueError('explicit --port COMn required')
    if args.device_id < 0 or 'USB-Audio' not in args.device_name:
        raise ValueError('explicit nonnegative WinMM ID and exact USB-Audio name required')
    args.manifest = args.manifest.resolve()
    args.output_dir = args.output_dir.resolve()


def make_plan(args):
    return dict(plan_only=args.plan_only, port=args.port, device_id=args.device_id,
                device_name=args.device_name, manifest=str(args.manifest), output_dir=str(args.output_dir),
                run_folder_timezone='Asia/Shanghai',
                protocol_version=8, new_uart_flags=False, programming_performed=False,
                requires_independent_usercode=True, acquisition_ready_before_stimulus=True,
                keepalive_seconds=.1, consecutive_ack_failure_limit=2,
                synth_overrun_ack_bit=7, synth_overrun_allowed=False,
                waveform_overrun_tb_required=0,
                physical_adc_fault_ack_bit=3, physical_adc_fault_alone_fails_test=False,
                full_bank_wav_seconds=8, main_native_capture_seconds=MAIN_NATIVE_SECONDS,
                main_pre_roll_note='finite 11 s acquisition includes readiness + 2.2 s arm; save a full 8 s bank window',
                independence=args.independence, independence_capture_seconds=SWEEP_SECONDS if args.independence else None,
                maximum_single_capture_seconds=40,
                sequence=['exact S13+S15 = 0x5000 hold 2.2 s',
                          'normal fade 21.8 ms then test fade 21.8 ms (firmware)',
                          'release keys=0; wait 0.1 s; default 32 voices',
                          'save 8 s full-bank WAV',
                          'optional S6: autonomous index 0 OFF first; OFF 0.5 s / ON 0.5 s; total 32 s',
                          'finally S16 hold 0.08 s; DISABLED; verify release echo'],
                voice_selection_masks={str(k): f'0x{v:04x}' for k, v in VOICE_KEYS.items()},
                remote_active_falling_exit='DISABLED or 1 s watchdog fades/exits; watchdog not observed by host',
                physical_mode_idle_autoexit_seconds=60,
                ack_scope='echo only: no FPGA test-state ACK exists',
                target_hz=[400+97*i for i in range(32)],
                dds_hz=[round((400+97*i)*2**24/93750)*93750/2**24 for i in range(32)])


def verify_manifest(manifest_path, folder, run=subprocess.run):
    """Reuse V009 read-only UserCode reader; reject missing/forged completion."""
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    usercode = manifest.get('usercode', '')
    digest = manifest.get('sha256', '')
    if (not isinstance(usercode, str) or not re.fullmatch(r'0x[0-9a-fA-F]{8}', usercode)
            or usercode.lower() == '0xffffffff' or not isinstance(digest, str)
            or not re.fullmatch(r'[0-9a-f]{64}', digest)):
        raise ValueError('manifest requires concrete UserCode and lowercase firmware SHA256')
    firmware = manifest_path.parent/manifest['firmware_name']
    if hashlib.sha256(firmware.read_bytes()).hexdigest() != digest:
        raise RuntimeError('manifest firmware SHA256 mismatch')
    record = folder/'firmware_readback.json'
    command = [sys.executable, '-B', str(HERE/'verify_firmware.py'),
               '--manifest', str(manifest_path), '--output', str(record)]
    env = os.environ.copy(); env['PYTHONIOENCODING'] = 'utf-8'
    response = run(command, capture_output=True, timeout=20, env=env)
    if response.returncode or not record.is_file():
        raise RuntimeError('independent FPGA UserCode readback failed; no controls or recording started')
    proof = json.loads(record.read_text(encoding='utf-8'))
    if (proof.get('verified') is not True or proof.get('read_only') is not True
            or proof.get('firmware_sha256_verified') is not True or proof.get('exit_code') != 0
            or str(proof.get('actual_usercode', '')).lower() != usercode.lower()
            or str(proof.get('expected_usercode', '')).lower() != usercode.lower()):
        raise RuntimeError('independent manifest/UserCode proof does not match this release')
    return dict(manifest=str(manifest_path), readback=str(record), **proof)


def audio_inputs():
    # Same module name as V009, preserving its audio_devices mock contract.
    sys.path.insert(0, str(HERE/'support'))
    from audio_devices import enumerate_devices
    return enumerate_devices()


class SynthAckStream(rc.AckStream):
    """Observe every valid version-08 ACK without changing echo matching."""
    def __init__(self, controller):
        super().__init__()
        self.controller = controller

    def feed(self, data):
        frames = super().feed(data)
        for raw, ack in frames:
            self.controller.observe_synth_status(raw, ack)
        return frames


class OscillatorController(rc.Controller):
    """V009 transport/matching plus a latched synth-overrun host criterion."""
    def __init__(self, *args):
        super().__init__(*args)
        self.synth_overrun_event = None
        self.active_control = self.had_active_control = False
        self.current_phase = 'initial'
        self.stream = SynthAckStream(self)

    def send(self, state, phase):
        record = super().send(state, phase)
        self.active_control = bool(state[0] & 1)
        self.had_active_control |= self.active_control
        self.current_phase = phase
        return record

    def observe_synth_status(self, raw, ack):
        # Include valid late/unmatched ACKs while active, and late active ACKs
        # during release. Bit3 denotes physical ADC fault and is not this fault.
        active = self.active_control or (self.had_active_control and ack['active'])
        if active and ack['flags'] & 0x80 and self.synth_overrun_event is None:
            self.synth_overrun_event = dict(reason=OVERRUN_REASON, phase=self.current_phase,
                host_timestamp=self.wall(), host_monotonic=self.clock(), ack_hex=raw.hex(),
                ack_seq=ack['seq'], ack_flags=ack['flags'], synth_overrun=True,
                physical_adc_fault=bool(ack['flags'] & 8), test_state_ack=False)

    def pump(self, deadline, until=None, stop=True):
        if stop and self.synth_overrun_event is not None:
            raise RuntimeError(OVERRUN_REASON)
        try:
            super().pump(deadline, until=until, stop=stop)
        finally:
            if stop and self.synth_overrun_event is not None:
                raise RuntimeError(OVERRUN_REASON)


class Recorder:
    """Own exactly one native worker; supervisor deadline also bounds cleanup."""
    def __init__(self, folder, name, args, seconds, clock=time.monotonic,
                 popen=subprocess.Popen):
        self.clock, self.seconds = clock, seconds
        self.wav = (folder/(name+'.wav')).resolve()
        self.ready_file = (folder/(name+'.ready.json')).resolve()
        self.deadline = clock()+seconds+8
        self.ready_data = None
        command = [sys.executable, '-B', str(HERE/'support'/'record_wav.py'), '--_worker',
                   '--device-id', str(args.device_id), '--device-name', args.device_name,
                   '--output', str(self.wav), '--ready-file', str(self.ready_file),
                   '--seconds', str(seconds), '--rate', '48000', '--channels', '2']
        env = os.environ.copy(); env['PYTHONIOENCODING'] = 'utf-8'
        self.process = popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)

    def check(self):
        if self.clock() >= self.deadline-1e-9 and self.process.poll() is None:
            raise TimeoutError('native recording exceeded supervisor deadline')

    def ready(self):
        self.check()
        if self.ready_data is not None:
            return self.ready_data
        if self.ready_file.exists():
            try:
                self.ready_data = json.loads(self.ready_file.read_text(encoding='utf-8'))
            except json.JSONDecodeError:
                return None
        if self.process.poll() is not None and self.ready_data is None:
            raise RuntimeError('recorder ended without verified acquisition readiness')
        return self.ready_data

    def done(self):
        self.check()
        return self.process.poll() is not None

    def finish(self):
        stdout, stderr = self.process.communicate(timeout=1)
        if self.process.returncode or not self.wav.is_file():
            raise RuntimeError('recording failed: '+(stdout+stderr).decode('utf-8', errors='replace')[-2000:])
        with wave.open(str(self.wav), 'rb') as wav:
            if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth(), wav.getnframes()) != (
                    48000, 2, 2, round(self.seconds*48000)):
                raise RuntimeError('recording format/duration is not the requested complete capture')

    def abort(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.communicate(timeout=3)


class Session:
    """Pump the reused Controller while maintaining 100 ms packets across waits."""
    def __init__(self, controller, clock):
        self.control, self.clock = controller, clock
        # V009 retains 100 records for short tests. This finite session needs
        # every sweep event, including request/ACK times and sequence wraps.
        controller.records = deque(maxlen=2048)
        self.state, self.phase = rc.DISABLED, 'capture_disabled_keepalive'
        self.next_tick = clock()

    def poll(self, end, recorder=None, *, stop=True):
        if recorder is not None:
            recorder.check()
        if self.clock() >= self.next_tick-1e-9:
            if stop and self.control.stopped:
                raise RuntimeError('two consecutive ACK failures; test stopped')
            self.control.send(self.state, self.phase+'_keepalive')
            self.next_tick = self.clock()+rc.KEEPALIVE
        self.control.pump(min(end, self.next_tick, self.clock()+.02), stop=stop)

    def wait(self, seconds, recorder=None, *, stop=True):
        end = self.clock()+seconds
        while self.clock() < end-1e-9:
            self.poll(end, recorder, stop=stop)

    def set_keys(self, keys, phase):
        self.state = (1, keys, 127, ADC)
        self.phase = phase
        record = self.control.send(self.state, phase)
        self.next_tick = self.clock()+rc.KEEPALIVE
        return record

    def wait_ack(self, record, recorder=None, *, stop=True):
        while record['outcome'] == 'pending':
            self.poll(record['deadline'], recorder, stop=stop)
            self.control.settle()
        if record['outcome'] != 'acknowledged':
            raise RuntimeError(record.get('error', 'control echo unconfirmed'))
        return record['response']

    def wait_ready(self, recorder, args):
        end = self.clock()+5
        while self.clock() < end-1e-9:
            ready = recorder.ready()
            if ready is not None:
                required = ('capture_started_monotonic', 'capture_started_epoch',
                            'acquisition_ready_monotonic', 'wave_start_call_seconds')
                if (ready.get('acquisition_progress_verified') is not True
                        or ready.get('acquisition_progress_bytes', 0) < 4
                        or ready.get('device_id') != args.device_id
                        or ready.get('device_name') != args.device_name
                        or any(not isinstance(ready.get(k), (int, float))
                               or not math.isfinite(ready[k]) for k in required)
                        or not 0 <= ready['wave_start_call_seconds'] <= .05
                        or not ready['capture_started_monotonic'] <= ready['acquisition_ready_monotonic'] <= self.clock()
                        or self.clock()-ready['capture_started_monotonic'] > .30):
                    raise RuntimeError('acquisition readiness/identity/timing is unverified or too late')
                return ready
            self.poll(end, recorder)
        raise TimeoutError('recorder did not confirm real acquisition readiness; no stimulus sent')


def trim_main(raw_wav, output, offset):
    with wave.open(str(raw_wav), 'rb') as wav:
        start = math.ceil(offset*48000)
        count = round(MAIN_SECONDS*48000)
        if start < 0 or start+count > wav.getnframes():
            raise RuntimeError('capture does not contain a complete 8 s full-bank window')
        wav.setpos(start)
        pcm = wav.readframes(count)
    with output.open('xb') as stream:
        with wave.open(stream, 'wb') as wav:
            wav.setnchannels(2); wav.setsampwidth(2); wav.setframerate(48000)
            wav.writeframes(pcm)
    return start/48000


def acquire(args, folder, *, verify_fn=verify_manifest, enumerate_fn=rc.enumerate_ports,
            audio_fn=audio_inputs, serial_factory=rc.WindowsSerial, recorder_factory=Recorder,
            clock=time.monotonic, sleep=time.sleep, wall_fn=wall):
    report = dict(plan=make_plan(args), success=False, status='inconclusive',
                  folder=str(folder.resolve()), physical_controls_verified=False,
                  hardware_checks_claimed=False, fpga_test_state_verified=False,
                  synth_overrun_seen=False,
                  release_ack_verified=False, events=[], captures=[], started_utc=wall_fn())
    serial = control = session = None
    recorders = []
    try:
        report['firmware_verification'] = verify_fn(args.manifest, folder)
        devices = [d for d in enumerate_fn() if d.get('port') == args.port]
        if len(devices) != 1 or not rc.verified_ftdi(devices[0]):
            raise ValueError('chosen port is not a unique present verified FTDI device')
        inputs = [d for d in audio_fn() if d.get('id') == args.device_id]
        if (len(inputs) != 1 or inputs[0].get('name') != args.device_name
                or 'USB-Audio' not in inputs[0]['name'] or inputs[0].get('channels', 0) < 2):
            raise ValueError('chosen WinMM ID/exact stereo USB-Audio name changed; no fallback')
        report['serial_device'], report['audio_device'] = devices[0], inputs[0]
        serial = serial_factory(args.port)
        control = OscillatorController(serial, clock, sleep, wall_fn)
        session = Session(control, clock)
        report['handshake'] = control.exchange(rc.DISABLED, 'disabled_protocol08_handshake')
        control.handshaken = True
        main = recorder_factory(folder, 'bank_native', args, MAIN_NATIVE_SECONDS, clock=clock)
        recorders.append(main)
        ready = session.wait_ready(main, args)
        report['captures'].append(dict(wav=str(main.wav), requested_seconds=MAIN_NATIVE_SECONDS, ready=ready))
        armed = session.set_keys(ARM_KEYS, 'arm_exact_S13_S15')
        # Hold from successful serial write, not from process launch or ACK.
        session.wait(2.2, main)
        session.wait_ack(armed, main)
        released = session.set_keys(0, 'arm_keys_release')
        session.wait(.1, main)
        session.wait_ack(released, main)
        bank_start = clock()
        report['bank_native_start_seconds'] = bank_start-ready['capture_started_monotonic']
        if report['bank_native_start_seconds']+8 > MAIN_NATIVE_SECONDS:
            raise RuntimeError('readiness/entry too slow for the finite full-bank window')
        while not main.done():
            session.poll(main.deadline, main)
        main.finish()
        full_wav = (folder/'bank32.wav').resolve()
        offset = trim_main(main.wav, full_wav, report['bank_native_start_seconds'])
        report.update(wav=str(full_wav), wav_native=str(main.wav),
                      wav_first_sample_monotonic=ready['capture_started_monotonic']+offset,
                      wav_first_sample_epoch=ready['capture_started_epoch']+offset,
                      sample_time_calibration='approximate host waveInStart + sample offset; driver latency uncalibrated')
        if args.independence:
            sweep = recorder_factory(folder, 'independence32', args, SWEEP_SECONDS, clock=clock)
            recorders.append(sweep)
            ready = session.wait_ready(sweep, args)
            report['captures'].append(dict(wav=str(sweep.wav), requested_seconds=SWEEP_SECONDS, ready=ready))
            pulse = session.set_keys(SWEEP_KEY, 'autonomous_sweep_S6')
            session.wait(.08, sweep)
            session.set_keys(0, 'sweep_keys_release')
            ack = session.wait_ack(pulse, sweep)
            origin = ready['capture_started_monotonic']
            request_time, ack_time = pulse['host_monotonic'], ack['host_monotonic']
            report['independence_timing'] = dict(
                source='waveInStart+protocol08_echo', acquisition_progress_verified=True,
                sweep_request_seconds=request_time-origin, sweep_ack_seconds=ack_time-origin,
                sweep_start_seconds=(request_time+ack_time)/2-origin,
                uncertainty_seconds=max(.05, (ack_time-request_time)/2+ready['wave_start_call_seconds']),
                basis='UART request/echo interval; FPGA onset and audio input latency approximate')
            if ack_time-origin+32 > SWEEP_SECONDS:
                raise RuntimeError('sweep onset too late for complete 32 s capture with padding')
            while not sweep.done():
                session.poll(sweep.deadline, sweep)
            sweep.finish()
            report['independence_wav'] = str(sweep.wav)
        report['success'] = True
    except (Exception, KeyboardInterrupt) as exc:
        report['error'] = str(exc) or 'interrupted'
        report['success'] = False
    finally:
        if control is not None:
            report['exit'] = dict(s16_attempted=False, s16_echo_verified=False,
                                  disabled_attempted=False, release_ack_verified=False,
                                  note='ACK proves virtual key/flags echo only; test-mode exit inferred from firmware behavior')
            if control.handshaken:
                record = None
                try:
                    report['exit']['s16_attempted'] = True
                    record = session.set_keys(EXIT_KEY, 'finally_S16_exit')
                    session.wait(.08, stop=False)
                except (Exception, KeyboardInterrupt) as exc:
                    report['exit']['s16_error'] = str(exc) or 'interrupted'
            else:
                record = None
                report['exit']['s16_note'] = 'active keys forbidden without disabled protocol08 handshake'
            # Attempt DISABLED even when the S16 send, ACK, recording or driver
            # failed. This is an observed release echo, never a test-state ACK.
            try:
                report['exit']['disabled_attempted'] = True
                session.state, session.phase = rc.DISABLED, 'finally_disabled'
                release_record = control.send(rc.DISABLED, 'finally_disabled_release')
                session.next_tick = clock()+rc.KEEPALIVE
                release = session.wait_ack(release_record, stop=False)
                report['release_ack_verified'] = bool(not release['active'] and release['flags'] & 7 == 0)
                report['exit'].update(release_ack_verified=report['release_ack_verified'], release_echo=release)
                if record is not None:
                    report['exit']['s16_echo_verified'] = record['outcome'] == 'acknowledged'
            except (Exception, KeyboardInterrupt) as exc:
                report['exit'].update(release_error=str(exc) or 'interrupted',
                                      watchdog_expected_seconds=1, watchdog_verified=False)
            if not report['release_ack_verified'] or not report['exit']['s16_echo_verified'] or control.stopped:
                report['success'] = False
            for pending in control.pending.values():
                if pending['outcome'] == 'pending':
                    pending.update(outcome='unconfirmed_at_close')
            report.update(events=list(control.records), packet_count=control.total,
                          bad_ack_frames=control.stream.bad_frames, failed_active_requests=control.failures)
            if control.synth_overrun_event is not None:
                report.update(synth_overrun_seen=True, synth_overrun_event=control.synth_overrun_event,
                              overrun_reason=OVERRUN_REASON, success=False, status='fail')
                report.setdefault('error', OVERRUN_REASON)
        if serial is not None:
            try:
                serial.close()
            except Exception as exc:
                report.update(close_error=str(exc), success=False)
        for recorder in recorders:
            try:
                recorder.abort()
            except Exception as exc:
                report.setdefault('recorder_cleanup_errors', []).append(str(exc))
                report['success'] = False
        report['finished_utc'] = wall_fn()
    return report


def main(argv=None):
    p = parser()
    args = p.parse_args(argv)
    try:
        validate(args)
    except ValueError as exc:
        p.error(str(exc))
    if args.plan_only:
        print(json.dumps(make_plan(args), ensure_ascii=True, indent=2))
        return 0
    if not args.manifest.is_file() or not args.output_dir.is_dir():
        p.error('manifest must exist; output-dir must already be a directory')
    folder = args.output_dir/(datetime.now(SHANGHAI).strftime('%Y-%m-%d_%H%M%S_%f')+'_oscillators')
    folder.mkdir(exist_ok=False)
    report = acquire(args, folder)
    try:
        if report['success']:
            from analyze_oscillators import analyze, save_report
            assessment, fft = analyze(report['wav'], independence_wav=report.get('independence_wav'),
                                      timing=report.get('independence_timing'))
            report['analysis_reports'] = save_report(assessment, fft, folder)
            report['status'] = assessment['status']
    except Exception as exc:
        report.update(status='inconclusive', analysis_error=str(exc))
    with (folder/'controller_events.json').open('x', encoding='utf-8') as out:
        json.dump(report, out, ensure_ascii=False, indent=2, allow_nan=False)
    summary = dict(status=report['status'], acquisition_success=report['success'],
                   release_ack_verified=report['release_ack_verified'], folder=str(folder),
                   synth_overrun_seen=report.get('synth_overrun_seen', False))
    if report.get('synth_overrun_seen'):
        summary['overrun_reason'] = report['overrun_reason']
    print(json.dumps(summary, ensure_ascii=True))
    return {'pass': 0, 'fail': 1, 'inconclusive': 2}[report['status']]


if __name__ == '__main__':
    raise SystemExit(main())
