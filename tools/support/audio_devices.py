"""WinMM 输入枚举；没有打开音频设备、设置增益或录音的功能。"""
import ctypes
from ctypes import wintypes
import sys


class WAVEINCAPSW(ctypes.Structure):
    # 必须采用 Windows 原生字段宽度；不能用 Python int 或 c_long 代替指针。
    _fields_ = [("wMid", wintypes.WORD), ("wPid", wintypes.WORD),
        ("vDriverVersion", wintypes.DWORD), ("szPname", wintypes.WCHAR*32),
        ("dwFormats", wintypes.DWORD), ("wChannels", wintypes.WORD),
        ("wReserved1", wintypes.WORD)]


def enumerate_devices():
    """返回当前 WinMM ID、名称和通道数；ID 变化后调用者必须重新选择。"""
    if sys.platform != 'win32':
        raise OSError('WinMM input enumeration requires Windows')
    mm = ctypes.WinDLL('winmm', use_last_error=True)
    mm.waveInGetNumDevs.argtypes=[]
    mm.waveInGetNumDevs.restype=wintypes.UINT
    mm.waveInGetDevCapsW.argtypes=[ctypes.c_size_t,ctypes.POINTER(WAVEINCAPSW),wintypes.UINT]
    mm.waveInGetDevCapsW.restype=wintypes.UINT
    result=[]
    for device_id in range(mm.waveInGetNumDevs()):
        caps=WAVEINCAPSW()
        code=mm.waveInGetDevCapsW(device_id,ctypes.byref(caps),ctypes.sizeof(caps))
        if code:
            # 保留真实 ID，不重排或用默认麦克风替代一个查询失败的设备。
            continue
        result.append({'id':device_id,'name':caps.szPname,'channels':int(caps.wChannels)})
    return result
