#!/usr/bin/env bash
# Real native scheduling and installed phone CLI, never a real pane, Keychain
# item or device. No model tokens; unavailable Mac/GUI surfaces capability-skip.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_WATCHDOG_LAUNCHD_SMOKE python3 launchctl plutil fm-notify-phone
if [ "$(uname)" != Darwin ]; then
  if [ "${FM_WATCHDOG_LAUNCHD_SMOKE:-${FM_LIVE:-0}}" = 1 ]; then
    fail 'native watchdog smoke requires macOS'
  fi
  printf 'skip: live: macOS launchd absent\n'
  exit 0
fi
if ! launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
  if [ "${FM_WATCHDOG_LAUNCHD_SMOKE:-${FM_LIVE:-0}}" = 1 ]; then
    fail 'native watchdog smoke requires a logged-in GUI user domain'
  fi
  printf 'skip: live: GUI user domain absent\n'
  exit 0
fi
bridge=$(type -P fm-notify-phone)
python3 "$ROOT/tests/watchdog-launchd-smoke.py" "$ROOT/bin/fm-watchdog.sh" "$bridge"
