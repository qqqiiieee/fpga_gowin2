"""One bounded virtual-input test plus a bounded explicit USB-Audio recording."""
from pathlib import Path
from datetime import datetime
import argparse
import json
import os
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
SUPPORT = HERE / 'support'
RECORDER = SUPPORT / 'record_wav.py'

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', required=True)
    p.add_argument('--device-id', type=int, required=True)
    p.add_argument('--profile', choices=['note', 'chord', 'volume', 'pitch', 'kick', 'snare', 'zero'], required=True)
    p.add_argument('--output-dir', type=Path, required=True)
    args = p.parse_args()
    if not args.output_dir.is_dir():
        p.error('output directory must already exist')
    if args.device_id < 0:
        p.error('device ID must be non-negative')
    # Check the current endpoint identity immediately before capture. Never use
    # the laptop microphone or a default-device fallback for these diagnostics.
    sys.path.insert(0, str(SUPPORT))
    from audio_devices import enumerate_devices
    inputs = enumerate_devices()
    chosen = next((x for x in inputs if x['id'] == args.device_id), None)
    if chosen is None or 'USB-Audio' not in chosen['name']:
        raise RuntimeError('chosen device is not the presently enumerated USB-Audio input')
    stamp = datetime.now().strftime('%Y-%m-%d_%H%M%S_%f')
    output = args.output_dir / (stamp + '_' + args.profile + '.wav')
    commands = {
        'note': ['play', '--keys', '6', '--volume', '128', '--seconds', '5'],
        'chord': ['play', '--keys', '1,6', '--volume', '128', '--seconds', '5'],
        'volume': ['sweep', '--control', 'volume', '--start', '32', '--end', '224', '--keys', '6', '--seconds', '5'],
        'pitch': ['sweep', '--control', 'pitch', '--start', '96', '--end', '160', '--keys', '6', '--seconds', '5'],
        'kick': ['strike', '--pad', '0', '--strength', '6000', '--seconds', '3'],
        'snare': ['strike', '--pad', '1', '--strength', '6000', '--seconds', '3'],
        'zero': ['play', '--mask', '0', '--zero', '--park-i2c', '--volume', '128', '--seconds', '5'],
    }
    command_log = output.with_suffix('.commands.json')
    control_command = [sys.executable, str(HERE/'remote_control.py')] + commands[args.profile] + [
        '--port', args.port, '--log', str(command_log)]
    ready_file = output.with_suffix('.ready.json')
    record_command = [sys.executable, str(RECORDER), '--device-id', str(args.device_id),
                      '--device-name', chosen['name'], '--ready-file', str(ready_file),
                      '--output', str(output), '--seconds', '8', '--rate', '48000', '--channels', '2']
    metadata = {'started_local': datetime.now().astimezone().isoformat(), 'device': chosen,
                'profile': args.profile, 'serial_port': args.port, 'wav': str(output),
                'physical_motion': False, 'expected_note': 'S6 / A4 approximately 440 Hz' if args.profile in ['note','volume','pitch'] else None,
                'limits': 'Virtual inputs through the real FPGA and audio output. Does not test physical keys, FSR mechanics or slider contacts. Input jack/gain are uncalibrated.'}
    record = None
    child_env = os.environ.copy()
    child_env['PYTHONIOENCODING'] = 'utf-8'
    try:
        record = subprocess.Popen(record_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=child_env)
        deadline = time.monotonic() + 5
        ready = None
        while time.monotonic() < deadline:
            if ready_file.exists():
                try:
                    ready = json.loads(ready_file.read_text(encoding='utf-8'))
                    break
                except json.JSONDecodeError:
                    pass
            if record.poll() is not None:
                break
            time.sleep(.02)
        if ready is None:
            raise RuntimeError('recorder did not confirm that USB capture started; no control test sent')
        metadata['capture_ready'] = ready
        time.sleep(.75)
        if record.poll() is not None:
            stdout, stderr = record.communicate()
            raise RuntimeError('recorder ended before the control test: ' + (stdout+stderr).decode('utf-8',errors='replace'))
        metadata['control_started_local'] = datetime.now().astimezone().isoformat()
        metadata['control_started_relative_seconds'] = time.monotonic()-ready['capture_started_monotonic']
        result = subprocess.run(control_command, capture_output=True, timeout=13, env=child_env)
        metadata.update(control_exit=result.returncode,
                        control_output=(result.stdout+result.stderr).decode('utf-8',errors='replace'),
                        control_ended_local=datetime.now().astimezone().isoformat(),
                        control_ended_relative_seconds=time.monotonic()-ready['capture_started_monotonic'])
        stdout, stderr = record.communicate(timeout=17)
        metadata.update(record_exit=record.returncode,
                        record_output=(stdout+stderr).decode('utf-8',errors='replace'))
        if result.returncode or record.returncode or not output.exists():
            raise RuntimeError('control or recording failed; inspect the saved run metadata')
        journal = json.loads(command_log.read_text(encoding='utf-8'))
        metadata['release_ack_verified'] = journal.get('release', {}).get('confirmed') is True
        if not metadata['release_ack_verified']:
            raise RuntimeError('control release was not acknowledged; do not mark this run complete')
        events = journal.get('packets', [])
        active = [e for e in events if e.get('outcome') == 'acknowledged' and e.get('request', {}).get('flags', 0) & 1]
        releases = [e for e in events if e.get('phase') == 'finally_release' and e.get('outcome') == 'acknowledged']
        if not active or not releases:
            raise RuntimeError('acknowledged virtual input and release timestamps are missing')
        origin = ready['capture_started_monotonic']
        onset = min(e['response']['host_monotonic'] for e in active)-origin
        release = max(e['host_monotonic'] for e in releases)-origin
        metadata['timing'] = {
            'active_start_seconds': onset + (.4 if args.profile in ('kick','snare') else .5),
            'active_end_seconds': release - .25,
            'first_active_ack_seconds': onset,
            'release_request_seconds': release,
            'basis': 'waveInStart monotonic time and acknowledged UART journal; boundaries are coarse and deliberately trimmed',
        }
        if metadata['timing']['active_end_seconds'] <= metadata['timing']['active_start_seconds']:
            raise RuntimeError('not enough acknowledged activity for an evaluation window')
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location('offline_wav_analysis', SUPPORT/'analyze_wav.py')
        analyzer = module_from_spec(spec)
        spec.loader.exec_module(analyzer)
        metadata['audio_analysis'] = analyzer.analyze(output)[0]
        metadata['audio_analysis']['measurement_note'] = metadata['limits']
        metadata['success'] = True
    except Exception as exc:
        metadata['success'] = False
        metadata['error'] = str(exc)
        if isinstance(exc, subprocess.TimeoutExpired):
            metadata['release_ack_verified'] = False
            metadata['recovery_note'] = 'The controller was terminated by its deadline; FPGA watchdog should exit remote mode within one second after the last valid command, but release was not observed.'
        raise
    finally:
        if record is not None and record.poll() is None:
            # The recorder is itself bounded; allow cleanup, then terminate only
            # our supervised process if it fails its deadline.
            try:
                record.communicate(timeout=17)
            except subprocess.TimeoutExpired:
                record.kill()
                record.communicate(timeout=3)
        metadata['ended_local'] = datetime.now().astimezone().isoformat()
        output.with_suffix('.run.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'wav': str(output), 'metadata': str(output.with_suffix('.run.json')), 'success': True}, ensure_ascii=True))

if __name__ == '__main__':
    main()
