"""Read only the existing USB-UART diagnostic reply; never activate virtual ADC."""
from pathlib import Path
import argparse,json,time
from datetime import datetime,timezone,timedelta
from touch_calibrate import DiagnosticClient

def decode(diag2):
    d=diag2>>2
    return dict(enabled=(d>>9)&1,ready=(d>>5)&1,level_A=(d>>7)&1,level_B=(d>>8)&1,
                blocked_A=(d>>2)&1,blocked_B=(d>>3)&1,busy=(d>>6)&1)

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--port');ap.add_argument('--seconds',type=float,default=45);a=ap.parse_args()
    if not 0<a.seconds<=600:ap.error('--seconds must be within 0..600')
    import serial
    from serial.tools import list_ports
    ports=[p.device for p in list_ports.comports() if p.vid==0x0403 and p.pid==0x6010]
    if not a.port and len(ports)!=1:ap.error('Specify --port; detected FTDI ports: '+repr(ports))
    port=a.port or ports[0];events=[];previous=None;start=time.monotonic()
    try:
        with serial.Serial(port,115200,timeout=.05,write_timeout=1) as uart:
            client=DiagnosticClient(uart,timeout=1)
            print('保持无遮挡，然后分别遮挡A、B各约1秒；本工具只读状态，不切STRUM模式。',flush=True)
            while time.monotonic()-start<a.seconds:
                r=client.query();state=decode(r.diag2)
                if state!=previous:
                    event=dict(seconds=round(time.monotonic()-start,3),**state);events.append(event)
                    print(json.dumps(event,ensure_ascii=False),flush=True);previous=state
                time.sleep(.05)
    finally:
        out=Path(__file__).resolve().parents[1]/'validation'
        out.mkdir(exist_ok=True);f=out/('optical_live_'+datetime.now(timezone(timedelta(hours=8))).strftime('%Y%m%d_%H%M%S')+'.json')
        f.write_text(json.dumps(dict(port=port,events=events,write_commands='diagnostic query 0x80 only; no configuration writes'),ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        print('记录：',f,flush=True)
if __name__=='__main__':main()
