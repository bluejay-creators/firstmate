#!/usr/bin/env bash
# Public CLI fixtures only; no live harness, credentials or notification effects.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 "$ROOT/tests/fm-prompt-shadow.test.py"
pass 'shadow prompt classifier, correlation, stall routing and resolution fixtures'
