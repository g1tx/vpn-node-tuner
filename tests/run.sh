#!/usr/bin/env bash
set -euo pipefail
(( EUID == 0 )) || { printf 'Run with sudo: sudo bash tests/run.sh (all kernel commands are simulated).\n' >&2; exit 1; }
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
python3 tests/test_tune.py
exec python3 tests/test_benchmark.py
