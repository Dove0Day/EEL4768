#!/usr/bin/env bash
# Formal self-check for graded riscv_fv.v (fixed riscv_fv.sby for everyone).
#
# Usage:
#   ./run.sh /path/to/your/submission/root
#
# Expects at that root (same names the .sby lists):
#   riscv_fv.v
#   cdb_arb.v
#   rat.v
#
# Requires OSS CAD Suite (sby) on PATH.
set -euo pipefail

EX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="${1:-}"

if [[ -z "${SUB_DIR}" ]]; then
  echo "Usage: $0 /path/to/your/submission/root" >&2
  echo "  Required at that root: riscv_fv.v cdb_arb.v rat.v" >&2
  exit 2
fi
SUB_DIR="$(cd "${SUB_DIR}" && pwd)"

if ! command -v sby >/dev/null 2>&1; then
  echo "ERROR: sby not on PATH. Install OSS CAD Suite (see documentation/phase_7.pdf § Formal Verification)." >&2
  exit 1
fi

for f in riscv_fv.v cdb_arb.v rat.v; do
  [[ -f "${SUB_DIR}/${f}" ]] || { echo "ERROR: missing ${SUB_DIR}/${f}" >&2; exit 1; }
done

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/riscv_fv.XXXXXX")"
cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

cp "${EX_DIR}/riscv_fv.sby" "${STAGE}/"
cp "${SUB_DIR}/riscv_fv.v"  "${STAGE}/"
cp "${SUB_DIR}/cdb_arb.v"   "${STAGE}/"
cp "${SUB_DIR}/rat.v"       "${STAGE}/"

cd "${STAGE}"
sby -f riscv_fv.sby
