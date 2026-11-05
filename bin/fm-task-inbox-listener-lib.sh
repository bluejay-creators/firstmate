#!/usr/bin/env bash
# fm-task-inbox-listener-lib.sh - the shell-side half of the in-session
# steering-inbox listener for omp workers (.omp/extensions/fm-inbox-listener.ts).
#
# One question answered here: does <record-dir> (an inbox directory holding
# NNN.msg records) have a LIVE listener, so the doorbell line must NOT be
# typed into its pane? bin/fm-task-inbox-lib.sh owns the doorbell and re-ring
# ladder contract this check tempers; it calls this library before every ring
# and before every escalation vote so a live-listener pane is never typed
# into, while a stale or absent heartbeat falls straight back to the
# doorbell path unchanged.
#
# Heartbeat contract (the extension owns the write side):
#   <inbox-dir>/.listener   "<pid>\t<epoch-ms>", rewritten every
#                           FM_INBOX_LISTENER_HEARTBEAT_MS on the extension
#                           side and removed at session_shutdown
# Live means ALL of:
#   - the file's age is under FM_INBOX_LISTENER_STALE_SECS (default 30)
#   - its recorded pid exists on this host
# The pid check also refuses a heartbeat left by a dead process (an
# ungraceful exit cannot remove its own heartbeat). A record written for a
# home-private peers inbox (state/peers/peers.sh) uses the exact same file
# name and verdict, so peers' tracked half is simply this same call.
# fm-send's fire-and-forget retry marking treats listener-live like a
# successful ring: the listener owns delivery while it lives, so no retry is
# owed for a ring that was deliberately not typed.
#
# Source-only; no side effects. Dependency-light (no backend dispatch).
# Bash 3.2 compatible.
#
# Tunables (env):
#   FM_INBOX_LISTENER_STALE_SECS  default 30; heartbeat freshness tolerance

fm_task_inbox_listener_stale_secs() {
  local s=${FM_INBOX_LISTENER_STALE_SECS:-30}
  case "$s" in ''|*[!0-9]*) s=30 ;; esac
  printf '%s' "$s"
}

# 0 when the inbox directory containing <record-path> has a live in-session
# listener; 1 otherwise (absent, stale, unreadable, or dead-pid heartbeat).
fm_task_inbox_listener_live() {  # <record-path-or-inbox-dir>
  local target=${1-} dir hb age pid
  [ -n "$target" ] || return 1
  case "$target" in
    *.msg) dir=${target%/*} ;;
    *) dir=$target ;;
  esac
  hb=$dir/.listener
  [ -f "$hb" ] || return 1
  age=$(fm_path_age "$hb" 2>/dev/null) || return 1
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age" -lt "$(fm_task_inbox_listener_stale_secs)" ] || return 1
  pid=$(awk -F '\t' '{print $1; exit}' "$hb" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  return 0
}
