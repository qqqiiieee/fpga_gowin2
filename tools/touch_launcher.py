"""双击入口的薄包装：监视只读；标定由用户逐键采集后应用，不负责烧录。"""
from pathlib import Path
from datetime import datetime
import sys
from touch_calibrate import main

if __name__=='__main__':
    mode=sys.argv[1] if len(sys.argv)>1 else 'monitor'
    root=Path(__file__).resolve().parents[1]
    if mode=='calibrate':
        destination=root.parent/'标定记录'/datetime.now().strftime('%Y-%m-%d_%H%M%S')
        sys.argv=[sys.argv[0],'calibrate','--output-dir',str(destination),'--apply']
    else:
        sys.argv=[sys.argv[0],'monitor']
    raise SystemExit(main())
