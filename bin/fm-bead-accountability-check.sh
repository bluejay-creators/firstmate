#!/usr/bin/env bash
# fm-bead-accountability-check.sh - board ownership, graph, progress and ETA check.
#
# Usage: fm-bead-accountability-check.sh [install]
# Polls config/beads-board through fm_bead_accountability.py and the existing
# readonly Beads interfaces. Reports findings, never dispatches or assigns work.
# Missed structured commitments reach this home's existing Inbox once per
# commitment; owner-authored revisions remain in bead metadata, not the Inbox.
# Register in the board's owning home only, not in every joined mate home.
# install copies this check to state/bead-accountability.check.sh and registers
# its exact bytes with fm-check-register.sh. Activation is a separate approval.
# Retire the older private bead-ready check when activating this replacement;
# captain duration expectations remain owned by fm-bead-overdue-check.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"

case "${1:-}" in
  '') ;;
  install)
    if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
      printf 'bead-accountability: state directory is unavailable\n' >&2
      exit 1
    fi
    check="$STATE/bead-accountability.check.sh"
    cp "$SCRIPT_DIR/fm-bead-accountability-check.sh" "$check"
    chmod 0700 "$check"
    FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-check-register.sh" bead-accountability
    printf 'installed: %s (hash-bound; not a worker dispatcher)\n' "$check"
    exit 0
    ;;
  -h|--help)
    printf 'usage: fm-bead-accountability-check.sh [install]\n'
    exit 0
    ;;
  *)
    printf 'usage: fm-bead-accountability-check.sh [install]\n' >&2
    exit 2
    ;;
esac
exec python3 "$FM_ROOT/bin/fm_bead_accountability.py" check --home "$FM_HOME"
