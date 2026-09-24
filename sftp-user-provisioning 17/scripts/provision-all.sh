#!/usr/bin/env bash
#
# Reads users.yaml, validates it, and provisions each user via
# provision-user.sh. See README for setup and details.
#
#   provision-all.sh validate|plan|apply

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
