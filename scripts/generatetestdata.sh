#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 1
fi

if [[ ! -d "${ROOT}/.venv-generate" ]]; then
  python3 -m venv "${ROOT}/.venv-generate"
fi
# shellcheck source=/dev/null
source "${ROOT}/.venv-generate/bin/activate"
pip install -q -r "${ROOT}/requirements-dev.txt"

python3 "${ROOT}/scripts/generate_test_pdfs.py"
echo "Done. PDFs are in fixtures/generated/"
