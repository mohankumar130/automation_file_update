#!/usr/bin/env bash
# deploy.sh — interactive deployment of selected repo files to a web root.
#
# Usage:
#   ./deploy.sh [--dry-run] [--base <web-root>] [--yes]
#
# The script prompts you for: environment type/level, git repo URL, branch,
# source subdir inside the repo, destination folder under the web root, and
# the list of files to deploy. It clones the repo, backs up any existing
# destination files, copies the new ones, and prints a summary.
#
# Options:
#   --dry-run          Preview every action without changing anything.
#   --base <web-root>  Override the web-root base (default /var/www/html).
#                      Handy for testing: --base /tmp/test-webroot
#   --yes, -y          Skip the live-deployment confirmation prompt.
#
# Examples:
#   ./deploy.sh --dry-run --base /tmp/test-webroot   # safe sandbox preview
#   sudo ./deploy.sh                                 # real run on the server

set -uo pipefail

# ---------- defaults / args ----------
DRY_RUN=0
ASSUME_YES=0
BASE_OVERRIDE=""
DEFAULT_BASE="/var/www/html"

log()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { echo "❌ ERROR: $*" >&2; exit 1; }

timestamp_date()      { date +"%d-%m-%Y"; }
timestamp_date_time() { date +"%d-%m-%Y-%H-%M-%S"; }

# run-or-echo wrapper: in dry-run, print the command instead of executing it
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   [dry-run] $*"
  else
    "$@"
  fi
}

usage() { sed -n '2,20p' "$0"; exit "${1:-0}"; }

# ---------- parse args ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --base)    BASE_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *)         die "Unknown option: $1 (use --help)" ;;
  esac
done

# ---------- required commands ----------
for cmd in git cp rm mkdir basename dirname date; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

# ---------- gather inputs (interactive) ----------
ENV_TYPE=""; ENV_LEVEL=""; REPO=""; BRANCH=""; DEST_FOLDER=""; SRC_SUBDIR=""
declare -a FILES=()

log "Enter deployment details."
read -rp "Environment type (odms/pulse): " ENV_TYPE
read -rp "Environment level (stage/prod): " ENV_LEVEL
read -rp "Git repo URL: " REPO
read -rp "Branch name: " BRANCH
read -rp "Source subdir inside repo (Enter for repo root): " SRC_SUBDIR
read -rp "Destination folder under web root (Enter for root): " DEST_FOLDER
echo "Enter file paths to deploy (Windows or Linux style)."
echo "One per line. Type 'done' (or a blank line) to finish."
while true; do
  read -rp "  path> " _p
  [[ -z "$_p" || "$_p" =~ ^(done|exit|DONE|EXIT)$ ]] && break
  FILES+=("$_p")
done

[ -z "$ENV_TYPE" ]        && die "Environment type is required"
[ -z "$ENV_LEVEL" ]       && die "Environment level is required"
[ -z "$REPO" ]            && die "Repo URL is required"
[ -z "$BRANCH" ]          && die "Branch is required"
[ "${#FILES[@]}" -eq 0 ]  && die "No files provided"

# ---------- resolve paths ----------
BASE_TARGET="${BASE_OVERRIDE:-$DEFAULT_BASE}"
if [ -n "$DEST_FOLDER" ]; then
  TARGET_BASE="$BASE_TARGET/${DEST_FOLDER#/}"
else
  TARGET_BASE="$BASE_TARGET"
fi

REPO_NAME="$(basename "$REPO" .git)"
TMP_DIR="/tmp/${REPO_NAME}.$$"   # unique per run to avoid stale-clone confusion

START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
HOST_V="$(hostname 2>/dev/null || echo unknown)"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

declare -a BACKUP_SRC=() BACKUP_DEST=() COPIED_FROM=() COPIED_TO=() SKIPPED=() ERRORS=()

# ---------- summary banner ----------
log "=========== DEPLOY PLAN ==========="
echo " Mode:           $([ "$DRY_RUN" -eq 1 ] && echo 'DRY-RUN (no changes)' || echo 'LIVE')"
echo " Environment:    $ENV_TYPE / $ENV_LEVEL"
echo " Repo:           $REPO"
echo " Branch:         $BRANCH"
echo " Source subdir:  ${SRC_SUBDIR:-<repo root>}"
echo " Web root base:  $BASE_TARGET"
echo " Target base:    $TARGET_BASE"
echo " Files:          ${#FILES[@]}"
for f in "${FILES[@]}"; do echo "    - $f"; done
echo "-----------------------------------"

# ---------- confirm for live runs ----------
if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  read -rp "Proceed with LIVE deployment to '$TARGET_BASE'? (yes/no): " ans
  [[ "$ans" =~ ^(yes|YES|y|Y)$ ]] || die "Aborted by user."
fi

# ---------- clone ----------
clone_repo() {
  local repo="$1" branch="$2"
  [ -d "$TMP_DIR" ] && run rm -rf "$TMP_DIR"
  log "Cloning '$repo' (branch: $branch) into $TMP_DIR ..."
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "   [dry-run] git clone --branch $branch --depth 1 $repo $TMP_DIR"
    return 0
  fi
  if git clone --branch "$branch" --depth 1 "$repo" "$TMP_DIR" >/dev/null 2>&1; then
    return 0
  fi
  log "Shallow branch clone failed; trying full clone + checkout..."
  if git clone "$repo" "$TMP_DIR" >/dev/null 2>&1; then
    ( cd "$TMP_DIR" && git checkout "$branch" >/dev/null 2>&1 ) && return 0
    die "Branch '$branch' not found in $repo"
  fi
  die "git clone failed for $repo"
}

clone_repo "$REPO" "$BRANCH"

# Resolve source root (repo root + optional subdir)
SRC_ROOT="$TMP_DIR"
[ -n "$SRC_SUBDIR" ] && SRC_ROOT="$TMP_DIR/${SRC_SUBDIR#/}"

if [ "$DRY_RUN" -eq 0 ] && [ -n "$SRC_SUBDIR" ] && [ ! -d "$SRC_ROOT" ]; then
  die "Source subdir not found in repo: $SRC_ROOT"
fi

# ---------- backup helper ----------
# Backup name always includes DATE + TIME (to the second) so repeated deploys of
# the same file never overwrite an earlier backup. If two backups land in the
# same second, a numeric counter (-1, -2, ...) guarantees uniqueness.
backup_file() {
  local src="$1" dir name base ext stamp newname dest n
  dir="$(dirname "$src")"; name="$(basename "$src")"
  if [[ "$name" == *.* ]]; then base="${name%.*}"; ext=".${name##*.}"; else base="$name"; ext=""; fi
  stamp="$(timestamp_date_time)"                 # DD-MM-YYYY-HH-MM-SS
  newname="$base-$stamp$ext"
  # collision safety net for same-second repeats
  n=1
  while [ -e "$dir/$newname" ]; do
    newname="$base-$stamp-$n$ext"
    n=$((n + 1))
  done
  dest="$dir/$newname"
  if [ "$DRY_RUN" -eq 1 ]; then echo "$dest"; return 0; fi
  cp -p "$src" "$dest" && { echo "$dest"; return 0; }
  return 2
}

# ---------- copy loop ----------
for rel in "${FILES[@]}"; do
  # normalize windows backslashes -> forward, strip leading slashes
  rel_unix="$(printf '%s' "$rel" | tr '\\' '/' | sed 's#^/*##')"
  src="$SRC_ROOT/$rel_unix"
  dest="$TARGET_BASE/$rel_unix"

  log "Processing: $rel_unix"
  log "   src=$src"
  log "   dest=$dest"

  if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$src" ]; then
    log "   ⚠️  source file not found — skipping"
    SKIPPED+=("$rel_unix")
    continue
  fi
  if [ "$DRY_RUN" -eq 1 ] && [ ! -f "$src" ]; then
    log "   (dry-run) source not present yet in this sandbox"
  fi

  run mkdir -p "$(dirname "$dest")"

  # backup existing destination
  if [ -f "$dest" ]; then
    bkp="$(backup_file "$dest")"
    if [ $? -eq 0 ]; then
      BACKUP_SRC+=("$dest"); BACKUP_DEST+=("$bkp")
      log "   backup: $dest -> $bkp"
    else
      ERRORS+=("backup-failed:$rel_unix")
    fi
  fi

  if run cp -p "$src" "$dest"; then
    COPIED_FROM+=("$src"); COPIED_TO+=("$dest")
    log "   ✅ copied"
  else
    ERRORS+=("copy-failed:$rel_unix")
    log "   ❌ copy failed"
  fi
done

END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

# ---------- summary ----------
echo
log "=========== DEPLOYMENT SUMMARY ==========="
echo " Mode:            $([ "$DRY_RUN" -eq 1 ] && echo DRY-RUN || echo LIVE)"
echo " Environment:     $ENV_TYPE / $ENV_LEVEL"
echo " Repo / Branch:   $REPO ($BRANCH)"
echo " Source subdir:   ${SRC_SUBDIR:-<repo root>}"
echo " Target base:     $TARGET_BASE"
echo " Host / IP:       $HOST_V / $SERVER_IP"
echo " Start / End:     $START_TIME  ->  $END_TIME"
echo "------------------------------------------"
if [ "${#BACKUP_SRC[@]}" -gt 0 ]; then
  echo " Backups:"
  for i in "${!BACKUP_SRC[@]}"; do echo "   - ${BACKUP_SRC[$i]}  ->  ${BACKUP_DEST[$i]}"; done
else echo " No backups created."; fi
if [ "${#COPIED_FROM[@]}" -gt 0 ]; then
  echo " Copied:"
  for i in "${!COPIED_FROM[@]}"; do echo "   - ${COPIED_FROM[$i]}  ->  ${COPIED_TO[$i]}"; done
else echo " No files copied."; fi
[ "${#SKIPPED[@]}" -gt 0 ] && { echo " Skipped:"; for s in "${SKIPPED[@]}"; do echo "   - $s"; done; }
if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo " Errors:"; for e in "${ERRORS[@]}"; do echo "   - $e"; done
  echo " ⚠️  Review errors above."
else echo " ✅ No errors."; fi
echo "------------------------------------------"
echo " Temp clone: $TMP_DIR $([ "$DRY_RUN" -eq 1 ] && echo '(not created in dry-run)')"
echo "=========================================="

# cleanup temp clone on live runs
if [ "$DRY_RUN" -eq 0 ] && [ -d "$TMP_DIR" ]; then
  rm -rf "$TMP_DIR"
fi
