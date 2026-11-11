#!/usr/bin/env bash
#
# enable_codeowners.sh
#
# Changes "manage_codeowners: false" -> "manage_codeowners: true" in
# repositories.yaml files, touching ONLY the paths you pass in.
#
# Usage:
#   ./enable_codeowners.sh [--dry-run] [--branch <name>] <path> [<path> ...]
#
#   <path> can be:
#     - an exact file path   e.g. config/team-a/repositories.yaml
#     - a folder path        e.g. config/   (every repositories.yaml inside it,
#                                             at any depth, is processed)
#
#   --dry-run          Show what would change, but don't modify anything.
#   --branch <name>    Stop unless the repo is currently on exactly this branch.
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
# Works with the default macOS bash (3.2) and macOS's built-in perl.

DRY_RUN=0
EXPECTED_BRANCH=""
INPUTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --branch)
      [ -z "$2" ] && { echo "ERROR: --branch needs a branch name." >&2; exit 1; }
      EXPECTED_BRANCH="$2"; shift ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) INPUTS+=("$1") ;;
  esac
  shift
done

if [ ${#INPUTS[@]} -eq 0 ]; then
  echo "Usage: $0 [--dry-run] [--branch <name>] <file-or-folder> [<file-or-folder> ...]" >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || { echo "ERROR: git not found." >&2; exit 1; }

command -v perl >/dev/null 2>&1 || { echo "ERROR: perl not found." >&2; exit 1; }

# Colors only when printing to a terminal
if [ -t 1 ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'
  BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; BOLD=""; RESET=""
fi

KEY_REGEX='^[[:space:]]*manage_codeowners[[:space:]]*:'
BACKUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/enable_codeowners.XXXXXX")
trap 'rm -rf "$BACKUP_DIR"' EXIT

# Result buckets (plain arrays, bash 3.2 compatible)
CHANGED=(); WOULD_CHANGE=(); ALREADY_TRUE=(); FLAGGED=()
NOT_FOUND=(); UNEXPECTED=(); ERRORS=()
TOTAL=0

# ---------- collect target files ----------
FILES=()
for p in "${INPUTS[@]}"; do
  if [ -f "$p" ]; then
    FILES+=("$p")
  elif [ -d "$p" ]; then
    found=0
    while IFS= read -r -d '' f; do
      FILES+=("$f"); found=1
    done < <(find "$p" -type f -name 'repositories.yaml' -not -path '*/.git/*' -print0 | sort -z)
    [ $found -eq 0 ] && ERRORS+=("$p  ->  no repositories.yaml found in this folder")
  else
    ERRORS+=("$p  ->  path does not exist")
  fi
done

abort () {
  echo "" >&2
  echo "${RED}${BOLD}STOPPED - no files were modified.${RESET}" >&2
  for line in "$@"; do echo "${RED}   $line${RESET}" >&2; done
  exit 3
}

if [ ${#FILES[@]} -eq 0 ]; then
  for e in "${ERRORS[@]}"; do echo "${RED}$e${RESET}" >&2; done
  abort "No repositories.yaml files to process."
fi

# ---------- Git pre-flight checks (read-only) ----------
REPO_ROOT=""
for f in "${FILES[@]}"; do
  root=$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null)
  [ -z "$root" ] && abort "$f is not inside a Git repository."
  if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$root"
  elif [ "$root" != "$REPO_ROOT" ]; then
    abort "Files span more than one Git repository:" "  $REPO_ROOT" "  $root"
  fi
done

BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)

case "$BRANCH" in
  HEAD|"")
    abort "Repo is in detached HEAD state. Check out your working branch first." ;;
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
  abort "These files already have uncommitted changes (commit, stash or revert them first):" \
        "${DIRTY[@]}"
fi

echo "${BOLD}manage_codeowners: false -> true${RESET}"
echo "Repo   : $REPO_ROOT"
echo "Branch : ${BOLD}$BRANCH${RESET}"
[ $DRY_RUN -eq 1 ] && echo "${BLUE}DRY RUN - no files will be modified${RESET}"
echo "------------------------------------------------------------"

# ---------- process each file ----------
for f in "${FILES[@]}"; do
  TOTAL=$((TOTAL + 1))

  if [ ! -r "$f" ] || [ ! -w "$f" ]; then
    ERRORS+=("$f  ->  not readable/writable"); echo "${RED}[ERROR]${RESET}     $f"; continue
  fi

  count=$(grep -cE "$KEY_REGEX" "$f")

  if [ "$count" -eq 0 ]; then
    NOT_FOUND+=("$f"); echo "${YELLOW}[NO KEY]${RESET}    $f"; continue
  fi

  if [ "$count" -ge 2 ]; then
    lines=$(grep -nE "$KEY_REGEX" "$f" | cut -d: -f1 | paste -sd, -)
    FLAGGED+=("$f  ->  $count occurrences on lines $lines")
    echo "${RED}[FLAGGED]${RESET}   $f  ($count occurrences, lines $lines) - not modified"
    continue
  fi

  lineno=$(grep -nE "$KEY_REGEX" "$f" | cut -d: -f1)
  # value = text after the colon, minus comment, whitespace and any CR
  value=$(grep -E "$KEY_REGEX" "$f" | tr -d '\r' \
          | sed -E 's/^[[:space:]]*manage_codeowners[[:space:]]*:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//')

  case "$value" in
    true)
      ALREADY_TRUE+=("$f  (line $lineno)")
      echo "${GREEN}[OK]${RESET}        $f  (already true)"
      ;;
    false)
      if [ $DRY_RUN -eq 1 ]; then
        WOULD_CHANGE+=("$f  (line $lineno)")
        echo "${BLUE}[WOULD FIX]${RESET} $f  (line $lineno)"
        continue
      fi

      backup="$BACKUP_DIR/$TOTAL.bak"
      cp -p "$f" "$backup"

      # Change ONLY the word "false" on that one line; everything else untouched
      perl -pi -e 's/^(\s*manage_codeowners\s*:\s*)false\b/${1}true/' "$f"

      # Verify: exactly one line changed, and it now says true
      removed=$(diff "$backup" "$f" | grep -c '^<')
      added=$(diff "$backup" "$f" | grep -c '^>')
      newval=$(grep -E "$KEY_REGEX" "$f" | tr -d '\r' \
               | sed -E 's/^[[:space:]]*manage_codeowners[[:space:]]*:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//')

      if [ "$removed" -eq 1 ] && [ "$added" -eq 1 ] && [ "$newval" = "true" ]; then
        CHANGED+=("$f  (line $lineno)")
        echo "${GREEN}[CHANGED]${RESET}   $f  (line $lineno)"
      else
        cp -p "$backup" "$f"   # restore original
        ERRORS+=("$f  ->  verification failed, file restored to original")
        echo "${RED}[ERROR]${RESET}     $f  (verification failed, restored)"
      fi
      ;;
    *)
      UNEXPECTED+=("$f  (line $lineno)  ->  value is '$value'")
      echo "${YELLOW}[SKIPPED]${RESET}   $f  (unexpected value '$value')"
      ;;
  esac
done

# ---------- summary ----------
print_section () {   # $1 = color, $2 = title, rest = items
  local color="$1" title="$2"; shift 2
  [ $# -eq 0 ] && return
  echo ""
  echo "${color}${BOLD}$title ($#)${RESET}"
  for item in "$@"; do echo "   - $item"; done
}

echo ""
echo "============================================================"
echo "${BOLD}SUMMARY${RESET}"
echo "============================================================"
echo "Repo                 : $REPO_ROOT"
echo "Branch               : $BRANCH"
echo "Files checked        : $TOTAL"
if [ $DRY_RUN -eq 1 ]; then
  echo "Would be changed     : ${#WOULD_CHANGE[@]}"
else
  echo "Changed false->true  : ${#CHANGED[@]}"
fi
echo "Already true         : ${#ALREADY_TRUE[@]}"
echo "Flagged (2+ keys)    : ${#FLAGGED[@]}"
echo "Key not found        : ${#NOT_FOUND[@]}"
echo "Unexpected value     : ${#UNEXPECTED[@]}"
echo "Errors               : ${#ERRORS[@]}"

[ ${#CHANGED[@]}      -gt 0 ] && print_section "$GREEN"  "Changed"                                "${CHANGED[@]}"
[ ${#WOULD_CHANGE[@]} -gt 0 ] && print_section "$BLUE"   "Would change (dry run)"                 "${WOULD_CHANGE[@]}"
[ ${#ALREADY_TRUE[@]} -gt 0 ] && print_section "$GREEN"  "Already true (no change needed)"        "${ALREADY_TRUE[@]}"
[ ${#FLAGGED[@]}      -gt 0 ] && print_section "$RED"    "FLAGGED - multiple keys, review manually" "${FLAGGED[@]}"
[ ${#NOT_FOUND[@]}    -gt 0 ] && print_section "$YELLOW" "manage_codeowners key not found"        "${NOT_FOUND[@]}"
[ ${#UNEXPECTED[@]}   -gt 0 ] && print_section "$YELLOW" "Skipped - unexpected value"             "${UNEXPECTED[@]}"
[ ${#ERRORS[@]}       -gt 0 ] && print_section "$RED"    "Errors"                                 "${ERRORS[@]}"

echo ""
if [ $DRY_RUN -eq 0 ] && [ ${#CHANGED[@]} -gt 0 ]; then
  echo "Next steps on branch '$BRANCH' (nothing was committed):"
  echo "   git status"
  echo "   git diff"
fi

# Non-zero exit if anything needs your attention
if [ ${#FLAGGED[@]} -gt 0 ] || [ ${#ERRORS[@]} -gt 0 ] || [ ${#UNEXPECTED[@]} -gt 0 ]; then
  exit 2
fi
exit 0
