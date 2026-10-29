"""Portable cloud checks; no serial port, audio-device, JTAG or FPGA access.

--static is intentionally cheap and can be used during packaging. A simulation
suite only runs when explicitly selected. Reports retain command output and
return codes; successful setup is separate from a passing RTL regression.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse, ast, hashlib, json, os, re, shutil, subprocess, sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

def static_check():
    project=ET.parse(ROOT/'instrument_handoff.gprj')
    files=[e.attrib['path'] for e in project.iter('File')]
    missing=[p for p in files if not (ROOT/p).is_file()]
    if missing: raise RuntimeError('Missing GPRJ sources: '+str(missing))
    cst=(ROOT/'src/multi_tone.cst').read_text(encoding='utf-8-sig')
    required={'midi_rx':'T8','optical_beams[0]':'P8','optical_beams[1]':'P9',
              'touch_sclk':'T6','touch_mosi':'P6','touch_miso':'R8','touch_cs_n':'T7',
              'adc_scl':'D14','adc_sda':'E15','matrix_rows[1]':'M14','matrix_rows[2]':'T12'}
    for net,pin in required.items():
        if not re.search(r'IO_LOC\s+"'+re.escape(net)+r'"\s+'+pin+r'\s*;',cst):
            raise RuntimeError('Pin contract changed: '+net)
    parsed=0
    for directory in ['scripts','tools','cloud']:
        for p in (ROOT/directory).rglob('*.py'):
            if '__pycache__' in p.parts or 'vendor' in p.parts:continue
            ast.parse(p.read_text(encoding='utf-8-sig'),filename=str(p));parsed+=1
    # Imported hashes provide provenance. Cloud runs should compare their own
    # current source hashes rather than call the old release a new measurement.
    manifest=json.loads((ROOT/'verification/cloud_import.json').read_text(encoding='utf-8'))
    fw=ROOT/'instrument_v020.fs'
    if hashlib.sha256(fw.read_bytes()).hexdigest()!=manifest['firmware_sha256']:
        raise RuntimeError('Reference firmware hash differs from imported V020')
    return {'status':'pass','gprj_sources_present':len(files),'python_files_parsed':parsed,
            'pin_contracts_checked':len(required),'reference_firmware_verified':True,
            'simulation_run':False,'hardware_tested':False,'platform':sys.platform}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--static',action='store_true')
    parser.add_argument('--suite',choices=['smoke','full'])
    parser.add_argument('--list',action='store_true')
    args=parser.parse_args()
    py=sys.executable
    smoke=[['scripts/run_midi_tests.py','--case','tb_midi_uart_rx','--workers','1'],
           ['scripts/run_optical_tests.py','--workers','2']]
    full=[['scripts/run_midi_tests.py','--workers','2'],
          ['scripts/run_optical_tests.py','--workers','2'],
          ['scripts/run_touch_unit_tests.py','--workers','2'],
          ['scripts/run_pressure_expression_tests.py','--jobs','2'],
          ['scripts/run_iverilog_tests.py','--tests','tb_fsr_expression_integration',
           '--jobs','1','--timeout','600']]
    commands=full if args.suite=='full' else smoke
    if args.list:
        print(json.dumps(commands,ensure_ascii=False,indent=2));return 0
    if not args.static and not args.suite:
        parser.error('Select --static or --suite smoke/full; simulation is never implicit')
    output=ROOT/'validation/cloud'
    output.mkdir(parents=True,exist_ok=True)
    report={'started_utc':datetime.now(timezone.utc).isoformat(),'static':static_check(),
            'suite':args.suite,'commands':[],'status':'pass','hardware_tested':False,
            'gowin_build_performed':False,'programming_performed':False}
    if args.suite:
        for tool in ['iverilog','vvp']:
            resolved=shutil.which(tool)
            if not resolved:raise RuntimeError(tool+' not available; run cloud/setup.sh in the cloud')
            report[tool]={'path':resolved,'sha256':hashlib.sha256(Path(resolved).read_bytes()).hexdigest()}
        for index,argv in enumerate(commands):
            cmd=[py,*argv]
            print('CLOUD_CHECK '+argv[0],flush=True)
            record={'argv':cmd,'cwd':str(ROOT),'returncode':None}
            try:
                result=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True,
                    encoding='utf-8',errors='replace',timeout=1800,
                    env={**os.environ,'PYTHONIOENCODING':'utf-8'})
                record.update(returncode=result.returncode,stdout=result.stdout,stderr=result.stderr)
            except (subprocess.TimeoutExpired,OSError) as exc:
                record['error']=str(exc)
            (output/f'{index+1:02d}_{Path(argv[0]).stem}.json').write_text(
                json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
            report['commands'].append({'argv':cmd,'returncode':record['returncode']})
            if record['returncode']!=0:
                report['status']='fail';print(record.get('stderr','')[-3000:])
                print(record.get('stdout','')[-3000:]);break
    report['finished_utc']=datetime.now(timezone.utc).isoformat()
    (output/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=True,indent=2))
    return 0 if report['status']=='pass' else 1

if __name__=='__main__':raise SystemExit(main())
