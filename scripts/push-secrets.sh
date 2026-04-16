#!/usr/bin/env bash
# push-secrets.sh — Push GitHub secrets and variables to one or more repos.
#
# USAGE:
#   # Shared secrets only (root .secrets.env):
#   ./scripts/push-secrets.sh WebAvenueIG/repo1
#
#   # Shared + project-specific (project values override root):
#   ./scripts/push-secrets.sh --project my-app WebAvenueIG/repo1
#
#   # Multiple repos:
#   ./scripts/push-secrets.sh --project my-app WebAvenueIG/repo1 WebAvenueIG/repo2
#
#   # Via env var:
#   GITHUB_REPOS="WebAvenueIG/repo1" ./scripts/push-secrets.sh --project my-app
#
#   # DRY RUN (prints what would be pushed without calling gh):
#   DRY_RUN=1 ./scripts/push-secrets.sh --project my-app WebAvenueIG/repo1
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

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[error]${NC} $*" >&2; }

# ── Parse arguments ───────────────────────────────────────────────────────────
PROJECT=""
REPOS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      if [[ -z "${2:-}" ]]; then
        error "--project requires a project name argument"
        exit 1
      fi
      PROJECT="$2"
      shift 2
      ;;
    *)
      REPOS+=("$1")
      shift
      ;;
  esac
done

# ── Preflight checks ──────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
  error "GitHub CLI (gh) not found. Install it: https://cli.github.com"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  error "Not authenticated with gh. Run: gh auth login"
  exit 1
fi

ROOT_ENV="$REPO_ROOT/.secrets.env"
PROJECT_ENV=""
[[ -n "$PROJECT" ]] && PROJECT_ENV="$REPO_ROOT/$PROJECT/.secrets.env"

if [[ ! -f "$ROOT_ENV" ]] && { [[ -z "$PROJECT_ENV" ]] || [[ ! -f "$PROJECT_ENV" ]]; }; then
  error "No .secrets.env found."
  error "Expected: $ROOT_ENV"
  [[ -n "$PROJECT_ENV" ]] && error "    and/or: $PROJECT_ENV"
  error "Copy .secrets.env.example → .secrets.env and fill in your values."
  exit 1
fi

if [[ -n "$PROJECT_ENV" ]] && [[ ! -f "$PROJECT_ENV" ]]; then
  error "Project secrets file not found: $PROJECT_ENV"
  exit 1
fi

# ── Resolve target repos ──────────────────────────────────────────────────────
if [[ ${#REPOS[@]} -eq 0 ]]; then
  if [[ -n "${GITHUB_REPOS:-}" ]]; then
    read -ra REPOS <<< "$GITHUB_REPOS"
  else
    error "No repos specified."
    error "Usage: $0 [--project <name>] org/repo1 [org/repo2 ...]"
    error "   or: GITHUB_REPOS='org/repo1' $0 [--project <name>]"
    exit 1
  fi
fi

DRY_RUN="${DRY_RUN:-0}"
[[ "$DRY_RUN" == "1" ]] && warn "DRY RUN mode — no changes will be made."

# ── Parse an env file into SECRETS / VARIABLES (later calls override earlier) ─
declare -A SECRETS
declare -A VARIABLES

parse_env_file() {
  local file="$1"
  [[ ! -f "$file" ]] && return

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue

    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"

      # Strip surrounding quotes if present
      if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi

      # _B64 suffix → value is a file path; base64-encode its contents
      if [[ "$key" == *_B64 ]]; then
        local file_path="$value"
        [[ "$file_path" != /* ]] && file_path="$REPO_ROOT/$file_path"
        if [[ ! -f "$file_path" ]]; then
          warn "File not found for $key: $file_path — skipping"
          continue
        fi
        value="$(base64 < "$file_path" | tr -d '\n')"
      fi

      # VAR_ prefix → GitHub Variable; otherwise → GitHub Secret
      if [[ "$key" == VAR_* ]]; then
        VARIABLES["${key#VAR_}"]="$value"
      else
        SECRETS["$key"]="$value"
      fi
    fi
  done < "$file"
}

# Load root first, then project (project overrides root)
parse_env_file "$ROOT_ENV"
[[ -n "$PROJECT_ENV" ]] && parse_env_file "$PROJECT_ENV"

if [[ -n "$PROJECT" ]]; then
  info "Loaded root + project '$PROJECT' secrets — ${#SECRETS[@]} secret(s), ${#VARIABLES[@]} variable(s)"
else
  info "Loaded root secrets — ${#SECRETS[@]} secret(s), ${#VARIABLES[@]} variable(s)"
fi
echo ""

# ── Push to each repo ─────────────────────────────────────────────────────────
for repo in "${REPOS[@]}"; do
  echo -e "${BLUE}━━━ $repo ━━━${NC}"

  for key in "${!SECRETS[@]}"; do
    value="${SECRETS[$key]}"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "  [dry-run] secret   $key"
    else
      echo -n "$value" | gh secret set "$key" --repo "$repo" --body -
      success "secret   $key"
    fi
  done

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
