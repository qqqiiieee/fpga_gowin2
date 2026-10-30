"""Locate host Icarus tools without a project-specific installation path.

An explicit directory (when a runner offers --tool-bin) takes precedence over
IVERILOG_BIN; otherwise both iverilog and vvp are discovered on PATH. Nothing
is installed or downloaded. Works with Windows .exe and Unix tool names.
"""
from dataclasses import dataclass
from pathlib import Path
import os
import shutil


class ToolchainError(RuntimeError):
    """A requested host tool could not be found."""


def _names(name):
    return (name + ".exe", name) if os.name == "nt" else (name, name + ".exe")


@dataclass(frozen=True)
class Icarus:
    iverilog: Path
    vvp: Path

    def environment(self):
        """Preserve the caller's environment and expose adjacent tool DLLs."""
        env = os.environ.copy()
        directories = list(dict.fromkeys(str(p.parent) for p in (self.iverilog, self.vvp)))
        env["PATH"] = os.pathsep.join(directories + [env.get("PATH", "")])
        return env

    def as_dict(self):
        return {"iverilog": str(self.iverilog), "vvp": str(self.vvp)}


def find_icarus(tool_bin=None):
    """Return resolved executables; an invalid explicit override fails clearly."""
    override = tool_bin if tool_bin is not None else os.environ.get("IVERILOG_BIN")
    directory = Path(override).expanduser().resolve() if override else None
    found = {}
    for name in ("iverilog", "vvp"):
        if directory is not None:
            candidate = next((directory / n for n in _names(name)
                              if (directory / n).is_file()), None)
        else:
            candidate = next((p for n in _names(name) if (p := shutil.which(n))), None)
        if candidate is None:
            location = str(directory) if directory is not None else "PATH"
            raise ToolchainError(
                f"Missing Icarus tool '{name}' in {location}. Install Icarus Verilog "
                "and add its bin directory to PATH, or set IVERILOG_BIN to the "
                "directory containing both iverilog and vvp. No tools were downloaded."
            )
        found[name] = Path(candidate).resolve()
    return Icarus(**found)
