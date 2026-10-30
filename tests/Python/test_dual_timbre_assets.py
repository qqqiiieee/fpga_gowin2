"""生产两音色资产的独立选择、重建与失效保护测试，不访问板卡。"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class DualTimbreAssets(unittest.TestCase):
    def words(self, path):
        return [int(x, 16) for x in path.read_text(encoding='ascii').split()]

    def test_selected_banks_preserve_exact_samples(self):
        original = self.words(ROOT/'src/timbre_soft.hex')
        selected = self.words(ROOT/'src/timbre_dual.hex')
        self.assertEqual(len(selected), 2048)
        self.assertEqual(selected, original[1024:2048] + original[7168:8192])

    def test_all_compact_samples_reconstruct(self):
        original = self.words(ROOT/'src/timbre_dual.hex')
        half = self.words(ROOT/'src/timbre_dual_half.hex')
        self.assertEqual(len(half), 1024)
        decoded=[]
        for bank in range(2):
            for index in range(1024):
                pos=((-index)&511) if index>=512 else index
                word=half[bank*512+pos]
                decoded.append((-word)&65535 if index>=512 else word)
        self.assertEqual(decoded, original)

    def fixture(self):
        temp=tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root=Path(temp.name)
        for name in ['scripts','src','assets']:
            (root/name).mkdir()
        for name in ['generate_dual_timbres.py','generate_odd_half_rom.py']:
            shutil.copy2(ROOT/'scripts'/name, root/'scripts'/name)
        for name in ['timbre_soft.hex','timbre_dual.hex','timbre_dual_half.hex']:
            shutil.copy2(ROOT/'src'/name,root/'src'/name)
        shutil.copy2(ROOT/'assets/timbres_dual.json',root/'assets/timbres_dual.json')
        return root

    def check(self, root, success, optimized=False):
        before={p.name: p.read_bytes() for p in (root/'src').glob('timbre_dual*.hex')}
        proc=subprocess.run([sys.executable,*(['-O'] if optimized else []),
                             str(root/'scripts/generate_dual_timbres.py'),'--check'],capture_output=True)
        self.assertEqual(proc.returncode==0, success, (proc.stdout+proc.stderr).decode(errors='replace'))
        after={p.name: p.read_bytes() for p in (root/'src').glob('timbre_dual*.hex')}
        self.assertEqual(after,before,'check must never overwrite generated files')

    def test_clean_generated_assets_pass(self):
        self.check(self.fixture(),True)

    def test_corrupted_full_output_is_rejected(self):
        root=self.fixture(); (root/'src/timbre_dual.hex').write_text('0001\n'*2048)
        self.check(root,False)

    def test_corrupted_half_output_is_rejected(self):
        root=self.fixture(); (root/'src/timbre_dual_half.hex').write_text('0001\n'*1024)
        self.check(root,False)

    def test_corrupted_output_is_rejected_with_python_optimization(self):
        root=self.fixture(); (root/'src/timbre_dual_half.hex').write_text('0001\n'*1024)
        self.check(root,False,optimized=True)

    def test_source_hash_drift_is_rejected(self):
        root=self.fixture(); (root/'src/timbre_soft.hex').write_text('0000\n'*16384)
        self.check(root,False)

    def test_wrong_bank_mapping_is_rejected(self):
        root=self.fixture(); p=root/'assets/timbres_dual.json'; data=json.loads(p.read_text(encoding='utf-8'))
        data['timbres'][0]['source_bank']=0
        p.write_text(json.dumps(data),encoding='utf-8'); self.check(root,False)

    def test_wrong_source_length_even_with_updated_hash_is_rejected(self):
        root=self.fixture(); p=root/'src/timbre_soft.hex'; p.write_text('0000\n'*1024)
        m=root/'assets/timbres_dual.json'; data=json.loads(m.read_text(encoding='utf-8'))
        data['source_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
        m.write_text(json.dumps(data),encoding='utf-8'); self.check(root,False)

if __name__=='__main__':
    unittest.main()
