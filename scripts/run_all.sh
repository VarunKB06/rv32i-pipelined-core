#!/usr/bin/env bash
# Self-test the Python tools, then run the full regression. Extra args go to run_regression.py.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/rv32.py --selftest
python3 tools/run_regression.py "$@"
