#!/usr/bin/env bash
# fm-bead-overdue-check.sh - wake firstmate when a shared-board bead outlives
# its expected duration.
#
# Behavior:
#   - no config/beads-board in this home: exit 0, emit nothing, run no bd.
#   - list open in_progress beads (age from the bead's updated_at start mark,
#     which bin/fm-spawn.sh stamps when it dispatches the linked task) and
#     minutes from an `eta:<N>m|eta:<N>h` label, then this home's
#     config/bead-eta-defaults table keyed by label then issue_type, then the
#     fallback (bin/fm-bead-eta-lib.sh owns resolution and the `key=minutes`
#     syntax).
#   - print ONE wake line per threshold crossing per bead, deduped in
#     state/.bead-overdue-seen/: `overdue:` at 1x the expectation and
#     `escalate:` at 2x. The watcher turns each printed line into a `check:`
#     wake for this home's session. Quiet otherwise.
#
# Run shapes:
#   bin/fm-bead-overdue-check.sh            one poll (custom watcher check)
#   bin/fm-bead-overdue-check.sh install    copy this script to
#       state/bead-overdue.check.sh and hash-bind it with
#       bin/fm-check-register.sh, so the home's watcher polls it directly
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
# shellcheck source=bin/fm-bead-board-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-bead-board-lib.sh"
# shellcheck source=bin/fm-bead-eta-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-bead-eta-lib.sh"

fail() {
  printf 'fm-bead-overdue-check: %s\n' "$*" >&2
  exit 1
}

install_check() {
  local check="$STATE/bead-overdue.check.sh"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  cp "$SCRIPT_DIR/fm-bead-overdue-check.sh" "$check" \
    || fail "could not write $check"
  chmod 0700 "$check" || fail "could not set $check executable"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-register.sh" bead-overdue \
    || fail "could not hash-bind the installed check; remove $check and retry"
  printf 'installed: %s (hash-bound; the watcher polls it on its check cadence)\n' "$check"
}

case "${1:-}" in
  '') : ;;
  install) install_check; exit 0 ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *)
    printf 'usage: fm-bead-overdue-check.sh [install]\n' >&2
    exit 2
    ;;
esac

# Overdue polling is silent for an unjoined home: no board, no bd at all.
fm_bead_eta_poll_overdue "$STATE"

exit 0
