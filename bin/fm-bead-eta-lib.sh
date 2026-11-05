#!/usr/bin/env bash
# fm-bead-eta-lib.sh - bead start-time marking and overdue polling for the
# shared captain-bead board (source, never execute directly; requires
# fm-bead-board-lib.sh already sourced and FM_HOME set by the caller).
#
# A home joins by configuring `config/beads-board` (fm-bead-board-lib.sh);
# every helper below is a silent no-op for an unjoined home - no bd call at
# all. The lifecycle mutators never refuse the owning script: they return 0
# on failure so a board outage cannot block a spawn, teardown, or merge.
#
# Clock anchor: fm_bead_mark_in_progress stamps the bead's `updated_at` field
# to the mark time (bd rewrites that field on every update; the appended notes
# line exists only to force the write and record who marked). The overdue poll
# reads `updated_at` as the start time, so a bead the fleet never touched ages
# from its last write. Captain beads count from creation instead: discovery via
# `bd list --status open --label captain` can lag creation by minutes for a
# bead that deep-links against actual creation, so fm_bead_eta_poll_overdue
# anchors `captain`-labelled beads at `created_at`.
#
# ETA resolution (first match wins):
#   1. a carryable `eta:<N>m|eta:<N>h` label on the bead (bd accepts
#      `^eta:[0-9]+[mh]$`);
#   2. `config/bead-eta-defaults`: one `key=minutes` line per kind, matched
#      against the bead's non-eta labels first, then its issue_type;
#   3. fallback 120 minutes.
# An absent config file means every non-labeled bead takes the fallback.
#
# The poll (fm_bead_eta_poll_overdue) prints ONE wake line per threshold
# crossing per bead, deduped in state/.bead-overdue-seen/<bead-id>:
#   crossing 1x the ETA: `overdue: <bead-id> <title> (<age>m/<eta>m), owner <assignee>`
#   crossing 2x the ETA: `escalate: <bead-id> <title> (<age>m/<eta>m), owner <assignee>`
# A bead still open past BOTH thresholds prints its escalate line even when the
# overdue line was never recorded (first sighting after 2x), but a recorded
# escalate suppresses every later crossing. The dedupe record carries the
# anchor epoch; a re-marked bead (the anchor moved) re-arms from level 0. A
# blocked bead's wake line appends `, blocked by <blocker-id> (owner
# <owner>)` - `owner unassigned` when the blocker carries no assignee - for
# the first open blocker whose owner differs from the bead's own.

FM_BEAD_ETA_FALLBACK_MINUTES=120

# Best-effort lifecycle mutators. Each is silent when this home never joined
# the board, the id is missing, or the update fails; the owning script keeps
# its own exit status.
fm_bead_mark_in_progress() { # <bead-id> <task-id>
  local id=$1 task=$2
  [ -n "$id" ] || return 0
  fm_bead_board_ready || return 0
  fm_bead_board_bd update "$id" -s in_progress \
    --notes "$(fm_bead_oneline "firstmate $task marked in_progress")" \
    >/dev/null 2>&1 || return 0
  return 0
}

fm_bead_close_landed() { # <bead-id> <reason>
  local id=$1 reason=$2
  [ -n "$id" ] || return 0
  fm_bead_board_ready || return 0
  fm_bead_board_bd close "$id" -r "$(fm_bead_oneline "landed: $reason")" \
    >/dev/null 2>&1 || return 0
  return 0
}

# Emit one timestamp-anchored start epoch to stdout: captain beads anchor at
# creation, every other bead at its updated_at; empty output when neither
# parses.
fm_bead_eta_start_epoch() { # <created_at> <updated_at> <is_captain:0|1>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
from datetime import datetime, timezone
created, updated, is_captain = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
raw = created if is_captain else (updated or created)
try:
    dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
except ValueError:
    raise SystemExit(0)
if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
PY
}

# Poll open captain beads and open in_progress beads; print deduped wake
# lines per the header. Silent for an unjoined home (no config, broken
# surface) and when bd/python3/jq is absent, so an install on a tool-less
# home stays green; a board read failure on a joined home also stays quiet
# rather than waking - the deps check already covers board health.
fm_bead_eta_poll_overdue() { # <state-dir>
  local state=$1
  fm_bead_board_ready || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  FM_BEAD_BOARD_DIR=$FM_BEAD_BOARD FM_BEAD_ETA_FALLBACK=$FM_BEAD_ETA_FALLBACK_MINUTES \
    python3 - "$state" "$FM_HOME/config/bead-eta-defaults" <<'PY'
import json, os, re, subprocess, sys
from datetime import datetime, timezone

state_dir, defaults_path = sys.argv[1], sys.argv[2]
board = os.environ["FM_BEAD_BOARD_DIR"]
fallback = int(os.environ["FM_BEAD_ETA_FALLBACK"])

def bd(*args):
    try:
        out = subprocess.run(["bd", *args, "--json"], cwd=board,
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except ValueError:
        return None

def parse_ts(raw):
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()

defaults = {}
try:
    with open(defaults_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip()
            if re.fullmatch(r"[A-Za-z0-9_.-]+", key) and val.isdigit():
                defaults[key] = int(val)
except OSError:
    pass

ETA_LABEL = re.compile(r"^eta:(\d+)([mh])$")

def eta_minutes(issue):
    labels = issue.get("labels") or []
    kind = issue.get("issue_type") or ""
    candidate_order = []
    for label in labels:
        m = ETA_LABEL.match(str(label))
        if m:
            n = int(m.group(1))
            return n * 60 if m.group(2) == "h" else n
        candidate_order.append(str(label))
    candidate_order.append(str(kind))
    for candidate in candidate_order:
        if candidate in defaults:
            return defaults[candidate]
    return fallback

inprog = bd("list", "--status", "in_progress", "--limit", "0")
captain = bd("list", "--status", "open", "--label", "captain", "--limit", "0")
if inprog is None or captain is None:
    raise SystemExit(0)
issues = {}
for row in inprog:
    if row.get("id"):
        issues[row["id"]] = (row, False)
for row in captain:
    if row.get("id"):
        issues[row["id"]] = (row, True)
if not issues:
    raise SystemExit(0)

seen_dir = os.path.join(state_dir, ".bead-overdue-seen")
os.makedirs(seen_dir, mode=0o700, exist_ok=True)
now = datetime.now(timezone.utc).timestamp()
wakes = []

for issue, is_captain in issues.values():
    iid = issue.get("id") or ""
    owner = (issue.get("owner") or "").split()[0] or "unassigned"
    title = re.sub(r"[\t\n]+", " ", issue.get("title") or "")[:80]
    eta = eta_minutes(issue)
    start_raw = issue.get("created_at") if is_captain else (issue.get("updated_at") or issue.get("created_at"))
    start = parse_ts(start_raw)
    if start is None:
        continue
    age_min = (now - start) / 60.0
    if age_min < eta:
        level = 0
    elif age_min < 2 * eta:
        level = 1
    else:
        level = 2
    if level == 0:
        continue

    # Blocking bead: read bd show once per over-threshold bead and name the
    # first open blocker whose owner differs from this bead's owner.
    block_note = ""
    if not is_captain:
        detail = bd("show", iid)
        rows = detail if isinstance(detail, list) else [detail] if detail else []
        for dep in (rows[0].get("dependencies") if rows else []) or []:
            if (dep.get("dependency_type") or dep.get("type")) != "blocks":
                continue
            if (dep.get("id") or "") == iid and dep.get("depends_on_id"):
                bid, bowner, bstatus = dep["depends_on_id"], "", None
            else:
                bid = dep.get("id")
                bowner = dep.get("owner") or ""
                bstatus = dep.get("status")
            if not bid:
                continue
            if bstatus is None:
                bd_blocker = bd("show", bid)
                brows = bd_blocker if isinstance(bd_blocker, list) else [bd_blocker] if bd_blocker else []
                brow = brows[0] if brows else {}
                bstatus = brow.get("status")
                bowner = bowner or brow.get("owner") or ""
            if bstatus in (None, "closed"):
                continue
            bowner_first = bowner.split()[0] if bowner else ""
            if bowner_first and bowner_first == owner and bstatus != "open":
                # Same-owner blockers that are merely in_progress still block
                # the waiter; the wake names the owner, not the bead itself.
                pass
            if bowner_first == owner:
                continue
            block_note = ", blocked by %s (owner %s)" % (bid, bowner_first or "unassigned")
            break

    if level == 1:
        line = "overdue: %s %s (%dm/%dm), owner %s%s" % (iid, title, int(age_min), eta, owner, block_note)
    else:
        line = "escalate: %s %s (%dm/%dm), owner %s%s" % (iid, title, int(age_min), eta, owner, block_note)

    marker = os.path.join(seen_dir, iid)
    prev_level, prev_start = 0, None
    try:
        with open(marker, encoding="utf-8") as fh:
            parts = fh.read().split()
        if len(parts) == 2:
            prev_level, prev_start = int(parts[0]), float(parts[1])
    except (OSError, ValueError):
        prev_level, prev_start = 0, None
    if prev_start is not None and prev_start != start:
        prev_level = 0  # anchor moved: the bead re-marked; re-arm.
    if prev_level >= level:
        continue
    tmp = marker + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("%d %d\n" % (level, int(start)))
    os.replace(tmp, marker)
    wakes.append(line)

for line in wakes:
    print(line)
PY
}
