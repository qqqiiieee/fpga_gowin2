"""Run a prepared, bounded virtual-input/real-audio functional test suite."""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import argparse
import json
import os
import subprocess
import sys

HERE = Path(__file__).resolve().parent
PROFILES = ('zero', 'note', 'chord', 'volume', 'pitch', 'kick', 'snare')

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, help='explicit verified FTDI COM port, e.g. COM8')
    parser.add_argument('--device-id', type=int, required=True, help='explicit currently enumerated USB-Audio WinMM input ID')
    parser.add_argument('--output-root', type=Path, default=Path(r'D:\Gowin_project\乐器版本\测量记录'))
    parser.add_argument('--manifest', type=Path, default=HERE.parent/'版本信息.json')
    parser.add_argument('--profiles', default=','.join(PROFILES))
    parser.add_argument('--plan-only', action='store_true', help='print plan; no JTAG, serial or audio-device access')
    args = parser.parse_args(argv)
    profiles = [x.strip() for x in args.profiles.split(',') if x.strip()]
    if not profiles or len(profiles) != len(set(profiles)) or any(p not in PROFILES for p in profiles):
        parser.error('profiles must be a non-repeated selection from '+','.join(PROFILES))
    from remote_control import parser as control_parser, validate
    validate(control_parser().parse_args(['status', '--port', args.port]))
    if args.device_id < 0:
        parser.error('device-id must be non-negative')
    plan = {'profiles': profiles, 'wav_seconds_each': 8, 'programming_performed': False,
            'formal_competition_compliance': False, 'requires_firmware_readback': True,
            'serial_port': args.port, 'audio_device_id': args.device_id}
    if args.plan_only:
        print(json.dumps(plan, ensure_ascii=True, indent=2))
        return 0
    if not args.manifest.is_file():
        parser.error('release manifest missing; use the packaged tool after programming its firmware')
    if not args.output_root.is_dir():
        parser.error('output-root must already exist')
    stamp = datetime.now(timezone(timedelta(hours=8))).strftime('%Y-%m-%d_%H%M%S_%f')
    folder = args.output_root / (stamp+'_虚拟输入音频验收')
    folder.mkdir(exist_ok=False)
    env = os.environ.copy();env['PYTHONIOENCODING']='utf-8'
    report = {'plan': plan, 'folder': str(folder), 'captures': [], 'status': 'inconclusive',
              'physical_sensors_verified': False, 'real_audio_recorded': False}
    baseline = None
    try:
        probe = subprocess.run([sys.executable, str(HERE/'verify_firmware.py'), '--manifest', str(args.manifest),
                                '--output', str(folder/'烧录版本回读.json')], capture_output=True, timeout=20, env=env)
        if probe.returncode:
            raise RuntimeError('FPGA UserCode was not independently verified; no virtual inputs or recording started')
        for profile in profiles:
            print('TEST '+profile, flush=True)
            before = set(folder.glob('*.run.json'))
            result = subprocess.run([sys.executable, str(HERE/'run_remote_capture.py'),
                '--port', args.port, '--device-id', str(args.device_id), '--profile', profile,
                '--output-dir', str(folder)], capture_output=True, timeout=40, env=env)
            created = set(folder.glob('*.run.json'))-before
            if result.returncode or len(created) != 1:
                raise RuntimeError(profile+' capture/control failed: '+(result.stdout+result.stderr).decode('utf-8',errors='replace')[-3000:])
            run_path = created.pop()
            run = json.loads(run_path.read_text(encoding='utf-8'))
            if run.get('success') is not True or run.get('release_ack_verified') is not True:
                raise RuntimeError(profile+' lacked confirmed completion and release')
            wav = Path(run['wav'])
            from evaluate_capture import evaluate_capture
            assessment = evaluate_capture(wav, profile, baseline=baseline, run_json=run_path)
            assessment_path = wav.with_suffix('.evaluation.json')
            with assessment_path.open('x', encoding='utf-8') as output:
                json.dump(assessment, output, ensure_ascii=False, indent=2, allow_nan=False)
            report['captures'].append({'profile': profile, 'wav': str(wav), 'evaluation': str(assessment_path),
                                       'status': assessment['status'], 'summary': assessment['summary']})
            report['real_audio_recorded'] = True
            if profile == 'zero':baseline = wav
            print(assessment['summary'], flush=True)
        decisive = [c['status'] for c in report['captures'] if c['profile'] != 'zero']
        report['status'] = ('fail' if 'fail' in decisive else 'inconclusive'
                            if not decisive or 'inconclusive' in decisive else 'pass')
        report['zero_note'] = 'zero is an analog-noise observation, excluded from the functional aggregate; it does not prove competition compliance or physical-sensor performance'
    except Exception as exc:
        report['error'] = str(exc);report['status']='inconclusive'
    finally:
        report['finished_local'] = datetime.now(timezone(timedelta(hours=8))).isoformat()
        (folder/'验收汇总.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
        rows = [f"{c['profile']}: {c['summary']}" for c in report['captures']]
        (folder/'验收摘要.txt').write_text('项目功能结果：'+report['status']+'\n'+
            '\n'.join(rows)+'\n'+report.get('error','')+
            '\n仅项目参考指标，不代表官方竞赛合规。此次输入由软件注入，未验证实体传感器接触与标定。\n',encoding='utf-8')
    print(json.dumps({'status':report['status'],'folder':str(folder)},ensure_ascii=True))
    return {'pass':0,'fail':1,'inconclusive':2}[report['status']]

if __name__=='__main__':
    raise SystemExit(main())
