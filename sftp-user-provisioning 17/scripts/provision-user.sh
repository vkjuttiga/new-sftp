#!/usr/bin/env bash
#
# Provisions one SFTP user in AWS Transfer Family and uploads its key to
# Keeper. No key material is ever written to disk. Called by
# provision-all.sh. See README for setup, env vars, and design notes.
#
#   provision-user.sh plan|apply <user> <path>

set -euo pipefail

MODE="${1:?usage: $0 <plan|apply> <user> <path>}"
USER_NAME="${2:?usage: $0 <plan|apply> <user> <path>}"
USER_PATH="${3:?usage: $0 <plan|apply> <user> <path>}"

[[ "$MODE" == "plan" || "$MODE" == "apply" ]] || { echo "mode must be plan or apply" >&2; exit 2; }

: "${AWS_REGION:?}" "${TRANSFER_SERVER_ID:?}" "${S3_BUCKET:?}" "${TRANSFER_ROLE_ARN:?}" "${TF_STATE_BUCKET:?}"
[[ "$MODE" == "apply" ]] && : "${KEEPER_CONFIG:?apply needs Keeper - it is the only place the key ends up}"

KEY_TYPE="${KEY_TYPE:-rsa}"
SFTP_HOST="${SFTP_HOST:-${TRANSFER_SERVER_ID}.server.transfer.${AWS_REGION}.amazonaws.com}"
SFTP_STATE_DIR="${SFTP_STATE_DIR:-$HOME/.sftp-provisioning}"
DONE_MARKER="$SFTP_STATE_DIR/$USER_NAME"

KEEPER_CLI="${KEEPER_CLI:-keeper}"
KEEPER_FOLDER="${KEEPER_FOLDER:-}"
KEEPER_RECORD_PREFIX="${KEEPER_RECORD_PREFIX:-}"
RECORD_TITLE="${KEEPER_RECORD_PREFIX}${USER_NAME}"

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
export TF_IN_AUTOMATION=1
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_server_id="$TRANSFER_SERVER_ID"
export TF_VAR_bucket_name="$S3_BUCKET"
export TF_VAR_role_arn="$TRANSFER_ROLE_ARN"

log() { printf '[%s] ==> %s\n' "$USER_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$USER_NAME" "$*" >&2; exit 1; }

log "starting: mode=$MODE path=$USER_PATH key=$KEY_TYPE"

# Prefer RAM; fall back to $TMPDIR if /dev/shm doesn't exist (e.g. macOS).
if [[ -d /dev/shm ]]; then
  KEY_BASE=/dev/shm
else
  KEY_BASE="${TMPDIR:-/tmp}"
  log "no /dev/shm on this system - using $KEY_BASE instead (still wiped on exit)"
fi

WORK="$(mktemp -d "$KEY_BASE/sftp-user.XXXXXX")"
chmod 700 "$WORK"
KEY="$WORK/id"
VARS="$WORK/users.tfvars.json"

TF_CREATED=0   # 1 once terraform has created something not yet rolled back

tf() { terraform -chdir="$TF_DIR" "$@"; }

cleanup() {
  local rc=$?
  trap - EXIT

  if [[ $rc -ne 0 && $TF_CREATED -eq 1 ]]; then
    log "rolling back - removing the user"
    tf destroy -auto-approve -input=false -var-file="$VARS" \
      || log "rollback failed - delete user '$USER_NAME' and its state by hand"
  fi

  if [[ -f "$KEY" ]]; then
    command -v shred >/dev/null && shred -u "$KEY" || rm -f "$KEY"
  fi
  rm -f "$KEY.pub"
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# Filed flat in KEEPER_FOLDER, titled with the username (see README - no
# per-user subfolder). Only the private key is uploaded.
keeper_upload_key() {
  log "uploading private key to Keeper as '$RECORD_TITLE'"
  local priv_b64 cmd out folder_arg=""
  priv_b64="$(base64 <"$KEY" | tr -d '\n')"
  [[ -n "$KEEPER_FOLDER" ]] && folder_arg=" --folder \"$KEEPER_FOLDER\""

  cmd="record-add --title \"$RECORD_TITLE\" --record-type login --force$folder_arg"
  cmd="$cmd \"login=$USER_NAME\" \"c.text.path=$USER_PATH\" \"c.secret.private_key_b64=$priv_b64\""

  if out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd" 2>&1)"; then
    mkdir -p "$SFTP_STATE_DIR"
    touch "$DONE_MARKER"
    log "Keeper upload succeeded"
    return 0
  fi
  log "Keeper upload FAILED: $(tail -n 1 <<<"$out")"
  return 1
}

check_existing_user() {
  log "checking if user '$USER_NAME' already exists"
  local out current expected
  if out="$(aws transfer describe-user --region "$AWS_REGION" --output json \
    --server-id "$TRANSFER_SERVER_ID" --user-name "$USER_NAME" 2>&1)"; then
    current="$(jq -r '.User.HomeDirectoryMappings[0].Target // .User.HomeDirectory // ""' <<<"$out")"
    current="${current%/}"
    expected="/${S3_BUCKET}/${USER_PATH}"
    [[ "$current" == "$expected" ]] \
      || die "exists but points to '$current', users.yaml says '$expected' - won't touch it"

    if [[ "$MODE" != "apply" ]]; then
      log "already exists - skipping"
      exit 10
    fi

    if [[ -f "$DONE_MARKER" ]]; then
      log "already fully set up - skipping"
      exit 10 # provision-all.sh treats this as "nothing to do"
    fi

    log "user exists but has no record of a completed key upload - regenerating the key"
    return
  elif [[ "$out" != *ResourceNotFoundException* ]]; then
    die "could not check for the user: $out"
  fi
}

generate_keys() {
  log "generating $KEY_TYPE key pair"
  local bits=()
  [[ "$KEY_TYPE" == "rsa" ]] && bits=(-b 4096)
  ssh-keygen -q -t "$KEY_TYPE" ${bits[@]+"${bits[@]}"} -N "" -C "sftp-${USER_NAME}" -f "$KEY"
  chmod 600 "$KEY"
}

write_tfvars() {
  log "writing terraform variables"
  jq -n --arg user "$USER_NAME" --arg pub "$KEY.pub" --arg path "$USER_PATH" \
    '{users: {($user): {public_key_path: $pub, home_directory_target: $path}}}' >"$VARS"
}

tf_init() {
  log "initializing terraform"
  tf init -input=false -reconfigure \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=sftp-users/${USER_NAME}.tfstate" \
    -backend-config="region=$AWS_REGION" >/dev/null
}

test_connection() {
  log "testing SFTP login"
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if sftp -i "$KEY" -b - \
      -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$WORK/known_hosts" \
      "${USER_NAME}@${SFTP_HOST}" <<<"pwd" >/dev/null 2>"$WORK/sftp.err"; then
      log "login works"
      return 0
    fi
    log "login attempt $attempt/6 failed: $(tail -n 1 "$WORK/sftp.err")"
    sleep 10
  done
  return 1
}

# ---------------------------------------------------------------- main ------
check_existing_user

if [[ "$MODE" == "plan" ]]; then
  log "writing a placeholder public key (plan only reads one, never a real key)"
  printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0 plan-placeholder\n' >"$KEY.pub"
else
  generate_keys
fi
write_tfvars
tf_init

if [[ "$MODE" == "plan" ]]; then
  log "running terraform plan"
  tf plan -input=false -no-color -var-file="$VARS"
  exit 0
fi

log "running terraform apply"
TF_CREATED=1
tf apply -auto-approve -input=false -var-file="$VARS"

test_connection || die "login test failed"

keeper_upload_key || die "key upload failed - the user's new key doesn't exist anywhere now, so it's being rolled back"
TF_CREATED=0

log "done: user set up, login tested, key uploaded to Keeper and wiped locally"
