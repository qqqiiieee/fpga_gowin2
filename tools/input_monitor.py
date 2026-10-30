"""V019只读输入监视：通过既有09诊断帧读取触摸/MIDI/光束，不接管演奏。"""
import argparse
import json
import time
import sys
from pathlib import Path
from touch_calibrate import DiagnosticClient,configured_port,open_serial,list_ports

ROOT=Path(__file__).resolve().parents[1]

def decode(reply):
    flags=reply.diag2
    return {'touch_raw':reply.touch_raw,'touch_keys':f'0x{reply.touch_keys:04X}',
            'touch_valid':bool(flags&1),'touch_fault':bool(flags&2),
            'midi_seen_or_held':bool(flags&4),'midi_frame_error':bool(flags&8),
            'beam_a_blocked':bool(flags&16),'beam_b_blocked':bool(flags&32),
            'midi_overflow':bool(flags&64),'optical_ready':bool(flags&128),
            'strum_busy':bool(flags&256),'touch_sample_sequence':reply.diag3}

def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port');parser.add_argument('--list',action='store_true')
    parser.add_argument('--count',type=int,default=0);parser.add_argument('--interval',type=float,default=0.1)
    parser.add_argument('--json',action='store_true',help='输出机器可读JSON；默认中文状态行')
    args=parser.parse_args(argv)
    if args.list:print(json.dumps(list_ports(),ensure_ascii=False,indent=2));return 0
    if args.count<0 or not .02<=args.interval<=10:parser.error('count>=0; interval=0.02..10s')
    serial=open_serial(args.port or configured_port(ROOT/'device_config.json'),.8)
    try:
        client=DiagnosticClient(serial,.8);number=0
        while not args.count or number<args.count:
            state=decode(client.query())
            if args.json:line=json.dumps(state,ensure_ascii=False)
            else:
                line=(f'触摸raw={state["touch_raw"]:4d} 键={state["touch_keys"]} '
                      f'故障={int(state["touch_fault"])} | MIDI有数据/按住={int(state["midi_seen_or_held"])} '
                      f'帧错={int(state["midi_frame_error"])} 溢出={int(state["midi_overflow"])} | '
                      f'光束A={"遮挡" if state["beam_a_blocked"] else "通光"} '
                      f'B={"遮挡" if state["beam_b_blocked"] else "通光"} '
                      f'就绪={int(state["optical_ready"])} 扫弦中={int(state["strum_busy"])}')
            print(line,flush=True)
            number+=1;time.sleep(args.interval)
    except KeyboardInterrupt:return 0
    finally:serial.close()
    return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,RuntimeError) as exc:
        print('读取输入失败：'+str(exc),file=sys.stderr);raise SystemExit(1)
