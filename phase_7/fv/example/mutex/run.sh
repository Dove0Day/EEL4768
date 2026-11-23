#!/usr/bin/env bash
# Run the mutex SymbiYosys example. Requires OSS CAD Suite on PATH.
set -euo pipefail

JOB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v sby >/dev/null 2>&1; then
  echo "ERROR: sby not on PATH. Install OSS CAD Suite and put bin/ first." >&2
  echo "  See documentation/phase_7.pdf (Formal Verification)." >&2
  exit 1
fi

cd "${JOB_DIR}"
exec sby -f mutex.sby
