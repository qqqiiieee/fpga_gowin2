#!/usr/bin/env bash
# Run in the Codex CLOUD environment, never as a request to install locally.
set -euo pipefail
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
if ! command -v iverilog >/dev/null || ! command -v vvp >/dev/null || ! python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then
  if [[ "$(id -u)" == 0 ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iverilog python3-venv python3-pip
  else
    sudo -n apt-get update
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iverilog python3-venv python3-pip
  fi
fi
python3 -m venv .venv
.venv/bin/python -m pip install --disable-pip-version-check -r requirements-cloud.txt
mkdir -p validation
.venv/bin/python cloud/run_checks.py --static
printf '%s\n' 'Cloud dependencies prepared. Run .venv/bin/python cloud/run_checks.py --suite full to validate RTL.'
