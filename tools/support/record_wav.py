"""Optional Windows capture helper. Requires an explicitly chosen WinMM ID.

No packages needed. Capture never starts on import. Duration is limited to
8 seconds by default, at most 40 with explicit --seconds; a supervisor kills
the worker if a driver/cleanup call stalls. Readiness requires input progress.
No device fallback, automatic selection, or overwrite of an existing WAV.
"""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import subprocess
import sys
import time
import wave


class WAVEFORMATEX(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("wFormatTag", wintypes.WORD), ("nChannels", wintypes.WORD),
        ("nSamplesPerSec", wintypes.DWORD), ("nAvgBytesPerSec", wintypes.DWORD),
        ("nBlockAlign", wintypes.WORD), ("wBitsPerSample", wintypes.WORD),
        ("cbSize", wintypes.WORD)]


class WAVEINCAPSW(ctypes.Structure):
    _fields_ = [("wMid", wintypes.WORD), ("wPid", wintypes.WORD),
        ("vDriverVersion", wintypes.DWORD), ("szPname", wintypes.WCHAR * 32),
        ("dwFormats", wintypes.DWORD), ("wChannels", wintypes.WORD),
        ("wReserved1", wintypes.WORD)]

class WAVEHDR(ctypes.Structure):
    _fields_ = [("lpData", ctypes.c_void_p), ("dwBufferLength", wintypes.DWORD),
        ("dwBytesRecorded", wintypes.DWORD), ("dwUser", ctypes.c_size_t),
        ("dwFlags", wintypes.DWORD), ("dwLoops", wintypes.DWORD),
        ("lpNext", ctypes.c_void_p), ("reserved", ctypes.c_size_t)]


class MMTIME(ctypes.Structure):
    _fields_ = [("wType", wintypes.UINT), ("value", wintypes.DWORD),
                ("reserved", wintypes.DWORD)]


def checked_seconds(seconds):
    if not 0.1 <= seconds <= 40.0:
        raise ValueError("seconds must be finite and between 0.1 and 40")
    return seconds


def capture_worker(args) -> None:
    mm = ctypes.WinDLL("winmm", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    mm.waveInGetNumDevs.argtypes = []
    mm.waveInGetNumDevs.restype = wintypes.UINT
    if args.device_id >= mm.waveInGetNumDevs():
        raise RuntimeError("chosen WinMM input ID is no longer present; rerun the probe")
    mm.waveInGetDevCapsW.argtypes = [ctypes.c_size_t, ctypes.POINTER(WAVEINCAPSW), wintypes.UINT]
    mm.waveInGetDevCapsW.restype = wintypes.UINT
    caps = WAVEINCAPSW()
    caps_code = mm.waveInGetDevCapsW(args.device_id, ctypes.byref(caps), ctypes.sizeof(caps))
    if caps_code or caps.szPname != args.device_name:
        raise RuntimeError("chosen input identity changed; capture aborted without fallback")
    mm.waveInGetErrorTextW.argtypes = [wintypes.UINT, wintypes.LPWSTR, wintypes.UINT]
    mm.waveInGetErrorTextW.restype = wintypes.UINT
    mm.waveInOpen.argtypes = [ctypes.POINTER(wintypes.HANDLE), wintypes.UINT,
        ctypes.POINTER(WAVEFORMATEX), ctypes.c_size_t, ctypes.c_size_t, wintypes.DWORD]
    mm.waveInOpen.restype = wintypes.UINT
    mm.waveInGetPosition.argtypes = [wintypes.HANDLE, ctypes.POINTER(MMTIME), wintypes.UINT]
    mm.waveInGetPosition.restype = wintypes.UINT
    for name in ("waveInPrepareHeader", "waveInAddBuffer", "waveInUnprepareHeader"):
        function = getattr(mm, name)
        function.argtypes = [wintypes.HANDLE, ctypes.POINTER(WAVEHDR), wintypes.UINT]
        function.restype = wintypes.UINT
    for name in ("waveInStart", "waveInReset", "waveInClose"):
        function = getattr(mm, name)
        function.argtypes = [wintypes.HANDLE]
        function.restype = wintypes.UINT
    kernel.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
    kernel.CreateEventW.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL

    def check(result, operation):
        if result:
            text = ctypes.create_unicode_buffer(256)
            mm.waveInGetErrorTextW(result, text, len(text))
            raise RuntimeError(f"{operation}: MMRESULT {result}: {text.value}")

    frames = int(args.rate * args.seconds)
    align = args.channels * 2
    pcm_format = WAVEFORMATEX(1, args.channels, args.rate, args.rate * align, align, 16, 0)
    buffer = ctypes.create_string_buffer(frames * align)
    header = WAVEHDR()
    header.lpData = ctypes.cast(buffer, ctypes.c_void_p).value
    header.dwBufferLength = frames * align
    event = kernel.CreateEventW(None, False, False, None)
    if not event:
        raise ctypes.WinError(ctypes.get_last_error())
    handle = wintypes.HANDLE()
    opened = prepared = False
    pcm = None
    try:
        check(mm.waveInOpen(ctypes.byref(handle), args.device_id,
            ctypes.byref(pcm_format), event, 0, 0x00050000), "waveInOpen")
        opened = True
        check(mm.waveInPrepareHeader(handle, ctypes.byref(header), ctypes.sizeof(header)),
              "waveInPrepareHeader")
        prepared = True
        check(mm.waveInAddBuffer(handle, ctypes.byref(header), ctypes.sizeof(header)),
              "waveInAddBuffer")
        before_start = time.monotonic()
        start_epoch = time.time()
        check(mm.waveInStart(handle), "waveInStart")
        capture_start = time.monotonic()
        if args.ready_file is not None:
            # Successful open/start alone cannot demonstrate that a driver is
            # delivering samples. Fail closed if its byte position stalls.
            progress_deadline = capture_start + min(1.0, args.seconds)
            position = MMTIME(4, 0, 0)  # TIME_BYTES
            while True:
                position.wType = 4
                check(mm.waveInGetPosition(handle, ctypes.byref(position), ctypes.sizeof(position)),
                      "waveInGetPosition")
                if position.wType != 4:
                    raise RuntimeError("input cannot report byte progress; readiness unverified")
                if position.value >= align:
                    break
                if time.monotonic() >= progress_deadline:
                    raise TimeoutError("input started but acquisition progress was not observed")
                time.sleep(.01)
            with args.ready_file.open("x", encoding="utf-8") as ready:
                json.dump({"capture_started_monotonic": capture_start,
                    "capture_started_epoch": start_epoch,
                    "capture_start_before_monotonic": before_start,
                    "wave_start_call_seconds": capture_start-before_start,
                    "acquisition_ready_monotonic": time.monotonic(),
                    "acquisition_progress_bytes": int(position.value),
                    "acquisition_progress_verified": True,
                    "sample_time_calibration": "approximate waveInStart host interval; driver latency uncalibrated",
                    "device_id": args.device_id, "device_name": args.device_name}, ready, ensure_ascii=False)
        deadline = time.monotonic() + args.seconds + 3
        while not header.dwFlags & 1:  # WHDR_DONE; initial open event is not completion.
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("input did not finish the requested capture")
            result = kernel.WaitForSingleObject(event, max(1, min(200, int(remaining * 1000))))
            if result not in (0, 258):  # WAIT_OBJECT_0, WAIT_TIMEOUT
                raise ctypes.WinError(ctypes.get_last_error())
        if header.dwBytesRecorded != frames * align:
            raise RuntimeError("short capture discarded; no complete WAV was saved")
        pcm = buffer.raw[:header.dwBytesRecorded]
    finally:
        if opened:
            mm.waveInReset(handle)
            if prepared:
                mm.waveInUnprepareHeader(handle, ctypes.byref(header), ctypes.sizeof(header))
            mm.waveInClose(handle)
        kernel.CloseHandle(event)
    # Save only after a full capture and cleanup, using exclusive file creation.
    with args.output.open("xb") as output:
        with wave.open(output, "wb") as wav:
            wav.setnchannels(args.channels)
            wav.setsampwidth(2)
            wav.setframerate(args.rate)
            wav.writeframes(pcm)
    print(json.dumps({"saved": str(args.output), "api": "winmm.waveIn",
        "device_id": args.device_id, "rate": args.rate, "channels": args.channels,
        "seconds": frames / args.rate, "pcm_bytes": len(pcm)}))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-id", type=int, required=True,
                        help="explicit WinMM ID from audio_inputs.json, never a sounddevice ID")
    parser.add_argument("--device-name", required=True, help="current exact WinMM input name")
    parser.add_argument("--ready-file", type=Path, help="exclusive JSON file after successful waveInStart")
    parser.add_argument("--output", type=Path, required=True, help="new WAV path; never overwritten")
    parser.add_argument("--seconds", type=float, default=8.0)
    parser.add_argument("--rate", type=int, choices=(8000, 16000, 22050, 44100, 48000), default=44100)
    parser.add_argument("--channels", type=int, choices=(1, 2), default=1)
    parser.add_argument("--_worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if sys.platform != "win32":
        parser.error("this native WinMM helper requires Windows")
    if args.device_id < 0:
        parser.error("device ID must be a nonnegative explicit input ID")
    try:
        checked_seconds(args.seconds)
    except ValueError as exc:
        parser.error(str(exc))
    args.output = args.output.resolve()
    if args.output.exists() or not args.output.parent.is_dir():
        parser.error("output must be a new file inside an existing directory")
    if args.ready_file is not None:
        args.ready_file = args.ready_file.resolve()
        if args.ready_file.exists() or not args.ready_file.parent.is_dir():
            parser.error("ready file must be a new file inside an existing directory")
    if args._worker:
        try:
            capture_worker(args)
            return 0
        except Exception as exc:
            print(f"Capture failed: {exc}", file=sys.stderr)
            return 1
    command = [sys.executable, "-B", str(Path(__file__).resolve()), "--_worker",
        "--device-id", str(args.device_id), "--device-name", args.device_name, "--output", str(args.output),
        "--seconds", str(args.seconds), "--rate", str(args.rate), "--channels", str(args.channels)]
    if args.ready_file is not None:
        command += ["--ready-file", str(args.ready_file)]
    try:
        result = subprocess.run(command, timeout=args.seconds + 10)
        return result.returncode
    except subprocess.TimeoutExpired:
        print("Capture worker exceeded its deadline and was stopped.", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Capture interrupted; worker stopped.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
