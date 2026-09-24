# SFTP user provisioning (AWS Transfer Family + Terraform + Keeper)

Creates SFTP users on an **existing** Transfer Family server, each locked into
their own folder of an **existing** S3 bucket, using a single shared IAM role
for permissions. The list of users lives in one file, `users.yaml`. Everything
runs from your own machine - there is no CI/CD pipeline.

Each key is generated in RAM, tested, uploaded to Keeper, and then wiped -
nothing ever touches permanent disk storage. Because of that, Keeper isn't
optional here: `apply` needs `KEEPER_CONFIG` set, since it's the only place
the key ends up.

## What this does (short version)

1. You add users (name + S3 folder path) to `users.yaml`.
2. You run `provision-all.sh`, which reads the file, checks it, and provisions
   each user that isn't already done. "Done" means the user exists in
   Transfer Family and its key has been uploaded to Keeper - tracked by a
   small local marker file, not the key itself. Adding new users and running
   `apply` again only touches those new users; anyone already done is left
   alone.
3. For each user that needs work:
   - `plan` mode never generates a real key - Terraform only needs to read
     *a* public key file, so a placeholder is used
   - `apply` generates a real RSA (4096-bit) key pair in RAM (`/dev/shm`, or
     `$TMPDIR` if that doesn't exist on this OS)
   - Terraform creates the user (or, if it already exists without a
     completed upload, just attaches a fresh key to it). There is no
     per-user IAM policy - every user gets exactly what the shared
     `TRANSFER_ROLE_ARN` role allows
   - the script logs in over SFTP with the new key to prove it works
   - only if that login succeeds is the private key uploaded to Keeper
   - the key is then shredded and every temp file removed, whether the run
     succeeded or failed
   - if anything fails along the way, whatever Terraform created is rolled
     back, so a re-run starts clean
4. The script prints what it's doing at every step (`==> ...` lines), and a
   summary of created / skipped / failed users at the end.

| File | Role |
|---|---|
| `users.yaml` | the list of users you edit |
| `scripts/provision-all.sh` | reads and validates `users.yaml`, loops over users |
| `scripts/provision-user.sh` | one user: skip check, keygen, Terraform, login test, Keeper upload |
| `terraform/` | generic module: Transfer Family user + SSH key |

Each user has its own Terraform state file, so provisioning one user never
touches another user's state.

## One-time setup

### 1. Tools

Install these on the machine you'll run the scripts from:

```bash
# AWS CLI, Terraform >= 1.10, jq, sftp client, ssh-keygen
# mikefarah yq v4 (NOT the python 'yq' package)
brew install awscli terraform jq yq        # macOS
# or on Ubuntu/Debian/WSL:
sudo apt install awscli jq openssh-client
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
# Terraform: https://developer.hashicorp.com/terraform/install
```

Check `yq --version` says `mikefarah/yq` - the Python `yq` package (`pip
install yq`) has different syntax and will not work here.

Your local AWS credentials (`aws configure`, an SSO profile, or
`AWS_PROFILE`) need permissions to manage Transfer Family users and read/write
the Terraform state bucket. See "AWS permissions" below.

### 2. Terraform state bucket

Any private, versioned, encrypted S3 bucket, separate from your SFTP data
bucket. Terraform >= 1.10 uses S3 native locking, so no DynamoDB table is
needed. Each user gets their own state file at
`s3://<TF_STATE_BUCKET>/sftp-users/<user>.tfstate`.

### 3. AWS permissions

Whatever AWS identity you run the scripts as (an IAM user or an assumed
role) needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TransferUsers",
      "Effect": "Allow",
      "Action": [
        "transfer:CreateUser", "transfer:UpdateUser", "transfer:DeleteUser",
        "transfer:DescribeUser", "transfer:ImportSshPublicKey", "transfer:DeleteSshPublicKey",
        "transfer:TagResource", "transfer:UntagResource", "transfer:ListTagsForResource"
      ],
      "Resource": [
        "arn:aws:transfer:REGION:ACCOUNT_ID:server/SERVER_ID",
        "arn:aws:transfer:REGION:ACCOUNT_ID:user/SERVER_ID/*"
      ]
    },
    {
      "Sid": "PassTheSharedRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::ACCOUNT_ID:role/YOUR_TRANSFER_ROLE",
      "Condition": { "StringEquals": { "iam:PassedToService": "transfer.amazonaws.com" } }
    },
    {
      "Sid": "StateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::STATE_BUCKET/sftp-users/*"
    },
    {
      "Sid": "StateList",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::STATE_BUCKET"
    }
  ]
}
```

`YOUR_TRANSFER_ROLE` is the existing IAM role Transfer Family assumes to
reach S3 (a different role from the one running these scripts).

### 4. Keeper

Needed for `apply` - `plan` and `validate` don't touch Keeper at all.

If you already have `keepercommander` installed and a `config.json` with a
persistent login session, you just need:

```bash
export KEEPER_CONFIG=/path/to/your/config.json
export KEEPER_FOLDER="Sftp-Keys"   # the parent folder you already created in Keeper
```

**Starting from scratch:** Commander installs without admin rights, no venv
required:

```bash
pip3 install --user keepercommander
keeper shell
# at the "My Vault>" prompt:
this-device register
this-device persistent-login on
this-device timeout 30d
quit
```

That writes a `config.json` you can point `KEEPER_CONFIG` at. **Never commit
it** - it holds a device token that keeps you logged in.

Every user's record is filed **directly inside** `KEEPER_FOLDER` (or the
Keeper root, if that's unset), titled with the user's own name (`acme`,
`globex`, ...), not nested in a subfolder. Only the **private** key is
uploaded - AWS already has the public key. It's stored base64-encoded (as a
`private_key_b64` custom field) rather than raw PEM text, to avoid feeding
Commander a value with embedded line breaks.

> **Why there's no per-user subfolder.** Confirmed against a live vault:
> Commander's non-interactive mode only ever runs one command at a time - it
> can't chain a `cd` into a following `mkdir`, and `mkdir` itself has no
> parent-path option. So every record goes straight into the one folder you
> create by hand, titled with the username instead of nested inside one.

**Reading a key back:** `get` needs an actual record UID, not a folder/title
path. Find the UID first - `search "<username>"`, `ls -l`/`ls -v` inside the
folder, or `list --format=json "$KEEPER_FOLDER"` all show it - then:

```bash
UID=YOUR_UID_HERE   # e.g. UID=9vVajHFwSjt71gO2C48zJA
keeper --config="$KEEPER_CONFIG" "get $UID --format=json" \
  | jq -r '[.. | objects | select(
        (.label // .name // .type // "") | ascii_downcase | contains("private")
      )][0].value | if type == "array" then .[0] else . end' \
  | base64 -d > acme.key   # macOS: base64 -D
chmod 600 acme.key
```

The `jq` filter searches for any field whose label mentions "private" rather
than an exact name, since Commander's exact casing isn't worth depending on.
Confirmed end to end: the field is found and decodes to the real key.

## Running it

```bash
export AWS_REGION=ap-south-1
export TRANSFER_SERVER_ID=s-0123456789abcdef0
export S3_BUCKET=my-sftp-bucket
export TRANSFER_ROLE_ARN=arn:aws:iam::123456789012:role/transfer-s3-role
export TF_STATE_BUCKET=my-tf-state

export KEEPER_CONFIG=/path/to/your/config.json
export KEEPER_FOLDER="Sftp-Keys"

bash scripts/provision-all.sh validate   # check users.yaml only, no cloud access
bash scripts/provision-all.sh plan       # + terraform plan per user, nothing created
bash scripts/provision-all.sh apply      # create the users for real
```

**Test with one throwaway user first.** Add a single entry to `users.yaml`,
run `plan`, read the output, then run `apply` and watch it go through each
step. Once that works end to end, add the rest of your users.

`users.yaml` behaviour:
- **Additive.** A user already done is skipped, so finished entries can stay
  in the file - add more whenever you like and re-run `apply`; only the new
  entries get processed.
- **Existing users are never changed.** If an existing user's path differs
  from the file, that user fails with a clear error instead of being modified.
- **Removing an entry does not delete the user** (see "Removing a user").

Validation is intentionally minimal: every entry needs a non-empty `name`
and `path`, and no two entries can share a name. That's it - it's a basic
sanity check, not a strict schema. Note that this means a `path` containing
`..` is no longer rejected; Terraform still only ever touches the S3 location
you give it, but it's worth knowing this check is gone if `users.yaml` is
ever populated from somewhere less trusted than your own hands.

### Recovering a half-done user

If a run creates the AWS user but fails before the Keeper upload finishes (a
crash, a network drop, Keeper rejecting the upload), that user is left with
no key anywhere - nothing was ever saved to disk to fall back on. Just run
`apply` again: it sees the user exists with no completed upload, generates a
fresh key, reattaches it (replacing the old, never-uploaded one), retests
the login, and uploads it. You don't need to do anything by hand or edit
`users.yaml` - the same entry that was already there is enough.

## Design notes

### Why keys are generated by the script, not by Terraform

Terraform *can* generate an SSH key pair itself (the `tls_private_key`
resource), which would cut a chunk of shell code. It isn't used here for one
reason: **`tls_private_key` stores the private key in the Terraform state
file**, in the clear as far as Terraform is concerned. That state file lives
in S3 for every user. Anyone who can read the state bucket could then read
every user's private key - the opposite of the "key only ever exists in RAM
and in Keeper" goal here.

### Why a "done" user is tracked by a marker file, not a key file

Nothing about a user's key is kept on disk once a run finishes, so there's
nothing to check for on the next run. A tiny empty file per user
(`SFTP_STATE_DIR/<user>`) plays that role instead - it holds no key
material, just a flag meaning "this user's key made it to Keeper." Deleting
it would make the next `apply` treat that user as unfinished and regenerate
their key.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `yq is not installed` / `wrong yq` | Install mikefarah/yq v4; the python `yq` package won't work. |
| `already exists but points to ...` | The user exists with a different path than `users.yaml`. The script never edits users: fix the file or change the user by hand. |
| `AccessDenied` on `transfer:CreateUser` / `iam:PassRole` | Your local AWS identity is missing a permission from "AWS permissions" above. |
| `AccessDenied` on the state bucket | Missing `s3:GetObject`/`PutObject`/`DeleteObject` on `sftp-users/*`, or `s3:ListBucket` on the bucket. |
| `Error acquiring the state lock` | A previous run was killed mid-way. Remove the leftover `.tflock` object for that user in the state bucket. |
| `login attempt 1/6 failed ...` six times, then rollback | Your machine can't reach the SFTP endpoint (VPC-only or IP-restricted server), or the server doesn't allow SSH key login. The user is deleted again automatically. |
| `this configuration doesn't support terraform version ...` | Your local Terraform is older than 1.10. Upgrade it (the state backend uses a 1.10+ feature), or ask to switch the backend to DynamoDB locking if you need to stay on an older version. |
| `keeper: command not found` | It's not on `PATH` (common with `pip3 install --user`, or a venv you haven't activated). Set `KEEPER_CLI` to its full path, e.g. `export KEEPER_CLI=~/.local/bin/keeper`. |
| Keeper upload fails, run exits non-zero | The user was rolled back - nothing partial is left behind. Fix whatever Keeper reported and re-run `apply`; it'll redo just that user. |
| Key material left behind after a crash | Shouldn't happen (the cleanup trap runs even on failure), but if a run is killed with `kill -9` or the machine loses power mid-run, check `/dev/shm` or `$TMPDIR` for a leftover `sftp-user.*` folder and delete it by hand. |

## Removing a user

Kept out of the scripts on purpose, so running `apply` again can never
delete access by accident. Delete the user from the Transfer server
(`terraform destroy` with the same state key, or the console/CLI), delete
the state object `sftp-users/<user>.tfstate`, delete
`SFTP_STATE_DIR/<user>`, and remove the entry from `users.yaml` (otherwise
the next run would create it again).
