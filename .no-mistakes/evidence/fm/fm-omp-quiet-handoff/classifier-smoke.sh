#!/usr/bin/env bash
# Bounded no-pane smoke of the composer classifier (bin/fm-composer-lib.sh)
# on omp 18.8 captured-shape frames, plus Cursor fully-dim and Cortex idle
# anchors. No tmux, no pane, no FM_HOME; prints one verdict per frame.
set -u
ROOT=${1:?worktree root}
. "$ROOT/bin/fm-composer-lib.sh"
ESC=$'\033'
TMUX_CAPS=$'styled=1\ncursor=1\nidentity=1\nrows=0'
HERDR_CAPS=$'styled=1\ncursor=0\nidentity=1\nrows=20'
fails=0
check() {  # <label> <want> <caps> <screen> [cursor] [identity]
  local label=$1 want=$2 got; shift 2
  got=$(fm_composer_classify_screen "$@")
  if [ "$got" = "$want" ]; then printf 'PASS  %-58s want=%-8s got=%s\n' "$label" "$want" "$got"
  else printf 'FAIL  %-58s want=%-8s got=%s\n' "$label" "$want" "$got"; fails=$((fails + 1)); fi
}
check_not() {  # <label> <forbidden> <caps> <screen> [cursor] [identity]
  local label=$1 bad=$2 got; shift 2
  got=$(fm_composer_classify_screen "$@")
  if [ "$got" != "$bad" ]; then printf 'PASS  %-58s not=%-8s got=%s\n' "$label" "$bad" "$got"
  else printf 'FAIL  %-58s not=%-8s got=%s\n' "$label" "$bad" "$got"; fails=$((fails + 1)); fi
}

# --- omp 18.8.7 nerd-preset frame shapes -----------------------------------
cap=$(printf '\356\202\266'); sep=$(printf '\356\202\261'); capr=$(printf '\356\202\260')
omp_icon=$(printf '\363\260\265\227'); ctx_icon=$(printf '\363\260\201\250')
key_a=$(printf '\363\260\230\266'); key_b=$(printf '\363\260\214\222')
status="${ESC}[38;2;15;18;22m${cap}${ESC}[39m ${ESC}[38;2;107;114;128m${omp_icon}${ESC}[39m ${sep} ${ESC}[38;2;0;180;255mMAI Pro${ESC}[39m ${sep} fm-lab ${capr}${ESC}[38;2;0;180;255m────8%${ESC}[38;2;42;48;56m──────────${ESC}[38;2;57;152;191m${ctx_icon}${ESC}[38;2;42;48;56m─────262K─"
dim="${ESC}[38;2;74;80;88m"; grey="${ESC}[38;2;229;229;231m"
pad=$(printf '%*s' 100 '')
label="${ESC}[3m${ESC}[38;2;107;114;128mto change thinking effort"
head='Tip: Type / to browse commands'
frame() { printf '%s\n\n%s\n%s\n\n' "$head" "$status" "$1"; }

check "omp 18.8 idle, captured nerd-pair effort hint (tmux)" empty "$TMUX_CAPS" \
  "$(frame "${dim}╰─ ${grey}${pad}${ESC}[38;2;0;180;255m${key_a} ${key_b}${grey} ${label}")" 3 probe-absent
check "omp 18.8 idle, captured nerd-pair effort hint (herdr)" empty "$HERDR_CAPS" \
  "$(frame "${dim}╰─ ${grey}${pad}${ESC}[38;2;0;180;255m${key_a} ${key_b}${grey} ${label}")" '' probe-absent
check "omp 18.8 idle, bare corner under status row (tmux)" empty "$TMUX_CAPS" \
  "$(frame "${dim}╰─ ${grey}")" 3 probe-absent
check "omp 18.8 typed draft under status row (tmux)" pending "$TMUX_CAPS" \
  "$(frame "${dim}╰─ ${grey}ship the fix")" 3 probe-absent
# Adversarial: key-hint shapes that were never captured must not read empty.
check_not "ADV: uncaptured 'ctrl+t' key cell + effort label" empty "$TMUX_CAPS" \
  "$(frame "${dim}╰─ ${grey}${pad}${ESC}[38;2;0;180;255mctrl+t${grey} ${label}")" 3 probe-absent
check_not "ADV: single nerd token + effort label" empty "$TMUX_CAPS" \
  "$(frame "${dim}╰─ ${grey}${pad}${ESC}[38;2;0;180;255m${key_a}${grey} ${label}")" 3 probe-absent
check_not "ADV: uncaptured running-agents hint" empty "$TMUX_CAPS" \
  "$(frame "${dim}╰─ ${grey}${pad}${ESC}[38;2;0;180;255m${key_a}${grey} ${ESC}[3m${ESC}[38;2;107;114;128mto see 3 running agents")" 3 probe-absent
# Adversarial: the corner is NOT proof without omp's status row directly above.
check_not "ADV: lone dim frame footer under cursor" empty "$TMUX_CAPS" \
  $'transcript\n╭─ subtask\n│ step one\n'"${dim}╰─${ESC}[39m"$'\n' 3 probe-absent
check_not "ADV: lone frame footer, cursorless bottom row" empty "$HERDR_CAPS" \
  $'transcript\n╭─ subtask\n│ step one\n'"${dim}╰─${ESC}[39m"$'\n' '' probe-absent
check_not "ADV: corner beneath plain prose, not status row" empty "$TMUX_CAPS" \
  $'some output line\n'"${dim}╰─ ${grey}"$'\n' 1 probe-absent
check "frame footer above live idle composer still idle" empty "$HERDR_CAPS" \
  $'╭─ subtask\n│ step one\n╰─\n\n'"$status"$'\n'"${dim}╰─ ${grey}"$'\n\n' '' probe-absent

# --- Cursor fully dim placeholder (main's handling preserved) --------------
row="${ESC}[48;2;42;44;57m ${ESC}[2m→ Add a follow-up${ESC}[0m${ESC}[48;2;42;44;57m        ${ESC}[49m"
cur=$'transcript\n '"${ESC}[38;2;42;44;57m▄▄▄▄▄▄▄▄${ESC}[39m"$'\n'"$row"$'\n '"${ESC}[38;2;42;44;57m▀▀▀▀▀▀▀▀${ESC}[39m"$'\n  Auto · 64%                          Run Everything\n  ~/wt · branch\n'
check "cursor fully dim placeholder (herdr)" empty "$HERDR_CAPS" "$cur"
curt=${cur//"${ESC}[2m→ Add a follow-up"/"→ fix login"}
check "cursor typed draft (herdr)" pending "$HERDR_CAPS" "$curt"

# --- Cortex idle anchors (main's handling preserved) -----------------------
rule() { local p; printf -v p '%*s' "$1" ''; printf '%s' "${p// /─}"; }
cx() {  # <cell> <visible-width>
  local title='New Session'
  printf '%s\n\n' ' › [Hook] Session context (ctrl+o to expand)'
  printf '╭%s %s ──╮\n' "$(rule $((92 - ${#title} - 4)))" "$title"
  printf '│ %s %s%*s│\n' "${ESC}[1m›${ESC}[0m" "$1" "$((92 - 3 - $2))" ''
  printf '╰%s╯\n\n' "$(rule 92)"
  printf '%s\n%s\n' '>> bypass safeguards  |  teams: off  |  plan: off  |  guard: on' 'view: compact • ? for help'
}
CX=$'styled=1\ncursor=0\nidentity=0\nrows=0\ncortex=1'
NOCX=$'styled=1\ncursor=0\nidentity=0\nrows=0'
check "cortex idle 'Type your message...' (cortex=1)" empty "$CX" "$(cx "${ESC}[7mT${ESC}[0m${ESC}[2mype your message...${ESC}[0m" 20)"
check "cortex busy 'Type to queue message...' (cortex=1)" empty "$CX" "$(cx "${ESC}[7mT${ESC}[0m${ESC}[2mype to queue message...${ESC}[0m" 24)"
check "cortex typed draft (cortex=1)" pending "$CX" "$(cx "draft text here${ESC}[7m ${ESC}[0m" 16)"
check_not "ADV: cortex titled box without cortex identity" empty "$NOCX" "$(cx "${ESC}[7mT${ESC}[0m${ESC}[2mype your message...${ESC}[0m" 20)"

printf '\nSMOKE_FAILURES=%s\n' "$fails"
[ "$fails" = 0 ]
