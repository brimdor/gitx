#!/usr/bin/env bash
# install.sh — one-shot installer for the `gitx` CLI (publish | push | pull)
# Supported shells: bash, zsh, fish
# Installs to: ~/.local/bin/gitx
# Adds ~/.local/bin to PATH (current session if sourced; persistently via rc files)

set -euo pipefail

# -----------------------------
# Config & Utilities
# -----------------------------
GITX_TARGET="${HOME}/.local/bin/gitx"
GITX_DIR="$(dirname "$GITX_TARGET")"
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

# -----------------------------
# Ensure ~/.local/bin on PATH
# -----------------------------
ensure_localbin() {
  mkdir -p "$GITX_DIR"

  case "${SHELL##*/}" in
    bash)
      RC_FILES=(~/.bashrc ~/.bash_profile ~/.profile)
      ;;
    zsh)
      RC_FILES=(~/.zshrc ~/.zprofile ~/.zshenv)
      ;;
    fish)
      RC_FILES=(~/.config/fish/config.fish)
      ;;
    *)
      RC_FILES=(~/.profile)
      warn "Unknown shell '${SHELL##*/}'. Falling back to ~/.profile."
      ;;
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

  # If this install script is sourced, we can update the current shell immediately.
  # shellcheck disable=SC2166
  if [[ "${BASH_SOURCE[0]:-}" != "$0" || "${ZSH_EVAL_CONTEXT:-}" == *:file ]]; then
    # We're being sourced; export path now.
    case "${SHELL##*/}" in
      fish) set -gx PATH ~/.local/bin $PATH >/dev/null 2>&1 || true ;;
      *)    export PATH="$HOME/.local/bin:$PATH" ;;
    esac
    ok "PATH exported for current session."
  else
    info "Open a new shell (or run 'source ~/.bashrc' / 'source ~/.zshrc' / 'fish -l') to use 'gitx' immediately."
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
DEFAULT_BRANCH="main"
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
  # Make sure default branch is main
  local cur_branch
  cur_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
  if [[ -z "$cur_branch" ]]; then
    git checkout -b "$DEFAULT_BRANCH" || git switch -c "$DEFAULT_BRANCH"
  elif [[ "$cur_branch" != "$DEFAULT_BRANCH" ]]; then
    git branch -M "$DEFAULT_BRANCH" || git switch -c "$DEFAULT_BRANCH"
  fi
}

# Return 0 if remote exists
remote_exists() {
  git remote get-url "$REMOTE_NAME" >/dev/null 2>&1
}

# --- Git & GitHub config checks ----
get_git_user()   { git config --get user.name   || true; }
get_git_email()  { git config --get user.email  || true; }
get_gh_user() {
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN not set. Create a PAT with 'repo' scope and export GITHUB_TOKEN."
  # Minimal parse of login from API
  local j
  j="$(curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" https://api.github.com/user)"
  # Extract "login": "username"
  printf "%s\n" "$j" | sed -n 's/^[[:space:]]*"login":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

require_identities() {
  local u e gh
  u="$(get_git_user)"
  e="$(get_git_email)"
  [[ -n "$u" ]] || die "Git user.name not set. Run: git config --global user.name \"Your Name\""
  [[ -n "$e" ]] || die "Git user.email not set. Run: git config --global user.email \"you@example.com\""
  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN not set. Export it before running gitx."
  gh="$(get_gh_user)"; [[ -n "$gh" ]] || die "Unable to determine GitHub user from token."
  echo "$gh"
}

# --- GitHub operations ---
# returns 0 if repo exists on GitHub
gh_repo_exists() {
  local gh_user="$1" repo="$2"
  curl -fsS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${gh_user}/${repo}" | grep -qE '^(200)$'
}

# create repo if missing (private=false by default)
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

# safer push without storing the token in remote URL; rely on interactive helper or env if configured
git_push() {
  GIT_ASKPASS= git push -u "$REMOTE_NAME" "$DEFAULT_BRANCH"
}

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

ASSUMPTIONS:
  • Repository name = current folder name.
  • Remote = origin, default branch = main.
  • Git user.name and user.email should be configured globally.

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

  local gh_user
  gh_user="$(require_identities)"
  local repo="${CURRENT_DIR}"

  if gh_repo_exists "$gh_user" "$repo"; then
    info "GitHub repo exists: ${gh_user}/${repo}"
  else
    gh_create_repo "$gh_user" "$repo" "$private"
  fi

  ensure_remote "$gh_user" "$repo"

  # Commit everything if needed
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
    shift
    msg="${1:-$msg}"
    [[ -n "${1:-}" ]] && shift || true
  fi
  ensure_repo
  ensure_safe_dir

  # If remote missing, try to wire it automatically
  local gh_user repo
  if ! remote_exists; then
    gh_user="$(require_identities)"
    repo="${CURRENT_DIR}"
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
  --debug) # allow 'gitx --debug publish'
           DEBUG=1; shift || true; set -x; 
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

Tips:
  • Ensure GITHUB_TOKEN is exported and has 'repo' scope.
  • Set your Git identity once:
      git config --global user.name  "Your Name"
      git config --global user.email "you@example.com"
USAGE
}

main "$@"
