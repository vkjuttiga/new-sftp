#!/usr/bin/env bash
#
# enable_codeowners.sh
#
# Changes "manage_codeowners: false" -> "manage_codeowners: true" in
# repository.yaml files, touching ONLY the paths you pass in.
#
# Usage:
#   ./enable_codeowners.sh [options] <path> [<path> ...]
#
#   <path> can be:
#     - a repositories folder  e.g. abc/repositories
#         -> processes ONLY abc/repositories/<appname>/repository.yaml
#            (one level of app folders; nothing deeper, nothing at the top)
#     - an exact file path     e.g. abc/repositories/appname/repository.yaml
#
# Options:
#   --dry-run            Show what would change, but don't modify anything.
#   --branch <name>      Stop unless the repo is currently on exactly this branch.
#   --report-dir <dir>   Where to save the CSV report
#                        (default: ~/codeowners-reports, outside the repo).
#   --verbose            Print every file in the terminal, not just problems.
#
# Git safety checks (read-only, run BEFORE any file is touched):
#   - All target files must be inside the same Git repository.
#   - Stops on protected branches: main, master, develop, release/*,
#     or a detached HEAD.
#   - Stops if any target file already has uncommitted changes.
#   - Never checks out, creates, commits or pushes anything.
#
# Rules:
#   - Only the value on the manage_codeowners line is changed; indentation,
#     comments, other keys, line endings and file permissions are kept as-is.
#   - Files with 2+ manage_codeowners keys are FLAGGED and NOT modified.
#   - Files where the value is not exactly false/true are reported and skipped.
#
# Works with the default macOS bash (3.2), perl and awk.
#
# END OF HELP

FILE_NAME="repository.yaml"
DRY_RUN=0
VERBOSE=0
EXPECTED_BRANCH=""
REPORT_DIR="$HOME/codeowners-reports"
INPUTS=()

EN_DASH=$'\xe2\x80\x93'   # –  (macOS smart punctuation often turns -- into these)
EM_DASH=$'\xe2\x80\x94'   # —

while [ $# -gt 0 ]; do
  arg="$1"
  # Turn any leading mix of -, – and — back into a plain "--"
  case "$arg" in
    "$EN_DASH"*|"$EM_DASH"*|-"$EN_DASH"*|-"$EM_DASH"*)
      while :; do
        case "$arg" in
          -*)          arg="${arg#-}" ;;
          "$EN_DASH"*) arg="${arg#"$EN_DASH"}" ;;
          "$EM_DASH"*) arg="${arg#"$EM_DASH"}" ;;
          *) break ;;
        esac
      done
      arg="--$arg" ;;
  esac
  # Accept --branch=name and --report-dir=dir as well
  case "$arg" in
    --branch=*)     EXPECTED_BRANCH="${arg#--branch=}"; shift; continue ;;
    --report-dir=*) REPORT_DIR="${arg#--report-dir=}"; shift; continue ;;
  esac
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --verbose) VERBOSE=1 ;;
    --branch)
      case "$2" in ""|-*) echo "ERROR: --branch needs a branch name, e.g. --branch feature/codeowners" >&2; exit 1 ;; esac
      EXPECTED_BRANCH="$2"; shift ;;
    --report-dir)
      case "$2" in ""|-*) echo "ERROR: --report-dir needs a folder." >&2; exit 1 ;; esac
      REPORT_DIR="$2"; shift ;;
    -h|--help) sed -n '2,/^# END OF HELP/p' "$0" | grep -v 'END OF HELP' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "ERROR: unknown option '$arg' (see --help)" >&2; exit 1 ;;
    *) INPUTS+=("$arg") ;;
  esac
  shift
done

if [ -n "$EXPECTED_BRANCH" ] && [ "${EXPECTED_BRANCH#-}" != "$EXPECTED_BRANCH" ]; then
  echo "ERROR: branch name '$EXPECTED_BRANCH' starts with '-'. Use: --branch <name>" >&2; exit 1
fi

if [ ${#INPUTS[@]} -eq 0 ]; then
  echo "Usage: $0 [--dry-run] [--branch <name>] <folder-or-file> [...]   (see --help)" >&2
  exit 1
fi

command -v git  >/dev/null 2>&1 || { echo "ERROR: git not found."  >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "ERROR: perl not found." >&2; exit 1; }

# Colors only when printing to a terminal
if [ -t 1 ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'; IS_TTY=1
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; BOLD=""; DIM=""; RESET=""; IS_TTY=0
fi

KEY_REGEX='^[[:space:]]*manage_codeowners[[:space:]]*:'
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/enable_codeowners.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
ROWS="$WORK_DIR/rows.tsv"; : > "$ROWS"

N_CHANGED=0; N_WOULD=0; N_TRUE=0; N_FLAGGED=0; N_NOKEY=0; N_UNEXPECTED=0; N_ERROR=0
ATTENTION=()

abort () {
  echo "" >&2
  echo "${RED}${BOLD}STOPPED - no files were modified.${RESET}" >&2
  for line in "$@"; do echo "${RED}   $line${RESET}" >&2; done
  exit 3
}

clear_progress () { [ $IS_TTY -eq 1 ] && printf '\r\033[K'; }

# record <STATUS> <file> <line> <detail>
record () {
  local status="$1" file="$2" line="$3" detail="$4" color=""
  printf '%s\t%s\t%s\t%s\n' "$status" "$file" "$line" "$(printf '%s' "$detail" | tr '\t\n' '  ')" >> "$ROWS"
  case "$status" in
    CHANGED)        N_CHANGED=$((N_CHANGED+1));       color="$GREEN"  ;;
    "WOULD CHANGE") N_WOULD=$((N_WOULD+1));           color="$BLUE"   ;;
    "ALREADY TRUE") N_TRUE=$((N_TRUE+1));             color="$GREEN"  ;;
    FLAGGED)        N_FLAGGED=$((N_FLAGGED+1));       color="$RED"    ;;
    "NO KEY")       N_NOKEY=$((N_NOKEY+1));           color="$YELLOW" ;;
    UNEXPECTED)     N_UNEXPECTED=$((N_UNEXPECTED+1)); color="$YELLOW" ;;
    ERROR)          N_ERROR=$((N_ERROR+1));           color="$RED"    ;;
  esac
  case "$status" in
    FLAGGED|"NO KEY"|UNEXPECTED|ERROR)
      ATTENTION+=("$(printf '%-12s' "$status") $file  -  $detail")
      clear_progress
      printf '%s%-12s%s %s  %s(%s)%s\n' "$color" "$status" "$RESET" "$file" "$DIM" "$detail" "$RESET" ;;
    *)
      if [ $VERBOSE -eq 1 ]; then
        clear_progress
        printf '%s%-12s%s %s\n' "$color" "$status" "$RESET" "$file"
      fi ;;
  esac
}

# ---------- collect target files ----------
FILES=()
PRE_ERRORS=()
for p in "${INPUTS[@]}"; do
  p="${p%/}"
  if [ -f "$p" ]; then
    if [ "$(basename "$p")" != "$FILE_NAME" ]; then
      PRE_ERRORS+=("$p"$'\t'"not a $FILE_NAME file, skipped"); continue
    fi
    FILES+=("$p")
  elif [ -d "$p" ]; then
    found=0
    # Only <folder>/<appname>/repository.yaml - exactly one level down
    while IFS= read -r -d '' f; do
      FILES+=("$f"); found=1
    done < <(find "$p" -mindepth 2 -maxdepth 2 -type f -name "$FILE_NAME" -not -path '*/.git/*' -print0 | sort -z)
    [ $found -eq 0 ] && PRE_ERRORS+=("$p"$'\t'"no <appname>/$FILE_NAME found in this folder")
  else
    PRE_ERRORS+=("$p"$'\t'"path does not exist")
  fi
done

if [ ${#PRE_ERRORS[@]} -gt 0 ]; then
  MSGS=("Problem with the path(s) you passed:")
  for e in "${PRE_ERRORS[@]}"; do MSGS+=("  '${e%%$'\t'*}'  ->  ${e#*$'\t'}"); done
  MSGS+=("" "Usage: $0 [--dry-run] [--branch <name>] abc/repositories"
         "Tip: type the command directly in Terminal. Copying it through Notes/Slack/Mail"
         "     can change -- into a long dash, which then looks like a path.")
  abort "${MSGS[@]}"
fi

# ---------- Git pre-flight checks (read-only) ----------
REPO_ROOT=""
for f in "${FILES[@]}"; do
  root=$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null)
  [ -z "$root" ] && abort "$f is not inside a Git repository."
  if [ -z "$REPO_ROOT" ]; then REPO_ROOT="$root"
  elif [ "$root" != "$REPO_ROOT" ]; then
    abort "Files span more than one Git repository:" "  $REPO_ROOT" "  $root"
  fi
done

BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
case "$BRANCH" in
  HEAD|"") abort "Repo is in detached HEAD state. Check out your working branch first." ;;
  main|master|develop|release/*)
    abort "You are on protected branch '$BRANCH'." \
          "Check out your working branch first, e.g.: git checkout <your-branch>" ;;
esac
if [ -n "$EXPECTED_BRANCH" ] && [ "$BRANCH" != "$EXPECTED_BRANCH" ]; then
  abort "Current branch is '$BRANCH', but --branch expected '$EXPECTED_BRANCH'."
fi

DIRTY=()
for f in "${FILES[@]}"; do
  st=$(git -C "$(dirname "$f")" status --porcelain -- "$(basename "$f")" 2>/dev/null)
  [ -n "$st" ] && DIRTY+=("$f  (git status: $(echo "$st" | cut -c1-2))")
done
if [ ${#DIRTY[@]} -gt 0 ]; then
  SHOW=("${DIRTY[@]:0:10}")
  [ ${#DIRTY[@]} -gt 10 ] && SHOW+=("... and $(( ${#DIRTY[@]} - 10 )) more (see: git status)")
  abort "${#DIRTY[@]} target file(s) already have uncommitted changes." \
        "If you already ran this script, review with: git diff --stat" \
        "Otherwise commit, stash or revert them first:" "${SHOW[@]}"
fi

# Report location (warn if it would land inside the repo)
mkdir -p "$REPORT_DIR" 2>/dev/null || abort "Cannot create report folder: $REPORT_DIR"
REPORT_DIR=$(cd "$REPORT_DIR" && pwd)
case "$REPORT_DIR/" in
  "$REPO_ROOT"/*) abort "Report folder is inside the repo ($REPORT_DIR)." \
                        "It would show up in git status. Use a folder outside the repo." ;;
esac

MODE="APPLIED"; [ $DRY_RUN -eq 1 ] && MODE="DRY RUN"
echo "${BOLD}manage_codeowners: false -> true${RESET}   ${DIM}($MODE)${RESET}"
echo "Repo   : $REPO_ROOT"
echo "Branch : ${BOLD}$BRANCH${RESET}"
echo "Files  : ${#FILES[@]}"
echo "------------------------------------------------------------"

for e in "${PRE_ERRORS[@]}"; do record "ERROR" "${e%%$'\t'*}" "-" "${e#*$'\t'}"; done

get_value () {   # value after the colon, minus comment, whitespace and CR
  grep -E "$KEY_REGEX" "$1" | tr -d '\r' \
    | sed -E 's/^[[:space:]]*manage_codeowners[[:space:]]*:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//'
}

# ---------- process each file ----------
TOTAL=${#FILES[@]}; i=0
for f in "${FILES[@]}"; do
  i=$((i+1))
  [ $IS_TTY -eq 1 ] && [ $VERBOSE -eq 0 ] && printf '\r%sProcessing %d/%d ...%s' "$DIM" "$i" "$TOTAL" "$RESET"

  if [ ! -r "$f" ] || [ ! -w "$f" ]; then record "ERROR" "$f" "-" "not readable/writable"; continue; fi

  count=$(grep -cE "$KEY_REGEX" "$f")
  if [ "$count" -eq 0 ]; then record "NO KEY" "$f" "-" "manage_codeowners key not found"; continue; fi
  if [ "$count" -ge 2 ]; then
    lines=$(grep -nE "$KEY_REGEX" "$f" | cut -d: -f1 | paste -sd, -)
    record "FLAGGED" "$f" "$lines" "$count occurrences - not modified, review manually"; continue
  fi

  lineno=$(grep -nE "$KEY_REGEX" "$f" | cut -d: -f1)
  value=$(get_value "$f")

  case "$value" in
    true)  record "ALREADY TRUE" "$f" "$lineno" "already true, no change needed" ;;
    false)
      if [ $DRY_RUN -eq 1 ]; then record "WOULD CHANGE" "$f" "$lineno" "false -> true"; continue; fi
      backup="$WORK_DIR/$i.bak"; cp -p "$f" "$backup"
      perl -pi -e 's/^(\s*manage_codeowners\s*:\s*)false\b/${1}true/' "$f"
      removed=$(diff "$backup" "$f" | grep -c '^<')
      added=$(diff "$backup" "$f" | grep -c '^>')
      if [ "$removed" -eq 1 ] && [ "$added" -eq 1 ] && [ "$(get_value "$f")" = "true" ]; then
        record "CHANGED" "$f" "$lineno" "false -> true"
      else
        cp -p "$backup" "$f"
        record "ERROR" "$f" "$lineno" "verification failed, file restored to original"
      fi ;;
    *) record "UNEXPECTED" "$f" "$lineno" "value is '$value' - not modified" ;;
  esac
done
clear_progress

# ---------- write CSV report ----------
# Columns: Status, App, File, Line, Details
# Rows needing attention come first, then changed, then already true.
STAMP=$(date '+%Y%m%d_%H%M%S')
SAFE_BRANCH=$(printf '%s' "$BRANCH" | tr -c 'A-Za-z0-9._-' '_')
CSV="$REPORT_DIR/codeowners_${SAFE_BRANCH}_${STAMP}.csv"

{ echo 'Status,App,File,Line,Details'
  awk -F'\t' '
    function q(s){ gsub(/"/,"\"\"",s); return "\"" s "\"" }
    BEGIN{ o["FLAGGED"]=1; o["UNEXPECTED"]=2; o["NO KEY"]=3; o["ERROR"]=4
           o["CHANGED"]=5; o["WOULD CHANGE"]=5; o["ALREADY TRUE"]=6 }
    { n=split($2,parts,"/"); app=(n>=2 ? parts[n-1] : "-")
      printf "%d\t%s\n", o[$1], q($1) "," q(app) "," q($2) "," q($3) "," q($4) }' "$ROWS" \
  | sort -t "$(printf '\t')" -k1,1n -s | cut -f2-
} > "$CSV"

N_ATT=$((N_FLAGGED + N_NOKEY + N_UNEXPECTED + N_ERROR))
N_ROWS=$(wc -l < "$ROWS" | tr -d ' ')

# ---------- terminal summary ----------
echo ""
echo "============================================================"
echo "${BOLD}SUMMARY${RESET}  ($MODE on branch '$BRANCH')"
echo "============================================================"
printf '  %-22s %s\n' "Files checked"      "$N_ROWS"
if [ $DRY_RUN -eq 1 ]; then printf '  %-22s %s\n' "Would change" "${BLUE}$N_WOULD${RESET}"
else printf '  %-22s %s\n' "Changed false->true" "${GREEN}$N_CHANGED${RESET}"; fi
printf '  %-22s %s\n' "Already true"       "$N_TRUE"
printf '  %-22s %s\n' "Flagged (2+ keys)"  "$( [ $N_FLAGGED -gt 0 ] && echo "${RED}$N_FLAGGED${RESET}" || echo 0 )"
printf '  %-22s %s\n' "Key not found"      "$( [ $N_NOKEY -gt 0 ] && echo "${YELLOW}$N_NOKEY${RESET}" || echo 0 )"
printf '  %-22s %s\n' "Unexpected value"   "$( [ $N_UNEXPECTED -gt 0 ] && echo "${YELLOW}$N_UNEXPECTED${RESET}" || echo 0 )"
printf '  %-22s %s\n' "Errors"             "$( [ $N_ERROR -gt 0 ] && echo "${RED}$N_ERROR${RESET}" || echo 0 )"
echo ""
if [ $N_ATT -gt 0 ]; then
  echo "${RED}${BOLD}$N_ATT file(s) need your attention${RESET} (listed above, and at the top of the CSV)."
else
  echo "${GREEN}No problems found.${RESET}"
fi
echo ""
echo "CSV report : $CSV"
echo "Open it    : open \"$CSV\""
if [ $DRY_RUN -eq 0 ] && [ $N_CHANGED -gt 0 ]; then
  echo ""
  echo "Next steps on '$BRANCH' (nothing was committed):  git status  /  git diff --stat"
fi

[ $N_ATT -gt 0 ] && exit 2
exit 0
