"""只枚举当前音频输入，不打开或开始录音。"""
from pathlib import Path
import sys,json
sys.path.insert(0,str(Path(__file__).resolve().parent/'support'))
from audio_devices import enumerate_devices
print(json.dumps(enumerate_devices(),ensure_ascii=True,indent=2))
