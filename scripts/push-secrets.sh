#!/usr/bin/env bash
# push-secrets.sh — Push GitHub secrets and variables from .secrets.env to one or more repos.
#
# USAGE:
#   ./scripts/push-secrets.sh WebAvenueIG/repo1 WebAvenueIG/repo2
#   GITHUB_REPOS="WebAvenueIG/repo1 WebAvenueIG/repo2" ./scripts/push-secrets.sh
#
# DRY RUN (prints what would be pushed without calling gh):
#   DRY_RUN=1 ./scripts/push-secrets.sh WebAvenueIG/repo1
#
# CONVENTIONS in .secrets.env:
#   - Keys prefixed with VAR_  → pushed as GitHub Variables  (gh variable set)
#   - All other keys           → pushed as GitHub Secrets    (gh secret set)
#   - Keys suffixed with _B64  → value is a FILE PATH; the file is base64-encoded before pushing
#   - Lines starting with #    → comments, ignored
#   - Blank lines              → ignored

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.secrets.env"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[error]${NC} $*" >&2; }

# ── Preflight checks ──────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
  error "GitHub CLI (gh) not found. Install it: https://cli.github.com"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  error "Not authenticated with gh. Run: gh auth login"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  error ".secrets.env not found at $ENV_FILE"
  error "Copy .secrets.env.example → .secrets.env and fill in your values."
  exit 1
fi

# ── Resolve target repos ──────────────────────────────────────────────────────
REPOS=()
if [[ $# -gt 0 ]]; then
  REPOS=("$@")
elif [[ -n "${GITHUB_REPOS:-}" ]]; then
  read -ra REPOS <<< "$GITHUB_REPOS"
else
  error "No repos specified."
  error "Usage: $0 org/repo1 [org/repo2 ...]"
  error "   or: GITHUB_REPOS='org/repo1 org/repo2' $0"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"
[[ "$DRY_RUN" == "1" ]] && warn "DRY RUN mode — no changes will be made."

# ── Parse .secrets.env ────────────────────────────────────────────────────────
declare -A SECRETS
declare -A VARIABLES

while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip comments and blank lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue

  if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    # Strip surrounding quotes if present
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    # _B64 suffix → value is a file path; base64-encode its contents
    if [[ "$key" == *_B64 ]]; then
      file_path="$value"
      # Resolve relative paths from repo root
      [[ "$file_path" != /* ]] && file_path="$REPO_ROOT/$file_path"
      if [[ ! -f "$file_path" ]]; then
        warn "File not found for $key: $file_path — skipping"
        continue
      fi
      value="$(base64 < "$file_path" | tr -d '\n')"
    fi

    # VAR_ prefix → GitHub Variable; otherwise → GitHub Secret
    if [[ "$key" == VAR_* ]]; then
      var_name="${key#VAR_}"
      VARIABLES["$var_name"]="$value"
    else
      SECRETS["$key"]="$value"
    fi
  fi
done < "$ENV_FILE"

info "Parsed ${#SECRETS[@]} secret(s) and ${#VARIABLES[@]} variable(s) from .secrets.env"
echo ""

# ── Push to each repo ─────────────────────────────────────────────────────────
for repo in "${REPOS[@]}"; do
  echo -e "${BLUE}━━━ $repo ━━━${NC}"

  # Secrets
  for key in "${!SECRETS[@]}"; do
    value="${SECRETS[$key]}"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "  [dry-run] secret  $key"
    else
      echo -n "$value" | gh secret set "$key" --repo "$repo" --body -
      success "secret  $key"
    fi
  done

  # Variables
  for key in "${!VARIABLES[@]}"; do
    value="${VARIABLES[$key]}"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "  [dry-run] variable $key = $value"
    else
      gh variable set "$key" --repo "$repo" --body "$value"
      success "variable $key"
    fi
  done

  echo ""
done

success "Done."
