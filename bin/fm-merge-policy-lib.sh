#!/usr/bin/env bash
# Adapter between the verified forge preflight and fm-merge-policy.py's typed
# facts. Sourced after fm-wake-lib.sh; fm-pr-merge.sh owns the CLI/config contract.
# Policy decisions are retained as private JSON, never as fabricated task records.

fm_merge_policy_require() {
  local root home_real config facts decision status=0
  root=$(fm_firstmate_root_home "$FM_HOME") || {
    echo 'error: merge policy root home could not be resolved' >&2
    return 1
  }
  home_real=$(CDPATH='' cd -- "$FM_HOME" && pwd -P) || return 1
  config="$root/config"
  [ "$root" != "$home_real" ] || config="${FM_CONFIG_OVERRIDE:-$config}"
  if [ -e "$config" ] || [ -L "$config" ]; then
    if [ ! -d "$config" ] || [ -L "$config" ] || [ ! -r "$config" ] || [ ! -x "$config" ]; then
      echo 'error: merge policy configuration directory is unreadable or unsafe' >&2
      return 1
    fi
  fi
  command -v python3 >/dev/null 2>&1 || {
    echo 'error: merge policy requires python3 on PATH' >&2
    return 1
  }
  facts=$(jq -cn --arg provider "$PROVIDER" --arg host "$PR_HOST" \
    --arg path "$PR_PATH" --arg number "$PR_NUMBER" --arg url "$URL" \
    --arg head "$FM_PR_MERGE_HEAD" --arg base "$FM_PR_MERGE_BASE" \
    --arg approval "$CAPTAIN_APPROVAL" --arg login "$FORGEJO_LOGIN" \
    --argjson green "$FM_PR_ALL_CHECKS_GREEN" --argjson away "$FM_PR_AWAY_POSTURE" \
    --argjson kinds "$MERGE_KINDS" \
    '{version:1,provider:$provider,host:$host,path:$path,number:$number,url:$url,
      repository:("https://"+$host+"/"+$path),head:$head,base:$base,
      all_checks_green:$green,approval:$approval,away:$away,kinds:$kinds,paths:null,login:$login}') || return 1
  decision=$(printf '%s\n' "$facts" | python3 "$SCRIPT_DIR/fm-merge-policy.py" \
    --config "$config/merge-policy.json" --collect) || status=$?
  [ -n "$decision" ] || return 1
  # A refused decision is audit evidence too. No forge command is reachable if
  # either policy evaluation or this durable write fails.
  umask 077
  FM_PR_POLICY_RECORD=$(mktemp "$STATE/.merge-decision.XXXXXX") || return 1
  if ! printf '%s\n' "$decision" | jq --arg task "$ID" \
      '. + {task:(if $task == "" then null else $task end),outcome:"not-requested"}' \
      > "$FM_PR_POLICY_RECORD"; then
    echo 'error: merge policy decision could not be recorded' >&2
    return 1
  fi
  printf 'policy: %s; audit=%s\n' "$(printf '%s' "$decision" | jq -r .reason)" "$FM_PR_POLICY_RECORD" >&2
  [ "$status" -eq 0 ] || return 1
  # shellcheck disable=SC2034 # Public result consumed by the merge entrypoint.
  FM_PR_POLICY_AUTHORITY=$(printf '%s' "$decision" | jq -r .authority) || return 1
}

fm_merge_policy_outcome() { # <requested|accepted|merged|queued|unconfirmed|failed>
  local outcome=$1 tmp device
  case "$outcome" in requested|accepted|merged|queued|unconfirmed|failed) ;; *) return 1 ;; esac
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_private_file_valid "$FM_PR_POLICY_RECORD" 600 "$device" || return 1
  tmp=$(mktemp "$STATE/.merge-decision-update.XXXXXX") || return 1
  if ! jq --arg outcome "$outcome" '.outcome=$outcome' "$FM_PR_POLICY_RECORD" > "$tmp" \
      || ! mv -f -- "$tmp" "$FM_PR_POLICY_RECORD"; then
    rm -f -- "$tmp"
    echo 'actionable: forge outcome could not be saved in the merge policy audit' >&2
    return 1
  fi
}
