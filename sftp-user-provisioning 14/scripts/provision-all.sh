#!/usr/bin/env bash
#
# Read users.yaml, validate it, then provision each user in turn. LOCAL USE ONLY.
#
#   provision-all.sh validate   check users.yaml only, needs no cloud access
#   provision-all.sh plan       validate + terraform plan per user, changes nothing
#   provision-all.sh apply      create the users
#
# Config file: $CONFIG_FILE, default <repo>/users.yaml. Needs mikefarah yq v4 + jq.
#
# Every entry must have a name and a path - that's the only rule. Each user is
# then provisioned by a separate process, so one failing user does not stop
# the others; the exit code is non-zero if any user failed.
# provision-user.sh exits 10 for "already exists with the same path, skipped".

set -euo pipefail

MODE="${1:?usage: $0 <validate|plan|apply>}"
[[ "$MODE" == "validate" || "$MODE" == "plan" || "$MODE" == "apply" ]] \
  || { echo "mode must be validate, plan or apply" >&2; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$here/../users.yaml}"
EXIT_SKIPPED=10

log() { printf '==> %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

log "mode=$MODE"
log "reading $CONFIG_FILE"

[[ -f "$CONFIG_FILE" ]] || fail "config file not found: $CONFIG_FILE"

log "checking jq and yq are installed"
command -v jq >/dev/null || fail "jq is not installed"
command -v yq >/dev/null || fail "yq is not installed (https://github.com/mikefarah/yq)"
yq --version 2>&1 | grep -qi mikefarah || fail "wrong yq: this needs mikefarah/yq v4, not the python 'yq'"

# YAML -> JSON -> one "name:path" line per entry (names and paths can't contain ':').
log "parsing users.yaml"
lines="$(yq -o=json '.' "$CONFIG_FILE" | jq -r '
    (.users // []) as $u
    | if ($u | type) != "array" then error("users must be a list") else $u end
    | .[]
    | if type != "object" then error("each entry needs name and path") else . end
    | "\(.name // ""):\(.path // "")"
  ')" || fail "could not read $CONFIG_FILE - it must look like:  users: [ {name: ..., path: ...} ]"

names=()
paths=()
seen=" "

log "validating entries (name and path both required, no duplicate names)"
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue

  user="${entry%%:*}"
  path="${entry#*:}"
  path="${path#/}"
  path="${path%/}"

  [[ -n "$user" ]] || fail "an entry is missing 'name'"
  [[ -n "$path" ]] || fail "user '$user' has no path - every user needs an explicit path"
  [[ "$seen" != *" $user "* ]] || fail "user '$user' is listed twice"

  seen+="$user "
  names+=("$user")
  paths+=("$path")
done <<<"$lines"

if [[ ${#names[@]} -eq 0 ]]; then
  log "no users in $(basename "$CONFIG_FILE") - nothing to do"
  exit 0
fi

log "validated ${#names[@]} user(s) from $(basename "$CONFIG_FILE"):"
for i in "${!names[@]}"; do printf '  %s -> %s\n' "${names[$i]}" "${paths[$i]}"; done

[[ "$MODE" != "validate" ]] || { log "validate-only mode, stopping here"; exit 0; }

created=()
skipped=()
failed=()

for i in "${!names[@]}"; do
  user="${names[$i]}"
  path="${paths[$i]}"

  log "----- $user -----"
  log "provisioning '$user' -> '$path' (mode=$MODE)"
  rc=0
  bash "$here/provision-user.sh" "$MODE" "$user" "$path" || rc=$?
  case "$rc" in
    0) created+=("$user") ;;
    "$EXIT_SKIPPED") skipped+=("$user") ;;
    *) failed+=("$user") ;;
  esac
done

verb="Created"
[[ "$MODE" == "plan" ]] && verb="Would create"

echo
log "$verb: ${created[*]:-none}"
log "Skipped (already exist): ${skipped[*]:-none}"
log "Failed: ${failed[*]:-none}"

[[ ${#failed[@]} -eq 0 ]]
