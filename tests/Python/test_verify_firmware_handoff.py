"""工具构造的命令必须只读且匹配下载线；不打开任何真实设备。"""
from pathlib import Path
import contextlib, io, importlib.util, json, hashlib, tempfile, unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('handoff_verify',ROOT/'tools/verify_firmware.py')
verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)
class VerifyReadback(unittest.TestCase):
    def check_read(self,extra,expected_index,location=None,reply='0x00001234'):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder);fw=p/'test.fs';fw.write_bytes(b'fixture')
            manifest=p/'manifest.json';manifest.write_text(json.dumps({'firmware_name':fw.name,'sha256':hashlib.sha256(fw.read_bytes()).hexdigest(),'usercode':'0x00001234'}),encoding='utf-8')
            output=p/'result.json'
            response=type('Result',(),{'returncode':0,'stdout':f'User Code is: {reply}'.encode(),'stderr':b''})()
            with patch.object(verify.subprocess,'run',return_value=response) as run,contextlib.redirect_stdout(io.StringIO()):
                code=verify.main(['--manifest',str(manifest),'--output',str(output),*extra])
            cmd=run.call_args.args[0]
            self.assertEqual(cmd[cmd.index('--run')+1],'73')
            self.assertNotIn('--fsFile',cmd)
            self.assertEqual(cmd[cmd.index('--cable-index')+1],str(expected_index))
            if location is None:self.assertNotIn('--location',cmd)
            else:self.assertEqual(cmd[cmd.index('--location')+1],str(location))
            self.assertEqual(code,0 if reply=='0x00001234' else 1)
            self.assertEqual(json.loads(output.read_text())['verified'],reply=='0x00001234')
    def test_usb_debugger_a(self):self.check_read([],4)
    def test_location_zero(self):self.check_read(['--cable-index','4','--location','0'],4,0)
    def test_other_cable_explicit(self):self.check_read(['--cable-index','1','--location','8721'],1,8721)
    def test_invalid_all_ones_rejected(self):self.check_read([],4,reply='0xFFFFFFFF')
if __name__=='__main__':unittest.main()
