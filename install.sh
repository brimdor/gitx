#!/usr/bin/env bash
# install.sh — one-shot installer for the `gitx` CLI (publish | push | pull)
# Installs to: ~/.local/bin/gitx  (user-local)
# Adds ~/.local/bin to PATH (current session if sourced; persistently via rc files)
# Prompts for and configures: git user.name, user.email, and GITHUB_TOKEN (with validation)
set -euo pipefail

# -----------------------------
# Config & Utilities
# -----------------------------
GITX_TARGET="${HOME}/.local/bin/gitx"
GITX_DIR="$(dirname "$GITX_TARGET")"
GITX_CFG_DIR="${HOME}/.config/gitx"
GITX_ENV_FILE="${GITX_CFG_DIR}/.env"     # bash/zsh export file
GITX_ENV_FISH="${GITX_CFG_DIR}/.env.fish" # fish env file

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
info() { printf "%s\n" "${DIM}==>${NC} $*"; }
ok()   { printf "%s\n" "${GREEN}✔${NC} $*"; }
warn() { printf "%s\n" "${YELLOW}⚠${NC} $*"; }
err()  { printf "%s\n" "${RED}✖${NC} $*" 1>&2; }
die()  { err "$*"; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# --- robust prompts that work with curl | bash (read from /dev/tty) ---
_read_from_tty() {
  # _read_from_tty [-s] "Prompt text" [default]
  local silent=0 prompt def ans
  if [[ "${1:-}" == "-s" ]]; then silent=1; shift; fi
  prompt="${1:-}"; def="${2:-}"

  if [[ -r /dev/tty ]]; then
    if [[ $silent -eq 1 ]]; then
      # shellcheck disable=SC2162
      read -r -s -p "${prompt}${def:+ [${def}]}: " ans </dev/tty || true
      printf "\n" 1>&2
    else
      # shellcheck disable=SC2162
      read -r -p "${prompt}${def:+ [${def}]}: " ans </dev/tty || true
    fi
  else
    # fallback to stdin (e.g., CI). No silent mode here.
    # shellcheck disable=SC2162
    read -r -p "${prompt}${def:+ [${def}]}: " ans || true
  fi
  printf "%s" "${ans:-$def}"
}

yesno() {
  # yesno "Question" "Y|N"
  local q="${1:-}" def="${2:-Y}" d="[Y/n]"
  [[ "$def" =~ ^[Nn]$ ]] && d="[y/N]"
  local a; a="$(_read_from_tty "${q} ${d}")"
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
          grep -q 'set -gx PATH ~/.local/bin $PATH' "$rc" 2>/dev/null || echo 'set -gx PATH ~/.local/bin $PATH' >> "$rc"
          ;;
        *)
          touch "$rc"
          grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$rc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
          ;;
      esac
    done
    ok "PATH updated in rc files."
  else
    ok "~/.local/bin already on PATH."
  fi

  # If the installer is sourced, update current session PATH immediately.
  if [[ "${BASH_SOURCE[0]:-}" != "$0" || "${ZSH_EVAL_CONTEXT:-}" == *:file ]]; then
    case "${SHELL##*/}" in
      fish) set -gx PATH ~/.local/bin $PATH >/dev/null 2>&1 || true ;;
      *)    export PATH="$HOME/.local/bin:$PATH" ;;
    esac
    ok "PATH exported for current session."
  else
    info "Open a new shell (or 'source' your rc) to use 'gitx' immediately."
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
    name="$(_read_from_tty "Enter your Git user.name")"
    [[ -n "$name" ]] || die "user.name cannot be empty."
    git config --global user.name "$name"
    ok "Set git user.name = '$name'"
  else
    ok "git user.name = '$name'"
  fi

  if [[ -z "$email" ]]; then
    info "Git user.email is not set."
    email="$(_read_from_tty "Enter your Git user.email")"
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
  local tok="$1"
  local resp login
  resp="$(curl -fsSL -H "Authorization: Bearer ${tok}" https://api.github.com/user || true)"
  login="$(printf "%s" "$resp" | sed -n 's/^[[:space:]]*"login":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$login" ]] || return 1
  printf "%s" "$login"
}

persist_env_export() {
  # Writes bash/zsh export file; sets fish file with set -gx
  local key="$1" val="$2"
  mkdir -p "$GITX_CFG_DIR"

  # bash/zsh style
  {
    echo "# gitx environment"
    echo "export ${key}=\"${val}\""
  } > "$GITX_ENV_FILE"

  # fish style
  {
    echo "# gitx environment (fish)"
    echo "set -gx ${key} \"${val}\""
  } > "$GITX_ENV_FISH"

  ok "Wrote ${GITX_ENV_FILE} and ${GITX_ENV_FISH}"

  case "${SHELL##*/}" in
    bash) RC_FILES=(~/.bashrc ~/.bash_profile ~/.profile) ;;
    zsh)  RC_FILES=(~/.zshrc ~/.zprofile ~/.zshenv) ;;
    fish) RC_FILES=(~/.config/fish/config.fish) ;;
    *)    RC_FILES=(~/.profile) ;;
  esac

  for rc in "${RC_FILES[@]}"; do
    case "$rc" in
      *fish*)
        mkdir -p "$(dirname "$rc")"
        grep -q 'source ~/.config/gitx/.env.fish' "$rc" 2>/dev/null || echo 'source ~/.config/gitx/.env.fish' >> "$rc"
        ;;
      *)
        touch "$rc"
        grep -q 'source ~/.config/gitx/.env' "$rc" 2>/dev/null || echo 'source ~/.config/gitx/.env' >> "$rc"
        ;;
    esac
  done

  # If sourced, load now
  if [[ "${BASH_SOURCE[0]:-}" != "$0" || "${ZSH_EVAL_CONTEXT:-}" == *:file ]]; then
    case "${SHELL##*/}" in
      fish) # shellcheck disable=SC1090
            source "$GITX_ENV_FISH" ;;
      *)    # shellcheck disable=SC1090
            source "$GITX_ENV_FILE" ;;
    esac
    ok "Exported ${key} for current session."
  else
    info "Restart your shell or 'source' your rc to pick up ${key}."
  fi
}

configure_github_token() {
  local token="${GITHUB_TOKEN:-}"
  local login=""

  # Always prompt until we have a non-empty, valid token
  while [[ -z "${token}" ]]; do
    warn "GITHUB_TOKEN is not set."
    info "Create a GitHub Personal Access Token (classic) with at least 'repo' scope."
    token="$(_read_from_tty -s "Paste GITHUB_TOKEN")"
    if [[ -z "$token" ]]; then
      err "GITHUB_TOKEN cannot be empty. Let's try again."
    fi
  done

  # Validate token; loop until valid
  while true; do
    login="$(validate_github_token "$token" || true)"
    if [[ -n "$login" ]]; then
      ok "Authenticated with GitHub as '${login}'."
      break
    fi
    err "That token didn't authenticate with GitHub."
    token="$(_read_from_tty -s "Try again — paste a valid GITHUB_TOKEN")"
    [[ -n "$token" ]] || { err "GITHUB_TOKEN cannot be empty."; continue; }
  done

  if yesno "Persist GITHUB_TOKEN to ${GITX_CFG_DIR} and source it automatically?" "Y"; then
    persist_env_export "GITHUB_TOKEN" "$token"
  else
    info "Using GITHUB_TOKEN only for this install session."
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
set -euo pipefail

# Styling
BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
info() { printf "%s\n" "${DIM}==>${NC} $*"; }
ok()   { printf "%s\n" "${GREEN}✔${NC} $*"; }
warn() { printf "%s\n" "${YELLOW}⚠${NC} $*"; }
err()  { printf "%s\n" "${RED}✖${NC} $*" 1>&2; }
die()  { err "$*"; exit 1; }

# Debug
DEBUG="${GITX_DEBUG:-0}"
if [[ "${1:-}" == "--debug" ]]; then DEBUG=1; shift; fi
[[ "$DEBUG" == "1" ]] && { PS4="+ [gitx:\${LINENO}] "; set -x; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
need git; need curl

DEFAULT_BRANCH="${GITX_DEFAULT_BRANCH:-main}"
REMOTE_NAME="origin"

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
  local cur_branch
  cur_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
  if [[ -z "$cur_branch" ]]; then
    git checkout -b "$DEFAULT_BRANCH" || git switch -c "$DEFAULT_BRANCH"
  elif [[ "$cur_branch" != "$DEFAULT_BRANCH" ]]; then
    git branch -M "$DEFAULT_BRANCH" || git switch -c "$DEFAULT_BRANCH"
  fi
}

remote_exists() { git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; }

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
    local cur; cur="$(git remote get-url "$REMOTE_NAME")"
    if [[ "$cur" != "$url" ]]; then
      info "Updating remote '$REMOTE_NAME' to $url"
      git remote set-url "$REMOTE_NAME" "$url"
    fi
  else
    info "Adding remote '$REMOTE_NAME' -> $url"
    git remote add "$REMOTE_NAME" "$url"
  fi
}

git_push() { GIT_ASKPASS= git push -u "$REMOTE_NAME" "$DEFAULT_BRANCH"; }
git_pull_ff() {
  git fetch "$REMOTE_NAME" "$DEFAULT_BRANCH"
  git pull --ff-only "$REMOTE_NAME" "$DEFAULT_BRANCH" || {
    warn "Fast-forward failed. Attempting rebase..."
    git pull --rebase "$REMOTE_NAME" "$DEFAULT_BRANCH"
  }
}

cmd_help() {
  cat <<'HLP'
gitx — GitHub helper for publish, push, and pull

USAGE:
  gitx publish [--debug] [--private]
  gitx push    [--debug] [--msg "commit message"]
  gitx pull    [--debug]
  gitx --help

ENVIRONMENT:
  GITHUB_TOKEN           PAT with 'repo' scope
  GITX_DEFAULT_BRANCH    Default branch (default: main)
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

  if ! gh_repo_exists "$gh_user" "$repo"; then
    gh_create_repo "$gh_user" "$repo" "$private"
  else
    info "GitHub repo exists: ${gh_user}/${repo}"
  fi

  ensure_remote "$gh_user" "$repo"
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "chore: initial commit via gitx"
  else
    info "Nothing to commit."
  fi
  git_push
  printf "%s\n" "✔ Published to https://github.com/${gh_user}/${repo}"
}

cmd_push() {
  local msg="chore: update via gitx"
  if [[ "${1:-}" == "--msg" ]]; then shift; msg="${1:-$msg}"; [[ -n "${1:-}" ]] && shift || true; fi
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
  remote_exists || die "No remote 'origin' configured. Run 'gitx publish' first."
  git_pull_ff
  ok "Local branch is up-to-date with $REMOTE_NAME/$DEFAULT_BRANCH."
}

sub="${1:-"--help"}"; shift || true
case "$sub" in
  publish) cmd_publish "$@";;
  push)    cmd_push "$@";;
  pull)    cmd_pull "$@";;
  --help|-h|help) cmd_help;;
  --debug) set -x; case "${1:-}" in
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
  gitx publish
  gitx push --msg "..."
  gitx pull
USAGE
}

main "$@"
