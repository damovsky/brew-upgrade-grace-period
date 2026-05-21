#!/usr/bin/env bash
# ============================================================
#  brew-safe-upgrade  —  supply-chain-aware Homebrew upgrader
#
#  Only upgrades formulae/casks whose new version has been
#  published for at least MIN_AGE_DAYS days, giving the
#  community time to detect and report malicious releases.
#
#  Usage:
#    ./brew-safe-upgrade.sh              # default: 5-day gate
#    ./brew-safe-upgrade.sh --days 7     # custom age gate
#    ./brew-safe-upgrade.sh --dry-run    # preview only
#    ./brew-safe-upgrade.sh --casks      # include casks
#    ./brew-safe-upgrade.sh --log        # append to ~/brew-safe-upgrade.log
# ============================================================

set -euo pipefail

# ── defaults ────────────────────────────────────────────────
MIN_AGE_DAYS=5
DRY_RUN=false
INCLUDE_CASKS=false
LOG_ENABLED=false
LOG_FILE="$HOME/brew-safe-upgrade.log"

FORMULA_API="https://formulae.brew.sh/api/formula"
CASK_API="https://formulae.brew.sh/api/cask"
GITHUB_API="https://api.github.com"
# Set GITHUB_TOKEN in env to avoid GitHub's 60 req/hr unauthenticated limit
GITHUB_HEADERS=(-H "User-Agent: brew-safe-upgrade")
[[ -n "${GITHUB_TOKEN:-}" ]] && GITHUB_HEADERS+=(-H "Authorization: Bearer $GITHUB_TOKEN")

# ── colours ─────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── helpers ─────────────────────────────────────────────────
log()  { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
         echo -e "$msg"
         $LOG_ENABLED && echo "$msg" | sed 's/\x1b\[[0-9;]*[mK]//g' >> "$LOG_FILE" || true; }

info()  { log "${CYAN}ℹ${RESET}  $*"; }
ok()    { log "${GREEN}✔${RESET}  $*"; }
warn()  { log "${YELLOW}⚠${RESET}  $*"; }
skip()  { log "${YELLOW}⏳${RESET} $*"; }
fail()  { log "${RED}✘${RESET}  $*"; }
header(){ echo -e "\n${BOLD}$*${RESET}"; }

# ── argument parsing ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || { fail "--days must be a positive integer (got: $2)"; exit 1; }
      MIN_AGE_DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true;       shift   ;;
    --casks)   INCLUDE_CASKS=true; shift   ;;
    --log)     LOG_ENABLED=true;   shift   ;;
    -h|--help)
      sed -n '3,12p' "$0" | sed 's/#  *//'
      exit 0 ;;
    *) fail "Unknown option: $1"; exit 1 ;;
  esac
done

NOW=$(date +%s)

# ── dependency check ─────────────────────────────────────────
for dep in brew curl jq; do
  if ! command -v "$dep" &>/dev/null; then
    fail "Required tool not found: $dep"
    exit 1
  fi
done

# ── banner ───────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║        brew-safe-upgrade                     ║"
echo "║   supply-chain-aware Homebrew upgrader       ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${RESET}"
info "Minimum version age : ${BOLD}${MIN_AGE_DAYS} days${RESET}"
$DRY_RUN      && warn "Dry-run mode — nothing will actually be upgraded" || true
$INCLUDE_CASKS && info "Cask upgrades       : enabled"                   || true
$LOG_ENABLED  && info "Logging to          : $LOG_FILE"                  || true

# ── fetch version age from GitHub commit history ─────────────
# The Homebrew JSON API has no version timestamp field; the source
# of truth is the oldest commit (among the last 10) that introduced
# the current version string into the formula/cask Ruby file.
# Both APIs expose ruby_source_path which maps to the GitHub path.
# Returns empty string if age cannot be determined.
_github_commit_age_days() {
  local repo="$1" path="$2" version="$3"
  # Fetch last 10 commits touching this file (newest-first)
  local commits_json
  commits_json=$(curl -sf --max-time 10 "${GITHUB_HEADERS[@]}" \
    "${GITHUB_API}/repos/${repo}/commits?path=${path}&per_page=10" \
    2>/dev/null) || true
  [[ -z "$commits_json" ]] && echo "" && return

  local num_commits
  num_commits=$(echo "$commits_json" | jq 'length' 2>/dev/null) || true
  [[ -z "$num_commits" || "$num_commits" -eq 0 ]] && echo "" && return

  # Walk commits from newest to oldest, find the oldest one whose diff
  # contains the version string — that is the version publication date.
  local found_date="" i sha commit_date patch_has_version
  for (( i=0; i<num_commits; i++ )); do
    sha=$(echo "$commits_json" | jq -r ".[${i}].sha // empty" 2>/dev/null) || true
    [[ -z "$sha" ]] && continue
    commit_date=$(echo "$commits_json" | jq -r ".[${i}].commit.committer.date // empty" 2>/dev/null) || true
    [[ -z "$commit_date" ]] && continue

    # Fetch the diff for this commit and check if the version string appears
    # in the patch for our specific file
    patch_has_version=$(curl -sf --max-time 10 "${GITHUB_HEADERS[@]}" \
      "${GITHUB_API}/repos/${repo}/commits/${sha}" \
      | jq -r --arg path "$path" --arg ver "$version" \
        '.files[] | select(.filename == $path) | .patch // "" | contains($ver)' \
      2>/dev/null) || true

    if [[ "$patch_has_version" == "true" ]]; then
      # This commit contains the version string — keep walking to find older ones
      found_date="$commit_date"
    fi
  done

  # If version was never found in any diff, fall back to the oldest commit in the list
  if [[ -z "$found_date" ]]; then
    found_date=$(echo "$commits_json" | jq -r ".[-1].commit.committer.date // empty" 2>/dev/null) || true
  fi

  [[ -z "$found_date" ]] && echo "" && return

  local epoch
  epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$found_date" +%s 2>/dev/null \
       || date -d "$found_date" +%s 2>/dev/null) || true
  [[ -z "$epoch" ]] && echo "" && return
  echo $(( (NOW - epoch) / 86400 ))
}

get_formula_age_days() {
  local name="$1"
  # Check HTTP status to detect third-party taps (404 = not in homebrew-core)
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
    "${FORMULA_API}/${name}.json") || true
  if [[ "$http_code" == "404" ]]; then
    echo "THIRD_PARTY"
    return
  fi
  local api_json path version
  api_json=$(curl -sf --max-time 8 "${FORMULA_API}/${name}.json" \
    2>/dev/null) || true
  [[ -z "$api_json" ]] && echo "" && return
  path=$(echo "$api_json" | jq -r '.ruby_source_path // empty' 2>/dev/null) || true
  [[ -z "$path" ]] && echo "" && return
  version=$(echo "$api_json" | jq -r '.versions.stable // empty' 2>/dev/null) || true
  _github_commit_age_days "Homebrew/homebrew-core" "$path" "$version"
}

get_cask_age_days() {
  local name="$1"
  # Check HTTP status to detect third-party taps (404 = not in homebrew-cask)
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
    "${CASK_API}/${name}.json") || true
  if [[ "$http_code" == "404" ]]; then
    echo "THIRD_PARTY"
    return
  fi
  local api_json path version
  api_json=$(curl -sf --max-time 8 "${CASK_API}/${name}.json" \
    2>/dev/null) || true
  [[ -z "$api_json" ]] && echo "" && return
  path=$(echo "$api_json" | jq -r '.ruby_source_path // empty' 2>/dev/null) || true
  [[ -z "$path" ]] && echo "" && return
  version=$(echo "$api_json" | jq -r '.version // empty' 2>/dev/null) || true
  _github_commit_age_days "Homebrew/homebrew-cask" "$path" "$version"
}

# ── GitHub rate limit pre-flight check ───────────────────────
check_github_rate_limit() {
  local remaining
  remaining=$(curl -sf --max-time 8 "${GITHUB_HEADERS[@]}" \
    "${GITHUB_API}/rate_limit" \
    | jq -r '.resources.core.remaining // empty' 2>/dev/null) || true
  [[ -z "$remaining" ]] && return  # can't check, proceed
  local needed=$(( ${#OUTDATED_FORMULAE[@]} * 3 ))  # ~3 calls per formula now
  if (( remaining < needed )); then
    warn "GitHub API: only ${remaining} requests remaining (need ~${needed}). Set GITHUB_TOKEN to avoid silent skips."
    warn "Rate limit resets in: $(curl -sf --max-time 8 "${GITHUB_HEADERS[@]}" "${GITHUB_API}/rate_limit" | jq -r '(.resources.core.reset - now) | round | tostring + "s"' 2>/dev/null || echo 'unknown')"
  fi
}

# ── process a list of packages ───────────────────────────────
process_packages() {
  local type="$1"   # "formula" or "cask"
  shift
  local packages=("$@")

  local upgraded=0 skipped=0 unknown=0 failed=0
  local type_flag=""
  [[ "$type" == "cask" ]] && type_flag="--cask"

  for pkg in "${packages[@]}"; do
    local age_days=""
    if [[ "$type" == "formula" ]]; then
      age_days=$(get_formula_age_days "$pkg")
    else
      age_days=$(get_cask_age_days "$pkg")
    fi

    if [[ "$age_days" == "THIRD_PARTY" ]]; then
      warn "$pkg — third-party tap, not in homebrew-core. Skipping. Run 'brew upgrade $pkg' manually after review."
      (( unknown++ )) || true
      continue
    fi

    if [[ -z "$age_days" ]]; then
      warn "$pkg — could not determine version age, skipping (safety first)"
      (( unknown++ )) || true
      continue
    fi

    if (( age_days >= MIN_AGE_DAYS )); then
      ok "$pkg — ${age_days}d old → eligible for upgrade"
      if $DRY_RUN; then
        info "  [dry-run] would run: brew upgrade${type_flag:+ $type_flag} $pkg"
      else
        if brew upgrade ${type_flag:+$type_flag} "$pkg" 2>&1; then
          (( upgraded++ )) || true
        else
          fail "$pkg — upgrade failed"
          (( failed++ )) || true
        fi
      fi
    else
      skip "$pkg — only ${age_days}d old (need ${MIN_AGE_DAYS}d) → skipping"
      (( skipped++ )) || true
    fi
  done

  echo ""
  info "Summary ($type): upgraded=${upgraded}  skipped=${skipped}  age-unknown=${unknown}  failed=${failed}"
}

# ── formulae ─────────────────────────────────────────────────
header "── Formulae ──────────────────────────────────────"
OUTDATED_FORMULAE=()
while IFS= read -r pkg; do OUTDATED_FORMULAE+=("$pkg"); done \
  < <(brew outdated --formula --quiet 2>/dev/null || true)

if [[ ${#OUTDATED_FORMULAE[@]} -eq 0 ]]; then
  info "No outdated formulae."
else
  info "Found ${#OUTDATED_FORMULAE[@]} outdated formula(e): ${OUTDATED_FORMULAE[*]}"
  check_github_rate_limit
  process_packages "formula" "${OUTDATED_FORMULAE[@]}"
fi

# ── casks ────────────────────────────────────────────────────
if $INCLUDE_CASKS; then
  header "── Casks ─────────────────────────────────────────"
  OUTDATED_CASKS=()
  while IFS= read -r pkg; do OUTDATED_CASKS+=("$pkg"); done \
    < <(brew outdated --cask --quiet 2>/dev/null || true)

  if [[ ${#OUTDATED_CASKS[@]} -eq 0 ]]; then
    info "No outdated casks."
  else
    info "Found ${#OUTDATED_CASKS[@]} outdated cask(s): ${OUTDATED_CASKS[*]}"
    process_packages "cask" "${OUTDATED_CASKS[@]}"
  fi
fi

header "── Done ──────────────────────────────────────────"
info "Finished at $(date '+%Y-%m-%d %H:%M:%S')"
