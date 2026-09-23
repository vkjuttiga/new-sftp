#!/usr/bin/env bash
#
# Provision ONE SFTP user end to end. LOCAL USE ONLY (no CI/CD).
#
#   provision-user.sh plan  <user> <path>   checks + terraform plan, changes nothing
#   provision-user.sh apply <user> <path>   creates the user for real
#
# apply order (nothing irreversible happens before the checks pass):
#   1. check the user: not there -> create it below. Already there with the
#      same path but NO saved key (a previous run got the user created and
#      then failed before the key was saved) -> resume: redo steps 2-4 for
#      that same user, replacing its unusable orphaned key. Already there
#      WITH a saved key but no Keeper upload yet (Keeper configured, but a
#      previous run's upload failed) -> retry just the Keeper upload, no AWS
#      changes at all. Already there with everything done -> skip (exit 10).
#      Already there with a different path -> error.
#   2. generate an RSA SSH keypair under $TMPDIR
#   3. terraform apply  (user + public key)
#   4. test the SFTP login with the private key
#   5. only then: copy both keys into a permanent per-user folder under
#      SFTP_KEYS_DIR
#   6. if KEEPER_CONFIG is set: best-effort upload to Keeper. This step can
#      never roll back steps 2-5 - by the time it runs, the AWS user and the
#      local key are already a done deal. If it fails, the run still exits
#      non-zero (so provision-all.sh reports the user under "Failed" and you
#      notice), but nothing about the user or its local key is touched -
#      just re-run apply to retry the upload alone (step 1 detects this and
#      skips straight to it), or upload $USER_KEY_DIR by hand.
#
# plan mode never generates a real keypair - it writes a placeholder public
# key, since that's all terraform plan needs to read.
#
# NOTE: this leaves real private keys sitting on disk under SFTP_KEYS_DIR
# until you move or delete them yourself. Keep that folder out of anywhere
# synced/backed up to somewhere you don't want key material, and don't
# commit it to git.
#
# Required env : AWS_REGION TRANSFER_SERVER_ID S3_BUCKET TRANSFER_ROLE_ARN TF_STATE_BUCKET
# Optional     : KEY_TYPE (rsa|ed25519, default rsa, 4096-bit when rsa)
#                SFTP_HOST
#                SFTP_KEYS_DIR (default: $HOME/Documents/sftp-keys) - each
#                user gets a subfolder here: SFTP_KEYS_DIR/<user_name>/
#                TMPDIR (default: /tmp) - where the keypair is briefly
#                generated before being copied into SFTP_KEYS_DIR
#                KEEPER_CONFIG - path to a Commander config.json with a
#                persistent login session. Leave unset to skip Keeper
#                entirely (local save only)
#                KEEPER_CLI (default: keeper)
#                KEEPER_FOLDER (optional parent folder you already created in
#                Keeper; every user's record is filed directly inside it, no
#                per-user subfolder - Commander's non-interactive mode has no
#                working way to create or cd into a nested folder, confirmed
#                against a live vault, so this design deliberately never
#                tries to)
#                KEEPER_RECORD_PREFIX (optional prefix on the record title,
#                e.g. "sftp-" - the title is "<prefix><user_name>", default
#                prefix is empty so the title is just the user's name)

set -euo pipefail

MODE="${1:?usage: $0 <plan|apply> <user> <path>}"
USER_NAME="${2:?usage: $0 <plan|apply> <user> <path>}"
USER_PATH="${3:?usage: $0 <plan|apply> <user> <path>}"

[[ "$MODE" == "plan" || "$MODE" == "apply" ]] || { echo "mode must be plan or apply" >&2; exit 2; }

: "${AWS_REGION:?}" "${TRANSFER_SERVER_ID:?}" "${S3_BUCKET:?}" "${TRANSFER_ROLE_ARN:?}" "${TF_STATE_BUCKET:?}"

KEY_TYPE="${KEY_TYPE:-rsa}"
SFTP_HOST="${SFTP_HOST:-${TRANSFER_SERVER_ID}.server.transfer.${AWS_REGION}.amazonaws.com}"
SFTP_KEYS_DIR="${SFTP_KEYS_DIR:-$HOME/Documents/sftp-keys}"
SFTP_KEYS_DIR="${SFTP_KEYS_DIR%/}"
USER_KEY_DIR="$SFTP_KEYS_DIR/$USER_NAME"

KEEPER_CLI="${KEEPER_CLI:-keeper}"
KEEPER_RECORD_PREFIX="${KEEPER_RECORD_PREFIX:-}"
KEEPER_FOLDER="${KEEPER_FOLDER:-}"
# Flat by design: one record per user, titled with their name, filed
# directly in KEEPER_FOLDER (or the Keeper root if unset). No per-user
# subfolder - see the NOTE further down for why.
RECORD_TITLE="${KEEPER_RECORD_PREFIX}${USER_NAME}"
KEEPER_ENABLED=0
[[ -n "${KEEPER_CONFIG:-}" ]] && KEEPER_ENABLED=1

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
export TF_IN_AUTOMATION=1
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_server_id="$TRANSFER_SERVER_ID"
export TF_VAR_bucket_name="$S3_BUCKET"
export TF_VAR_role_arn="$TRANSFER_ROLE_ARN"

log() { printf '[%s] ==> %s\n' "$USER_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$USER_NAME" "$*" >&2; exit 1; }

log "starting (mode=$MODE, path=$USER_PATH, key type=$KEY_TYPE, keeper=$([[ $KEEPER_ENABLED -eq 1 ]] && echo enabled || echo disabled))"

log "checking required tools are installed"
for bin in aws terraform jq sftp ssh-keygen; do
  command -v "$bin" >/dev/null || die "'$bin' is not installed or not on PATH"
done
if [[ $KEEPER_ENABLED -eq 1 ]]; then
  command -v "$KEEPER_CLI" >/dev/null || die "KEEPER_CONFIG is set but '$KEEPER_CLI' is not installed or not on PATH"
fi

KEY_BASE="${TMPDIR:-/tmp}"
KEY_BASE="${KEY_BASE%/}"
[[ -d "$KEY_BASE" ]] || die "temp directory '$KEY_BASE' does not exist"

WORK="$(mktemp -d "$KEY_BASE/sftp-user.XXXXXX")"
chmod 700 "$WORK"
KEY="$WORK/id"
VARS="$WORK/users.tfvars.json"

TF_CREATED=0        # 1 while a user exists that has not been fully delivered
RESUME=0            # 1 = user already existed without a saved key; only
                     # finish that leftover work, don't treat this as a
                     # brand-new user for rollback purposes
KEEPER_ONLY=0        # 1 = AWS + local key are already done; only the Keeper
                     # upload is outstanding, so skip straight to it

tf() { terraform -chdir="$TF_DIR" "$@"; }

cleanup() {
  local rc=$?
  trap - EXIT

  if [[ $rc -ne 0 && $TF_CREATED -eq 1 ]]; then
    if [[ $RESUME -eq 1 ]]; then
      log "failed while resuming an existing user - rolling back just the new SSH key (the user itself pre-dates this run, so it's left alone)"
      tf destroy -auto-approve -input=false -var-file="$VARS" \
        -target="aws_transfer_ssh_key.this[\"$USER_NAME\"]" \
        || log "ROLLBACK FAILED: remove the SSH key you just tried to attach for user '$USER_NAME' by hand"
    else
      log "failed after creating the user - rolling back"
      tf destroy -auto-approve -input=false -var-file="$VARS" \
        || log "ROLLBACK FAILED: delete user '$USER_NAME' and state key sftp-users/$USER_NAME.tfstate by hand"
    fi
  fi
  # Note: TF_CREATED is always reset to 0 before the Keeper upload is
  # attempted (see main, below) - so a Keeper failure never reaches this
  # rollback logic. Only a failure in steps 2-5 does.

  # This is the transient copy in $WORK, not the permanent one in
  # SFTP_KEYS_DIR (that copy is made deliberately, in save_keys_locally, and
  # is meant to persist - see the NOTE at the top of this file).
  if [[ -f "$KEY" ]]; then
    if command -v shred >/dev/null; then
      shred -u -z "$KEY" || rm -f "$KEY"
    else
      dd if=/dev/urandom of="$KEY" bs=1024 count="$(( ($(wc -c <"$KEY") / 1024) + 1 ))" conv=notrunc 2>/dev/null
      rm -f "$KEY"
    fi
  fi
  rm -f "$KEY.pub" 2>/dev/null
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT

# ----------------------------------------------------------------- Keeper ---
# Flat by design, confirmed against a live vault: Commander's non-interactive
# mode (--config=... "<command>") only ever runs ONE command - piped stdin,
# "&&", and ";" were all tried and none of them chain a cd into a following
# mkdir. `mkdir --help` also confirms it: mkdir only takes -uf/-sf (folder
# type) and, for shared folders, permission flags - there's no parent-path
# option at all. So there is no working non-interactive way to create or
# reference a NEW nested folder here.
#
# What IS confirmed working: record-add --folder "<one existing folder>",
# titled with the user's name, filed directly inside the one parent folder
# you create by hand ahead of time (KEEPER_FOLDER). No mkdir, no cd, no
# per-user subfolder.
keeper_upload_key() {
  local priv="$USER_KEY_DIR/id_${KEY_TYPE}"
  local pub="$USER_KEY_DIR/id_${KEY_TYPE}.pub"
  if [[ ! -f "$priv" || ! -f "$pub" ]]; then
    log "WARNING: no local key files found at $USER_KEY_DIR to upload"
    return 1
  fi

  log "uploading to Keeper as '${KEEPER_FOLDER:+$KEEPER_FOLDER/}$RECORD_TITLE'"
  # The key is sent base64-encoded, single line - embedding the raw PEM
  # (with its literal newlines) inside one Commander command string was a
  # plausible source of trouble on its own, so this stays regardless.
  local priv_b64 pub_b64 cmd out folder_arg=""
  priv_b64="$(base64 <"$priv" | tr -d '\n')"
  pub_b64="$(base64 <"$pub" | tr -d '\n')"
  [[ -n "$KEEPER_FOLDER" ]] && folder_arg=" --folder \"$KEEPER_FOLDER\""

  cmd="record-add --title \"$RECORD_TITLE\" --record-type login --force$folder_arg"
  cmd="$cmd \"login=$USER_NAME\""
  cmd="$cmd \"c.text.path=$USER_PATH\""
  cmd="$cmd \"c.text.public_key_b64=$pub_b64\""
  cmd="$cmd \"c.secret.private_key_b64=$priv_b64\""

  if out="$("$KEEPER_CLI" --config="$KEEPER_CONFIG" "$cmd" 2>&1)"; then
    touch "$USER_KEY_DIR/.keeper_uploaded"
    log "Keeper upload succeeded"
    return 0
  else
    log "WARNING: Keeper upload failed: $(tail -n 1 <<<"$out")"
    log "the key is safely saved locally at $USER_KEY_DIR either way - re-run apply to retry just the upload, or upload it by hand"
    return 1
  fi
}

# ------------------------------------------------------------ pre-checks ----
check_existing_user() {
  log "checking whether Transfer Family user '$USER_NAME' already exists"
  local out current expected
  if out="$(aws transfer describe-user --region "$AWS_REGION" --output json \
    --server-id "$TRANSFER_SERVER_ID" --user-name "$USER_NAME" 2>&1)"; then
    current="$(jq -r '.User.HomeDirectoryMappings[0].Target // .User.HomeDirectory // ""' <<<"$out")"
    current="${current%/}"
    expected="/${S3_BUCKET}/${USER_PATH}"
    if [[ "$current" != "$expected" ]]; then
      die "already exists but points to '$current' while users.yaml says '$expected'. The pipeline never changes existing users: fix users.yaml or change the user by hand"
    fi

    if [[ "$MODE" != "apply" ]]; then
      log "already exists with the same path - skipping"
      exit 10
    fi

    # User exists at the right path. That alone doesn't mean it's finished -
    # a previous run can have created the user and then failed before the
    # key was saved. Only treat the AWS+local part as done if a key is
    # already saved for it.
    if [[ ! -f "$USER_KEY_DIR/id_${KEY_TYPE}" ]]; then
      log "user exists but no saved key found at $USER_KEY_DIR - resuming: will generate a new key, attach it, test, and save it (the old, never-saved key is unusable and will be replaced)"
      RESUME=1
      return
    fi

    # AWS + local key are both done. If Keeper is enabled and this user
    # hasn't been uploaded yet, that's the only outstanding work - retry
    # just that, using the key already on disk, with no AWS changes at all.
    if [[ $KEEPER_ENABLED -eq 1 && ! -f "$USER_KEY_DIR/.keeper_uploaded" ]]; then
      log "user and local key are already set up, but not yet uploaded to Keeper - retrying just the upload"
      KEEPER_ONLY=1
      return
    fi

    log "already exists with the same path and nothing left to do - skipping"
    exit 10 # provision-all.sh treats this as "already exists, nothing to do"
  elif [[ "$out" != *ResourceNotFoundException* ]]; then
    die "could not check whether the user exists: $out"
  fi
}

# --------------------------------------------------------------- steps ------
generate_keys() {
  log "generating a fresh $KEY_TYPE keypair in $WORK"
  local bits=()
  if [[ "$KEY_TYPE" == "rsa" ]]; then bits=(-b 4096); fi
  ssh-keygen -q -t "$KEY_TYPE" ${bits[@]+"${bits[@]}"} -N "" -C "sftp-${USER_NAME}" -f "$KEY"
  chmod 600 "$KEY"
}

write_tfvars() {
  jq -n --arg user "$USER_NAME" --arg pub "$KEY.pub" --arg path "$USER_PATH" \
    '{users: {($user): {public_key_path: $pub, home_directory_target: $path}}}' >"$VARS"
}

tf_init() {
  log "initializing terraform (state: s3://$TF_STATE_BUCKET/sftp-users/${USER_NAME}.tfstate)"
  tf init -input=false -reconfigure \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=sftp-users/${USER_NAME}.tfstate" \
    -backend-config="region=$AWS_REGION" >/dev/null
}

test_connection() {
  log "testing the SFTP login with the new key against $SFTP_HOST"
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if sftp -i "$KEY" -b - \
      -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$WORK/known_hosts" \
      "${USER_NAME}@${SFTP_HOST}" <<<"pwd" >/dev/null 2>"$WORK/sftp.err"; then
      log "SFTP login works"
      return 0
    fi
    log "login attempt $attempt/6 failed: $(tail -n 1 "$WORK/sftp.err")"
    sleep 10
  done
  return 1
}

save_keys_locally() {
  log "saving the keypair to $USER_KEY_DIR"
  mkdir -p "$USER_KEY_DIR"
  chmod 700 "$USER_KEY_DIR"
  cp "$KEY" "$USER_KEY_DIR/id_${KEY_TYPE}"
  cp "$KEY.pub" "$USER_KEY_DIR/id_${KEY_TYPE}.pub"
  chmod 600 "$USER_KEY_DIR/id_${KEY_TYPE}"
  chmod 644 "$USER_KEY_DIR/id_${KEY_TYPE}.pub"
  # A small note, not sensitive itself - useful either for you to upload by
  # hand, or just as a record of what this key is for.
  printf 'user: %s\npath: %s\nserver: %s\n' "$USER_NAME" "$USER_PATH" "$SFTP_HOST" \
    >"$USER_KEY_DIR/info.txt"
}

# ---------------------------------------------------------------- main ------
check_existing_user

if [[ $KEEPER_ONLY -eq 1 ]]; then
  if keeper_upload_key; then
    log "done: key uploaded to Keeper (no AWS changes were needed)"
    exit 0
  else
    exit 1 # surfaces under "Failed" in provision-all.sh's summary - re-run to retry
  fi
fi

if [[ "$MODE" == "plan" ]]; then
  log "writing a placeholder public key (plan only needs terraform to read *a* public key file - no real keypair is generated until apply)"
  printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000 plan-placeholder-not-a-real-key\n' >"$KEY.pub"
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

test_connection || die "could not log in with the new key"

save_keys_locally
TF_CREATED=0   # AWS + local key are a done deal from here on - nothing below
               # this line can trigger a rollback

if [[ $KEEPER_ENABLED -eq 1 ]]; then
  if keeper_upload_key; then
    log "done: user set up, login tested, key saved locally and uploaded to Keeper"
  else
    exit 1 # AWS + local key are fine; only the Keeper upload needs a retry
  fi
else
  log "done: user set up, login tested, key saved locally (KEEPER_CONFIG not set, so Keeper upload was skipped)"
fi
