"""Optional local tool adapter; dependencies stay under this test directory.

Install: python -m pip install --target tests/custom_score/tool_deps yowasp-yosys
Used only when --yosys is requested; no system PATH/configuration changes.
"""
import os
from pathlib import Path
import struct
import sys

os.environ.setdefault('PROCESSOR_ARCHITECTURE', 'AMD64' if struct.calcsize('P')==8 else 'x86')
sys.path.insert(0, str(Path(__file__).resolve().parent/'tool_deps'))
import yowasp_yosys

raise SystemExit(yowasp_yosys.run_yosys(sys.argv[1:]))
