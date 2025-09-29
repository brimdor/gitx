#!/usr/bin/env bash
# install.sh — one-shot installer for the `gitx` CLI (publish | push | pull)
# Supported shells: bash, zsh, fish
# Installs to: ~/.local/bin/gitx
# Adds ~/.local/bin to PATH (current session if sourced; persistently via rc files)
# Now also prompts for and configures: git user.name, user.email, and GITHUB_TOKEN.

set -euo pipefail

# -----------------------------
# Config & Utilities
# -----------------------------
GITX_TARGET="${HOME}/.local/bin/gitx"
GITX_DIR="$(dirname "$GITX_TARGET")"
GITX_CFG_DIR="${HOME}/.config/gitx"
GITX_ENV_FILE="${GITX_CFG_DIR}/.env"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
log()  { printf "%s\n" "$*"; }
info() { printf "%s\n" "${DIM}==>${NC} $*"; }
ok()   { printf "%s\n" "${GREEN}✔${NC} $*"; }
warn() { printf "%s\n" "${YELLOW}⚠${NC} $*"; }
err()  { printf "%s\n" "${RED}✖${NC} $*" 1>&2; }
die()  { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

prompt() {
  # prompt "Label" "default"
  local label="${1:-}" def="${2:-}"
  if [[ -n "$def" ]]; then
    read -r -p "${label} [${def}]: " ans || true
    printf "%s" "${ans:-$def}"
  else
    read -r -p "${label}: " ans || true
    printf "%s" "${ans}"
  fi
}

prompt_secret() {
  # silent prompt for secrets
  local label="${1:-}"
  read -r -s -p "${label}: " ans || true
  printf "\n" 1>&2
  printf "%s" "${ans}"
}

yesno() {
  # yesno "Question" "Y"  -> default Yes; returns 0 for yes, 1 for no
  local q="${1:-}" def="${2:-Y}" d="[Y/n]"
  [[ "$def" =~ ^[Nn]$ ]] && d="[y/N]"
  local a; read -r -p "${q} ${d} " a || true
  a="${a:-$def}"
  [[ "$a" =~ ^[Yy]$ ]]
}

# -----------------------------
# Ensure ~/.local/bin on PATH
# -----------------------------
ensure_localbin() {
  mkdir -p "$GITX_DIR"

  case "${SHELL##*/}" in
    bash) RC_FILES=(~/.bashrc ~/.bash_profile ~/.profile) ;;
    zsh)  RC_FILES=(~/.zshrc ~/.zprofile ~/.zshenv) ;;
    fish) RC_FILES=(~/.config/fish/config.fish) ;;
    *)    RC_FILES=(~/.profile); warn "Unknown shell '${SHELL##*/}'. Falling back to ~/.profile." ;;
  esac

  if ! printf %s "$PATH" | tr ':' '\n' | grep -qx "$GITX_DIR"; then
    info "Adding ${GITX_DIR} to PATH in your shell rc."
    for rc in "${RC_FILES[@]}"; do
      case "$rc" in
        *fish*)
          mkdir -p "$(dirname "$rc")"
          if ! grep -q 'set -gx PATH ~/.local/bin $PATH' "$rc" 2>/dev/null; then
            echo 'set -gx PATH ~/.local/bin $PATH' >> "$rc"
          fi
          ;;
        *)
          touch "$rc"
          if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$rc" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
          fi
          ;;
      esac
    done
    ok "PATH updated in rc files."
  else
    ok "~/.local/bin already on PATH."
  fi

  # If this install script is sourced, update current shell now.
  if [[ "${BASH_SOURCE[0]:-}" != "$0" || "${ZSH_EVAL_CONTEXT:-}" == *:file ]]; then
    case "${SHELL##*/}" in
      fish) set -gx PATH ~/.local/bin $PATH >/dev/null 2>&1 || true ;;
      *)    export PATH="$HOME/.local/bin:$PATH" ;;
    esac
    ok "PATH exported for current session."
  else
    info "Open a new shell (or run 'source ~/.bashrc' / 'source ~/.zshrc' / start a new fish shell) to use 'gitx'."
  fi
}

# -----------------------------
# Configure Git identity
# -----------------------------
configure_git_identity() {
  local name email
  name="$(git config --global user.name || true)"
  email="$(git config --global user.email || true)"

  if [[ -z "$name" ]]; then
    info "Git user.name is not set."
    name="$(prompt "Enter your Git user.name" "")"
    [[ -n "$name" ]] || die "user.name cannot be empty."
    git config --global user.name "$name"
    ok "Set git user.name = '$name'"
  else
    ok "git user.name = '$name'"
  fi

  if [[ -z "$email" ]]; then
    info "Git user.email is not set."
    email="$(prompt "Enter your Git user.email" "")"
    [[ -n "$email" ]] || die "user.email cannot be empty."
    git config --global user.email "$email"
    ok "Set git user.email = '$email'"
  else
    ok "git user.email = '$email'"
  fi
}

# -----------------------------
# Configure GITHUB_TOKEN
# -----------------------------
validate_github_token() {
  # returns 0 if token works and prints login to stdout
  local tok="$1"
  local resp login
  resp="$(curl -fsSL -H "Authorization: Bearer ${tok}" https://api.github.com/user || true)"
  login="$(printf "%s" "$resp" | sed -n 's/^[[:space:]]*"login":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$login" ]] || return 1
  printf "%s" "$login"
}

persist_env_export() {
  # persist 'export NAME=VALUE' to rc files + .env
  local key="$1" val="$2"
  mkdir -p "$GITX_CFG_DIR"
  # write env file
  {
    echo "# gitx environment"
    echo "export ${key}=\"${val}\""
  } > "$GITX_ENV_FILE"
  ok "Wrote ${GITX_ENV_FILE}"

  # add 'source ~/.config/gitx/.env' to rc files if not present
  case "${SHELL##*/}" in
    bash) RC_FILES=(~/.bashrc ~/.bash_profile ~/.profile) ;;
    zsh)  RC_FILES=(~/.zshrc ~/.zprofile ~/.zshenv) ;;
    fish) RC_FILES=(~/.config/fish/config.fish) ;;
    *)    RC_FILES=(~/.profile);;
  esac

  for rc in "${RC_FILES[@]}"; do
    case "$rc" in
      *fish*)
        mkdir -p "$(dirname "$rc")"
        if ! grep -q 'source ~/.config/gitx/.env' "$rc" 2>/dev/null; then
          echo 'source ~/.config/gitx/.env' >> "$rc"
          ok "Linked ${GITX_ENV_FILE} in $(basename "$rc")"
        fi
        ;;
      *)
        touch "$rc"
        if ! grep -q 'source ~/.config/gitx/.env' "$rc" 2>/dev/null; then
          echo 'source ~/.config/gitx/.env' >> "$rc"
          ok "Linked ${GITX_ENV_FILE} in $(basename "$rc")"
        fi
        ;;
    esac
  done

  # If sourced, export now
  if [[ "${BASH_SOURCE[0]:-}" != "$0" || "${ZSH_EVAL_CONTEXT:-}" == *:file ]]; then
    # shellcheck disable=SC1090
    source "$GITX_ENV_FILE"
    ok "Exported ${key} for current session."
  else
    info "Restart your shell or 'source' your rc to pick up ${key}."
  fi
}

configure_github_token() {
  local token="${GITHUB_TOKEN:-}"
  local login=""

  if [[ -z "$token" ]]; then
    warn "GITHUB_TOKEN is not set."
    info "Please create a GitHub Personal Access Token (classic) with at least 'repo' scope."
    token="$(prompt_secret "Paste GITHUB_TOKEN")"
    [[ -n "$token" ]] || die "GITHUB_TOKEN cannot be empty."
  fi

  # Validate token
  login="$(validate_github_token "$token" || true)"
  if [[ -z "$login" ]]; then
    err "The provided token did not authenticate with GitHub."
    token="$(prompt_secret "Try again — paste a valid GITHUB_TOKEN")"
    [[ -n "$token" ]] || die "GITHUB_TOKEN cannot be empty."
    login="$(validate_github_token "$token")" || die "Token still invalid. Aborting."
  fi
  ok "Authenticated with GitHub as '${login}'."

  # Offer to persist
  if yesno "Persist GITHUB_TOKEN to ${GITX_ENV_FILE} and source it automatically?" "Y"; then
    persist_env_export "GITHUB_TOKEN" "$token"
  else
    info "Will use GITHUB_TOKEN from current environment only."
    export GITHUB_TOKEN="$token"
  fi
}

# -----------------------------
# Install the gitx CLI
# -----------------------------
write_gitx() {
  cat >"$GITX_TARGET" <<"EOF"
#!/usr/bin/env bash
# gitx — GitHub helper for publish, push, and pull
# Usage:
#   gitx publish [--debug]    Create (or point to) a GitHub repo and push initial commit
#   gitx push    [--debug]    Add, commit, and push changes to origin/main (auto-create origin if missing)
#   gitx pull    [--debug]    Pull updates from origin/main (auto-create origin if missing)
#   gitx --help               Show help
#
# Requirements:
#   - git, curl
#   - GITHUB_TOKEN env var with 'repo' scope
#
# Notes:
#   - Repo name defaults to the current folder name.
#   - Remote: https://github.com/<github_user>/<repo>.git
#   - --debug enables verbose tracing.

set -euo pipefail

# ---------- Styling ----------
BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
say()  { printf "%s\n" "$*"; }
info() { printf "%s\n" "${DIM}==>${NC} $*"; }
ok()   { printf "%s\n" "${GREEN}✔${NC} $*"; }
warn() { printf "%s\n" "${YELLOW}⚠${NC} $*"; }
err()  { printf "%s\n" "${RED}✖${NC} $*" 1>&2; }
die()  { err "$*"; exit 1; }

# ---------- Debug ----------
DEBUG="${GITX_DEBUG:-0}"
if [[ "${1:-}" == "--debug" ]]; then DEBUG=1; shift; fi
[[ "$DEBUG" == "1" ]] && { PS4="+ [gitx:\${LINENO}] "; set -x; }

# ---------- Helpers ----------
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
need git; need curl

CURRENT_DIR="${PWD##*/}"
DEFAULT_BRANCH="${GITX_DEFAULT_BRANCH:-main}"
REMOTE_NAME="origin"

# Detect git safe.directory issues (e.g., in containers)
ensure_safe_dir() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$root" ]] || return 0
  if ! git config --global --get-all safe.directory | grep -qx "$root"; then
    git config --global --add safe.directory "$root" || true
  fi
}

ensure_repo() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    info "Initializing new git repository…"
    git init
  fi
  # Ensure default branch
  local cur_branch
  cur_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
  if [[ -z "$cur_branch" ]]; then
    git checkout -b "$DEFAULT_BRANCH" || git switch -c "$DEFAULT_BRANCH"
  elif [[ "$cur_branch" != "$DEFAULT_BRANCH" ]]; then
    git branch -M "$DEFAULT_BRANCH" || git switch -c "$DEFAULT_BRANCH"
  fi
}

# Return 0 if remote exists
remote_exists() { git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; }

# --- Git & GitHub config checks ----
get_git_user()   { git config --get user.name   || true; }
get_git_email()  { git config --get user.email  || true; }
get_gh_user() {
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN not set. Export a PAT with 'repo' scope."
  local j
  j="$(curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" https://api.github.com/user)"
  printf "%s\n" "$j" | sed -n 's/^[[:space:]]*"login":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

require_identities() {
  local u e gh
  u="$(get_git_user)"
  e="$(get_git_email)"
  [[ -n "$u" ]] || die "Git user.name not set (global)."
  [[ -n "$e" ]] || die "Git user.email not set (global)."
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN not set."
  gh="$(get_gh_user)"; [[ -n "$gh" ]] || die "Unable to determine GitHub user from token."
  echo "$gh"
}

# --- GitHub operations ---
gh_repo_exists() {
  local gh_user="$1" repo="$2"
  curl -fsS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${gh_user}/${repo}" | grep -qE '^(200)$'
}

gh_create_repo() {
  local gh_user="$1" repo="$2" private="${3:-false}"
  local status
  status="$(curl -fsS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${repo}\",\"private\":${private}}" \
    https://api.github.com/user/repos || true)"
  case "$status" in
    201) ok "GitHub repo created: ${gh_user}/${repo}";;
    422) info "Repo already exists on GitHub: ${gh_user}/${repo}";;
    *)   die "Failed to create repo (HTTP $status)." ;;
  esac
}

ensure_remote() {
  local gh_user="$1" repo="$2"
  local url="https://github.com/${gh_user}/${repo}.git"
  if remote_exists; then
    local cur
    cur="$(git remote get-url "$REMOTE_NAME")"
    if [[ "$cur" != "$url" ]]; then
      info "Updating remote '$REMOTE_NAME' to $url"
      git remote set-url "$REMOTE_NAME" "$url"
    fi
  else
    info "Adding remote '$REMOTE_NAME' -> $url"
    git remote add "$REMOTE_NAME" "$url"
  fi
}

# Push/pull helpers
git_push() { GIT_ASKPASS= git push -u "$REMOTE_NAME" "$DEFAULT_BRANCH"; }
git_pull_ff() {
  git fetch "$REMOTE_NAME" "$DEFAULT_BRANCH"
  git pull --ff-only "$REMOTE_NAME" "$DEFAULT_BRANCH" || {
    warn "Fast-forward failed. Attempting rebase..."
    git pull --rebase "$REMOTE_NAME" "$DEFAULT_BRANCH"
  }
}

# ---------- Subcommands ----------
cmd_help() {
  cat <<'HLP'
gitx — GitHub helper for publish, push, and pull

USAGE:
  gitx publish [--debug] [--private]
      Initialize a repo (if needed), ensure GitHub repo exists (create if missing),
      set remote, commit any changes, and push to origin/main.
      --private     Create the GitHub repository as private (default: public)

  gitx push [--debug] [--msg "commit message"]
      Stage all changes, create a commit (or amend if none), and push to origin/main.
      --msg         Use the provided message instead of the auto message.

  gitx pull [--debug]
      Fetch and synchronize with origin/main using fast-forward (or rebase fallback).

  gitx --help
      Show this help.

ENVIRONMENT:
  GITHUB_TOKEN   Personal Access Token with 'repo' scope for GitHub API & pushes.
  GITX_DEFAULT_BRANCH  Override default branch name (default: main)

ASSUMPTIONS:
  • Repository name = current folder name.
  • Remote = origin.

EXAMPLES:
  gitx publish --private
  gitx push --msg "feat: add API client"
  gitx pull

DEBUGGING:
  Prepend --debug or set GITX_DEBUG=1 for verbose tracing.
HLP
}

cmd_publish() {
  local private=false
  if [[ "${1:-}" == "--private" ]]; then private=true; shift; fi

  ensure_repo
  ensure_safe_dir

  local gh_user repo
  gh_user="$(require_identities)"
  repo="${PWD##*/}"

  if gh_repo_exists "$gh_user" "$repo"; then
    info "GitHub repo exists: ${gh_user}/${repo}"
  else
    gh_create_repo "$gh_user" "$repo" "$private"
  fi

  ensure_remote "$gh_user" "$repo"

  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "chore: initial commit via gitx"
  else
    info "Nothing to commit."
  fi

  git_push
  ok "Published to https://github.com/${gh_user}/${repo}"
}

cmd_push() {
  local msg="chore: update via gitx"
  if [[ "${1:-}" == "--msg" ]]; then
    shift; msg="${1:-$msg}"; [[ -n "${1:-}" ]] && shift || true
  fi
  ensure_repo
  ensure_safe_dir

  local gh_user repo
  if ! remote_exists; then
    gh_user="$(require_identities)"
    repo="${PWD##*/}"
    if ! gh_repo_exists "$gh_user" "$repo"; then
      gh_create_repo "$gh_user" "$repo" "false"
    fi
    ensure_remote "$gh_user" "$repo"
  fi

  git add -A
  if git status --porcelain | grep -q .; then
    git commit -m "$msg" || true
  else
    info "Nothing changed; pushing current branch state."
  fi
  git_push
  ok "Pushed to $REMOTE_NAME/$DEFAULT_BRANCH"
}

cmd_pull() {
  ensure_repo
  ensure_safe_dir
  if ! remote_exists; then
    die "No remote 'origin' configured. Run 'gitx publish' first."
  fi
  git_pull_ff
  ok "Local branch is up-to-date with $REMOTE_NAME/$DEFAULT_BRANCH."
}

# ---------- Dispatch ----------
sub="${1:-"--help"}"; shift || true
case "$sub" in
  publish) cmd_publish "$@";;
  push)    cmd_push "$@";;
  pull)    cmd_pull "$@";;
  --help|-h|help) cmd_help;;
  --debug) DEBUG=1; shift || true; set -x;
           case "${1:-}" in
             publish) shift; cmd_publish "$@";;
             push)    shift; cmd_push "$@";;
             pull)    shift; cmd_pull "$@";;
             *)       cmd_help;;
           esac;;
  *) err "Unknown command: $sub"; cmd_help; exit 1;;
esac
EOF
  chmod +x "$GITX_TARGET"
  ok "Installed gitx -> $GITX_TARGET"
}

# -----------------------------
# Main
# -----------------------------
main() {
  require_cmd git
  require_cmd curl
  ensure_localbin
  configure_git_identity
  configure_github_token
  write_gitx

  printf "\n%s\n" "${BOLD}gitx — GitHub helper for publish, push, and pull${NC}"
  cat <<'USAGE'

USAGE:
  gitx publish [--debug] [--private]
  gitx push    [--debug] [--msg "commit message"]
  gitx pull    [--debug]
  gitx --help

Quick start:
  cd your/project
  gitx publish          # create GitHub repo (if missing) and push initial commit
  gitx push --msg "..." # commit & push further changes
  gitx pull             # sync with remote
USAGE
}

main "$@"
