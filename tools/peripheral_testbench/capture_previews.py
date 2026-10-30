"""开发验收：仅操作自身的模拟Tk窗口，使用Windows自带绘图库留存截图。"""
import os
from pathlib import Path
import subprocess
import sys
import time
import tkinter as tk
from unittest.mock import Mock

sys.dont_write_bytecode = True
PACKAGE = Path(__file__).resolve().parent
sys.path.insert(0, str(PACKAGE.parent))
from peripheral_testbench import cli
from peripheral_testbench.gui import TestbenchApp


def pump(root, predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        root.update()
        time.sleep(0.01)
    if not predicate():
        raise AssertionError("GUI preview timeout")


def capture(root, path):
    root.update()
    env = dict(os.environ)
    for name, value in {"HWND": root.winfo_id(), "PATH": str(path)}.items():
        env["TESTBENCH_CAPTURE_" + name] = str(value)
    code = """Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CaptureWindow {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L,T,R,B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,int flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
}
'@
[void][CaptureWindow]::SetProcessDPIAware()
$h = [CaptureWindow]::GetAncestor([IntPtr][long]$env:TESTBENCH_CAPTURE_HWND,2)
$rect = [CaptureWindow+Rect]::new()
[void][CaptureWindow]::GetWindowRect($h,[ref]$rect)
$bitmap = [System.Drawing.Bitmap]::new($rect.R-$rect.L, $rect.B-$rect.T)
$g = [System.Drawing.Graphics]::FromImage($bitmap)
$g.CopyFromScreen($rect.L, $rect.T, 0, 0, $bitmap.Size)
$bitmap.Save($env:TESTBENCH_CAPTURE_PATH, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bitmap.Dispose()
"""
    subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", code],
                   check=True, env=env, creationflags=subprocess.CREATE_NO_WINDOW, capture_output=True)


def main():
    output = PACKAGE / "validation" / "screenshots"
    output.mkdir(parents=True, exist_ok=True)
    forbidden = Mock(side_effect=AssertionError("real serial access is forbidden"))
    for tool, capability, filename in (("touch", False, "电容_模拟.png"),
                                        ("beam", False, "光束_V021_无真实电平.png"),
                                        ("beam", True, "光束_新版_真实电平.png")):
        args = cli.parser().parse_args(["--tool", tool, "--simulate", "--samples", "3",
            "--interval", "0.05", "--output", str(PACKAGE / "validation" / "preview_reports")]
            + (["--raw-capability"] if capability else []))
        root = tk.Tk()
        root.geometry("1100x880+30+30")
        app = TestbenchApp(root, args, factory=forbidden, enumerate_fn=forbidden)
        root.geometry("1100x880+30+30")
        app.connect()
        pump(root, lambda: app.last_frame is not None)
        app.capture()
        pump(root, lambda: len(app.test.results) == 1)
        app.peer.set_stage("touch4" if tool == "touch" else "a")
        count = len(app.peer.requests)
        pump(root, lambda: len(app.peer.requests) > count + 2)
        root.update()
        capture(root, output / filename)
        if tool == "touch":
            app.pause_polling()
            pump(root, lambda: app.pause_confirmed)
            started = time.monotonic()
            pump(root, lambda: time.monotonic() - started > 1.1)
            capture(root, output / "停止轮询_保持连接_一秒提示.png")
        app.close()
        pump(root, lambda: app.worker is None)
    forbidden.assert_not_called()
    print("Captured 4 offline GUI previews:", output)


if __name__ == "__main__":
    main()
