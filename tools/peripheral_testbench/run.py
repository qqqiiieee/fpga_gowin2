"""绝对路径/双击入口，独立交付和工程内使用同一份代码。"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from peripheral_testbench.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
