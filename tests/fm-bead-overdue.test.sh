#!/usr/bin/env bash
# tests/fm-bead-overdue.test.sh - the bead time-expectation surface: the ETA
# resolution order, the overdue/escalate wake thresholds and their dedupe,
# spawn's in_progress marking, and the relaunch/bead refusal edges, all
# through a fake bd on PATH. The real board is never touched: every run
# points config/beads-board at a scratch directory, and the no-config case
# proves no bd call happens at all.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bead-overdue)
CHECK="$ROOT/bin/fm-bead-overdue-check.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# --- fixture world ----------------------------------------------------------

make_home() {  # <name> -> home dir ready for a fake bd
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_fakebin "$home" >/dev/null
  printf '%s\n' "$home"
}

# Recording fake bd: appends one line per invocation to the home's bd.log.
# `list --status <s> ...` serves bd-list-<s>.json when staged, else
# bd-list.json; a `--label captain` poll serves bd-list-open.json. `show <id>`
# serves bd-show-<id>.json; `update`/`close` succeed and log. The log is the
# suite's authoritative record of exactly which bd calls happened.
make_fake_bd() {  # <home>
  local home=$1
  mkdir -p "$home/board/.beads"
  cat > "$home/fakebin/bd" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/bd.log"
case "\$1" in
  list)
    status=
    label=
    prev=
    for arg in "\$@"; do
      case "\$prev" in
        --status) status=\$arg ;;
        --label) label=\$arg ;;
      esac
      prev=\$arg
    done
    if [ "\$label" = captain ]; then
      cat "$home/bd-list-open.json" 2>/dev/null || printf '[]\n'
    else
      cat "$home/bd-list-\$status.json" 2>/dev/null || cat "$home/bd-list.json" 2>/dev/null || printf '[]\n'
    fi
    ;;
  show)
    f="$home/bd-show-\$2.json"
    [ -f "\$f" ] && cat "\$f" || printf '[]\n'
    ;;
  update|close)
    printf '{"id":"%s","status":"%s"}\n' "\$2" "\$1"
    ;;
  *)
    printf 'fake bd: unknown subcommand: %s\n' "\$1" >&2
    exit 2
    ;;
esac
exit 0
SH
  chmod +x "$home/fakebin/bd"
}

join_board() {  # <home>
  printf '%s\n' "$1/board" > "$1/config/beads-board"
}

run_check() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$CHECK"
}

# ISO 8601 UTC <minutes-ago>
ago() {  # <minutes>
  python3 - "$1" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
n = int(sys.argv[1])
print((datetime.now(timezone.utc) - timedelta(minutes=n)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# --- 1. no-config home makes no bd calls ------------------------------------

home_nc=$(make_home a-no-config)
make_fake_bd "$home_nc"
# A plausible board on disk proves nothing sniffs for one implicitly.
: > "$home_nc/board/.beads/placeholder"

out=$(run_check "$home_nc") || fail 'no-config home: the check failed'
[ -z "$out" ] || fail "no-config home: the check printed '$out'"
[ ! -f "$home_nc/bd.log" ] || fail 'no-config home called bd'
pass 'no-config home: no bd calls, no output'

# --- 2. ETA resolution: label wins, then defaults table, then fallback -------

home_t=$(make_home b-thresholds)
make_fake_bd "$home_t"
join_board "$home_t"
cat > "$home_t/config/bead-eta-defaults" <<'EOF'
# one key=minutes per line
deploy=45
ship=60
scout=120
captain=240
EOF
NOW_100M=$(ago 100)
NOW_10M=$(ago 10)
cat > "$home_t/bd-list.json" <<EOF
[
  {"id":"fm-eta-label","title":"explicit eta label","status":"in_progress","issue_type":"task","owner":"worker-one","created_at":"$(ago 500)","updated_at":"$NOW_100M","labels":["deploy","eta:30m"]},
  {"id":"fm-eta-kind","title":"kind default","status":"in_progress","issue_type":"task","owner":"worker-one","created_at":"$(ago 500)","updated_at":"$NOW_100M","labels":["deploy"]},
  {"id":"fm-eta-type","title":"issue_type default","status":"in_progress","issue_type":"scout","owner":"worker-one","created_at":"$NOW_10M","updated_at":"$NOW_100M","labels":[]},
  {"id":"fm-eta-fallback","title":"fallback","status":"in_progress","issue_type":"bug","owner":"worker-one","created_at":"$NOW_10M","updated_at":"$NOW_100M","labels":["unlisted"]},
  {"id":"fm-eta-young","title":"inside eta","status":"in_progress","issue_type":"task","owner":"worker-one","created_at":"$NOW_10M","updated_at":"$NOW_10M","labels":["deploy"]},
  {"id":"fm-eta-captain","title":"captain ages from creation","status":"open","issue_type":"task","owner":"captain","created_at":"$NOW_100M","updated_at":"$(ago 1)","labels":["captain"]}
]
EOF
# fm-eta-label: eta:30m label, age 100m -> escalate (label wins over deploy=45)
# fm-eta-kind: deploy=45, age 100m -> escalate (2x45=90 < 100)
# fm-eta-type: scout=120 (issue_type), age 100m -> quiet (100 < 120)
# fm-eta-fallback: 120 fallback, age 100m -> quiet
# fm-eta-young: deploy=45, age 10m -> quiet
# fm-eta-captain: captain=240, created 100m ago -> quiet (updated_at ignored)

out=$(run_check "$home_t") || fail 'threshold run failed'
printf '%s\n' "$out" > "$home_t/out1"
grep -q '^escalate: fm-eta-label explicit eta label (1[0-9][0-9]m/30m), owner worker-one$' "$home_t/out1" \
  || fail "label eta did not escalate over the kind default: $out"
grep -q '^escalate: fm-eta-kind kind default (1[0-9][0-9]m/45m), owner worker-one$' "$home_t/out1" \
  || fail "kind default did not apply: $out"
! grep -q 'fm-eta-type' "$home_t/out1" \
  || fail 'issue_type scout=120 was not honored (wrong table key matched)'
! grep -q 'fm-eta-fallback' "$home_t/out1" \
  || fail 'the 120-minute fallback was not honored'
! grep -q 'fm-eta-young' "$home_t/out1" \
  || fail 'a bead inside its eta was reported'
! grep -q 'fm-eta-captain' "$home_t/out1" \
  || fail 'a captain bead aged from its updated_at, not its creation'
pass 'ETA resolution: eta: label wins, defaults by label and issue_type, fallback 120, captain anchors at creation'

# --- 3. thresholds and dedupe: overdue at 1x, escalate at 2x, once each ------

home_d=$(make_home c-dedupe)
make_fake_bd "$home_d"
join_board "$home_d"
printf 'deploy=45\n' > "$home_d/config/bead-eta-defaults"

stage_d() {  # <minutes>
  cat > "$home_d/bd-list.json" <<EOF
[
  {"id":"fm-dep","title":"deploy to staging","status":"in_progress","issue_type":"task","owner":"stage-worker","created_at":"$(ago 500)","updated_at":"$(ago "$1")","labels":["deploy"]}
]
EOF
}

stage_d 50
out1=$(run_check "$home_d") || fail '1x run failed'
case "$out1" in
  'overdue: fm-dep deploy to staging ('*'m/45m), owner stage-worker') ;;
  *) fail "1x crossing printed the wrong wake: $out1" ;;
esac
out2=$(run_check "$home_d") || fail 'deduped run failed'
[ -z "$out2" ] || fail "the recorded overdue crossing re-fired: $out2"
pass '1x crossing fires one overdue wake and dedupes'

stage_d 95
out3=$(run_check "$home_d") || fail '2x run failed'
case "$out3" in
  'escalate: fm-dep deploy to staging ('*'m/45m), owner stage-worker') ;;
  *) fail "2x crossing printed the wrong wake: $out3" ;;
esac
out4=$(run_check "$home_d") || fail 'escalate dedupe run failed'
[ -z "$out4" ] || fail "the recorded escalate crossing re-fired: $out4"
pass '2x crossing escalates once; all later crossings stay quiet'

# A fresh home first sighting beyond 2x escalates directly (no overdue first),
# and once recorded, nothing refires. A re-marked start (the anchor moved)
# re-arms the thresholds.
home_l=$(make_home d-late)
make_fake_bd "$home_l"
join_board "$home_l"
printf 'deploy=45\n' > "$home_l/config/bead-eta-defaults"
stage_l() {  # <minutes>
  cat > "$home_l/bd-list.json" <<EOF
[
  {"id":"fm-late","title":"late bead","status":"in_progress","issue_type":"task","owner":"w","created_at":"$(ago 500)","updated_at":"$(ago "$1")","labels":["deploy"]}
]
EOF
}
stage_l 95
out5=$(run_check "$home_l") || fail 'late first-sighting run failed'
case "$out5" in
  'escalate: fm-late late bead ('*'m/45m), owner w') ;;
  *) fail "late first sighting printed the wrong wake: $out5" ;;
esac
[ -z "$(run_check "$home_l")" ] || fail 'the recorded late escalate re-fired'
stage_l 50
out6=$(run_check "$home_l") || fail 're-marked run failed'
case "$out6" in
  'overdue: fm-late late bead ('*'m/45m), owner w') ;;
  *) fail "a re-marked bead did not re-fire overdue: $out6" ;;
esac
pass 'late first sighting escalates; a re-marked start re-arms the thresholds'

# --- 4. blocked beads name their blocker --------------------------------------

home_b=$(make_home e-blocked)
make_fake_bd "$home_b"
join_board "$home_b"
printf 'deploy=45\n' > "$home_b/config/bead-eta-defaults"
stage_b() {  # <show-fixture-file>
  cat > "$home_b/bd-list.json" <<'EOF'
[
  {"id":"fm-waiter","title":"wait on schema","status":"in_progress","issue_type":"task","owner":"deploy-worker","created_at":"CREATED","updated_at":"UPDATED","labels":["deploy"]}
]
EOF
  sed -i '' "s/CREATED/$(ago 500)/; s/UPDATED/$(ago 100)/" "$home_b/bd-list.json"
  cp "$1" "$home_b/bd-show-fm-waiter.json"
}
fixture_b1="$TMP_ROOT/blocker-diff-owner.json"
cat > "$fixture_b1" <<'EOF'
[
  {"id":"fm-waiter","title":"wait on schema","status":"in_progress","owner":"deploy-worker","labels":["deploy"],
   "dependencies":[
     {"id":"fm-schema","title":"schema change","status":"open","owner":"schema-owner","dependency_type":"blocks"}
   ]}
]
EOF
stage_b "$fixture_b1"
outb=$(run_check "$home_b") || fail 'blocked run failed'
grep -q '^escalate: fm-waiter wait on schema (1[0-9][0-9]m/45m), owner deploy-worker, blocked by fm-schema (owner schema-owner)$' <<<"$outb" \
  || fail "the blocked bead did not name its blocker: $outb"
pass 'a blocked bead names the first open blocker whose owner differs'

# An unassigned blocker is named (unassigned); a same-owner blocker never
# names itself. Reset the dedupe records so the same bead refires.
rm -rf "$home_b/state/.bead-overdue-seen"
fixture_b2="$TMP_ROOT/blocker-same-and-unassigned.json"
cat > "$fixture_b2" <<'EOF'
[
  {"id":"fm-waiter","title":"wait on schema","status":"in_progress","owner":"deploy-worker","labels":["deploy"],
   "dependencies":[
     {"id":"fm-self","title":"own subtask","status":"open","owner":"deploy-worker","dependency_type":"blocks"},
     {"id":"fm-free","title":"unassigned blocker","status":"open","owner":"","dependency_type":"blocks"}
   ]}
]
EOF
stage_b "$fixture_b2"
outc=$(run_check "$home_b") || fail 'unassigned blocker run failed'
grep -q 'blocked by fm-free (owner unassigned)$' <<<"$outc" \
  || fail "an unassigned blocker was not flagged: $outc"
! grep -q 'blocked by fm-self' <<<"$outc" \
  || fail "a same-owner blocker named itself: $outc"
pass 'unassigned blocker named (unassigned); a same-owner blocker never flags'

# --- 5. spawn marks the linked bead in_progress and stamps its start ---------
# The spawn-fixture shape mirrors tests/fm-project-capacity.test.sh: fake
# tmux/treehouse, one git project with an origin, and a markdown backlog the
# real tasks-axi drives. Skip when tasks-axi is absent (the backlog gate is
# inert without it and the spawn's note extraction is the behavior under test).

SPAWN="$ROOT/bin/fm-spawn.sh"
if ! command -v tasks-axi >/dev/null 2>&1; then
  pass 'skipped: tasks-axi is not installed, so the spawn marking suite is inert'
  exit 0
fi

home_s=$(make_home f-spawn)
make_fake_bd "$home_s"
join_board "$home_s"
fm_fake_exit0 "$home_s/fakebin" no-mistakes gh gh-axi
# The tmux/treehouse fakes mirror tests/fm-project-capacity.test.sh's shape,
# extended for the relaunch walk: the fake keeps a window inventory, answers
# pane-path probes with the path the spawn was steered at, and spawns add
# their window to that inventory, so --relaunch can kill the window and then
# prove it gone (the tmux adapter's dead-window verdict is a definitive
# missing only when the session inventory no longer lists the window).
cat > "$home_s/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf 'tmux %s\n' "\$*" >> "$home_s/tmux.log"
case "\${1:-}" in
  list-windows)
    out=
    [ -f "$home_s/tmux-windows" ] && out=\$(cat "$home_s/tmux-windows")
    printf '%s\n' "\$out"
    exit 0
    ;;
  new-window)
    name=
    shift
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -n) name=\${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "\$name" >> "$home_s/tmux-windows"
    printf '@9\n'
    exit 0
    ;;
  kill-window)
    target=
    shift
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -t) target=\${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    window=\${target#*:}
    if [ -f "$home_s/tmux-windows" ]; then
      grep -vx "\$window" "$home_s/tmux-windows" > "$home_s/tmux-windows.tmp" || :
      mv "$home_s/tmux-windows.tmp" "$home_s/tmux-windows"
    fi
    exit 0
    ;;
  display-message)
    case "\$*" in
      *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
      *"#{pane_tty}"*) printf '%s\n' '/dev/ttys043'; exit 0 ;;
      *"#{pane_id}"*) printf '%s\n' '%1'; exit 0 ;;
    esac
    printf 'firstmate\n'
    exit 0
    ;;
  send-keys|new-session)
    exit 0
    ;;
esac
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
exit 0
SH
cat > "$home_s/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$home_s/fakebin/tmux" "$home_s/fakebin/treehouse"
mkdir -p "$home_s/projects"
touch "$home_s/state/.last-watcher-beat"
printf '%s\n' codex > "$home_s/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home_s/data/backlog.md"
cat > "$home_s/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
proj_s="$TMP_ROOT/proj-fixture"
fm_git_init_commit "$proj_s"
fm_git_add_origin "$proj_s" "$TMP_ROOT/proj-fixture.origin.git"
# A pristine "local copy" input: fm-spawn records worktree= as given, and the
# tmux fake answers every pane-path probe with the path it is steered at.
wt_s="$TMP_ROOT/fake-wt"
fm_git_init_commit "$wt_s"

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Exercise the bead marking surface for $2.

## Firstmate spec
Mark the linked bead and record the linkage.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/$2
EOF
}

add_item() {  # <home> <id>
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

# A fresh spawn against a passed local copy with fake tmux as its endpoint;
# FM_FAKE_PANE_PATH steers the fake's path answers to that copy.
run_spawn() {  # <worktree> <args...>
  local pane=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home_s" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" \
    PATH="$home_s/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <worktree> <id> [extra spawn args...] - mode no-mistakes
  local pane=$1 id=$2
  shift 2
  run_spawn "$pane" "$id" "$proj_s" --mode no-mistakes --yolo off "$@"
}

write_brief "$home_s" bead-mark-one
add_item "$home_s" bead-mark-one
cat > "$home_s/bd-list.json" <<'EOF'
[]
EOF
spawn1=$(spawn_ship "$wt_s" bead-mark-one --bead fm-linked) && rc1=0 || rc1=$?
if [ "$rc1" -ne 0 ]; then
  printf 'spawn1 failed rc=%d:\n%s\n' "$rc1" "$spawn1"
  fail 'fm-spawn --bead failed'
fi
grep -q '^update fm-linked -s in_progress ' "$home_s/bd.log" \
  || fail "spawn did not mark the bead in_progress: $(cat "$home_s/bd.log" 2>/dev/null)"
grep -q '^bead=fm-linked$' "$home_s/state/bead-mark-one.meta" \
  || fail 'the bead linkage was not recorded on the task record'
grep -q -- '--notes firstmate bead-mark-one marked in_progress' "$home_s/bd.log" \
  || fail 'spawn did not stamp the bead start time'
pass 'fm-spawn --bead marks the bead in_progress and stamps its start'

# A different spawn auto-extracts `bead: <id>` from the backlog item's note.
write_brief "$home_s" bead-mark-two
add_item "$home_s" bead-mark-two
tasks-axi update bead-mark-two --body 'context bead: fm-noted trailing words' \
  --file "$home_s/data/backlog.md" >/dev/null
wt_s2="$TMP_ROOT/fake-wt-2"
fm_git_init_commit "$wt_s2"
spawn2=$(spawn_ship "$wt_s2" bead-mark-two) && rc2=0 || rc2=$?
if [ "$rc2" -ne 0 ]; then
  printf 'note-linked spawn failed rc=%d:\n%s\n' "$rc2" "$spawn2"
  fail 'note-linked spawn failed'
fi
grep -q '^update fm-noted -s in_progress ' "$home_s/bd.log" \
  || fail "the backlog note did not link the bead: $(cat "$home_s/bd.log")"
grep -q '^bead=fm-noted$' "$home_s/state/bead-mark-two.meta" \
  || fail 'the note-linked bead was not recorded'
pass 'a bead: <id> line in the backlog note links the bead'

# A relaunch refuses --bead as an override (below) and otherwise reuses the
# recorded linkage. tmux deliberately refuses relaunch-on-a-missing-record
# (bin/fm-control-lib.sh owns that policy: it cannot prove absence from a
# task record), so driving a real completed relaunch would need the herdr
# adapter's recovery-grade classifier and its own fixture family; the
# replace-record half of the story - preserve_relaunch_meta carries every
# launch-unlisted key=value line, which is what keeps bead= on the new
# record - is pinned by the tests/fm-control-relaunch.test.sh family.

# --bead is refused where it cannot apply: as a relaunch override.
if run_spawn "$wt_s2" bead-mark-two --relaunch --bead fm-other > "$home_s/spawn4.out" 2>&1; then
  fail '--bead on a relaunch was accepted'
fi
grep -q -- '--relaunch reuses the task' "$home_s/spawn4.out" \
  || { cat "$home_s/spawn4.out"; fail 'the relaunch --bead refusal did not explain itself'; }

# A joined home whose board is broken refuses the spawn before any record.
write_brief "$home_s" bead-mark-broken
add_item "$home_s" bead-mark-broken
rm -rf "$home_s/board/.beads"
wt_s3="$TMP_ROOT/fake-wt-3"
fm_git_init_commit "$wt_s3"
if spawn_ship "$wt_s3" bead-mark-broken --bead fm-linked > "$home_s/spawn5.out" 2>&1; then
  fail 'a spawn with a broken board was accepted'
fi
grep -q 'board is unavailable\|beads board' "$home_s/spawn5.out" \
  || { cat "$home_s/spawn5.out"; fail 'the broken-board spawn refusal did not explain itself'; }
[ ! -e "$home_s/state/bead-mark-broken.meta" ] \
  || fail 'the broken-board refusal left a task record behind'
# The broken-board refusal above made no board call for its own spawn, so the
# log still ends at the two markings from the successful spawns.
[ "$(grep -c '^update fm-linked -s in_progress ' "$home_s/bd.log")" = 1 ] \
  || fail 'the broken-board refusal still touched the board'
pass '--bead refusal: relaunch override refused; a broken joined board refuses before any record exists'
