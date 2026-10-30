#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v iverilog >/dev/null; then
  if [ "$(id -u)" = 0 ]; then apt-get update && apt-get install -y iverilog python3-venv; else sudo -n apt-get update && sudo -n apt-get install -y iverilog python3-venv; fi
fi
python3 -m venv .venv
.venv/bin/python -m pip install --disable-pip-version-check -r requirements-cloud.txt
