"""Read-only USB/HID inventory for identifying an external screen controller."""
import argparse,json,subprocess
from pathlib import Path
from datetime import datetime,timezone,timedelta
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args()
    command="""[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false);
Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq 'HIDClass' -or $_.Class -eq 'USB' -or $_.InstanceId -like 'USB\\*' } |
Select-Object Status,Class,FriendlyName,InstanceId | ConvertTo-Json -Depth 3 -Compress"""
    result=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',command],capture_output=True,timeout=30)
    if result.returncode:raise SystemExit(result.stderr.decode('utf-8',errors='replace'))
    devices=json.loads(result.stdout.decode('utf-8-sig'))
    if isinstance(devices,dict):devices=[devices]
    candidates=[d for d in devices if any(v in (d.get('FriendlyName') or '').lower() for v in ('touch','digitizer','触摸','触控'))]
    now=datetime.now(timezone(timedelta(hours=8)))
    folder=args.output_dir/('USB触控设备_'+now.strftime('%Y-%m-%d_%H%M%S'));folder.mkdir(parents=True,exist_ok=False)
    report={'checked_local':now.isoformat(),'usb_hid_inventory':devices,'touch_name_candidates':candidates,
            'claim':'Device names are candidates only; VID/PID/report descriptor and screen model still need verification.',
            'hardware_settings_changed':False,'fpga_touch_enabled':False}
    (folder/'USB_HID设备.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'touch_name_candidates':candidates,'report':str(folder/'USB_HID设备.json'),'fpga_touch_enabled':False},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
