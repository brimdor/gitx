#!/usr/bin/env bash
# install.sh — user-local installer for `gitx` (publish | push | pull)
# Non-interactive after install: sets up AskPass using validated PAT.
set -euo pipefail

# ---------- Paths ----------
GITX_TARGET="${HOME}/.local/bin/gitx"
GITX_DIR="$(dirname "$GITX_TARGET")"
GITX_CFG_DIR="${HOME}/.config/gitx"
GITX_ENV_FILE="${GITX_CFG_DIR}/.env"        # bash/zsh
GITX_ENV_FISH="${GITX_CFG_DIR}/.env.fish"   # fish
GITX_ASKPASS="${GITX_CFG_DIR}/askpass.sh"

# ---------- UI ----------
DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
info(){ printf "%s\n" "${DIM}==>${NC} $*"; }
ok(){   printf "%s\n" "${GREEN}✔${NC} $*"; }
warn(){ printf "%s\n" "${YELLOW}⚠${NC} $*"; }
err(){  printf "%s\n" "${RED}✖${NC} $*" 1>&2; }
die(){  err "$*"; exit 1; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# ---------- robust prompts (work with curl | bash) ----------
_read_from_tty(){
  local silent=0 prompt def ans
  if [[ "${1:-}" == "-s" ]]; then silent=1; shift; fi
  prompt="${1:-}"; def="${2:-}"
  if [[ -r /dev/tty ]]; then
    if [[ $silent -eq 1 ]]; then read -r -s -p "${prompt}${def:+ [${def}]}: " ans </dev/tty || true; printf "\n" 1>&2
    else read -r -p "${prompt}${def:+ [${def}]}: " ans </dev/tty || true; fi
  else
    read -r -p "${prompt}${def:+ [${def}]}: " ans || true
  fi
  printf "%s" "${ans:-$def}"
}

yesno(){
  local q="${1:-}" def="${2:-Y}" d="[Y/n]"; [[ "$def" =~ ^[Nn]$ ]] && d="[y/N]"
  local a; a="$(_read_from_tty "${q} ${d}")"; a="${a:-$def}"; [[ "$a" =~ ^[Yy]$ ]]
}

# ---------- PATH wiring ----------
ensure_localbin(){
  mkdir -p "$GITX_DIR"
  case "${SHELL##*/}" in
    bash) RC_FILES=(~/.bashrc ~/.bash_profile ~/.profile) ;;
    zsh)  RC_FILES=(~/.zshrc ~/.zprofile ~/.zshenv) ;;
    fish) RC_FILES=(~/.config/fish/config.fish) ;;
    *)    RC_FILES=(~/.profile); warn "Unknown shell '${SHELL##*/}', using ~/.profile." ;;
  esac
  if ! printf %s "$PATH" | tr ':' '\n' | grep -qx "$GITX_DIR"; then
    info "Adding ${GITX_DIR} to PATH in your shell rc."
    for rc in "${RC_FILES[@]}"; do
      case "$rc" in
        *fish*) mkdir -p "$(dirname "$rc")"; grep -q 'set -gx PATH ~/.local/bin $PATH' "$rc" 2>/dev/null || echo 'set -gx PATH ~/.local/bin $PATH' >> "$rc" ;;
        *)      touch "$rc"; grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$rc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc" ;;
      esac
    done
    ok "PATH updated in rc files."
  else
    ok "~/.local/bin already on PATH."
  fi
}

# ---------- Git identity ----------
configure_git_identity(){
  local name email
  name="$(git config --global user.name || true)"
  email="$(git config --global user.email || true)"
  if [[ -z "$name" ]]; then name="$(_read_from_tty "Enter your Git user.name")"; [[ -n "$name" ]] || die "user.name cannot be empty."; git config --global user.name "$name"; ok "git user.name = '$name'"; else ok "git user.name = '$name'"; fi
  if [[ -z "$email" ]]; then email="$(_read_from_tty "Enter your Git user.email")"; [[ -n "$email" ]] || die "user.email cannot be empty."; git config --global user.email "$email"; ok "git user.email = '$email'"; else ok "git user.email = '$email'"; fi
}

# ---------- Token handling ----------
validate_github_token(){
  local tok="$1" resp login
  resp="$(curl -fsSL -H "Authorization: Bearer ${tok}" https://api.github.com/user || true)"
  login="$(printf "%s" "$resp" | sed -n 's/^[[:space:]]*"login":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$login" ]] || return 1
  printf "%s" "$login"
}

persist_env(){
  local user="$1" token="$2"
  mkdir -p "$GITX_CFG_DIR"
  # bash/zsh
  { echo "# gitx environment"; echo "export GITX_GH_USER=\"$user\""; echo "export GITHUB_TOKEN=\"$token\""; } > "$GITX_ENV_FILE"
  # fish
  { echo "# gitx environment (fish)"; echo "set -gx GITX_GH_USER \"$user\""; echo "set -gx GITHUB_TOKEN \"$token\""; } > "$GITX_ENV_FISH"
  ok "Wrote ${GITX_ENV_FILE} and ${GITX_ENV_FISH}"
  case "${SHELL##*/}" in
    bash) RC_FILES=(~/.bashrc ~/.bash_profile ~/.profile) ;;
    zsh)  RC_FILES=(~/.zshrc ~/.zprofile ~/.zshenv) ;;
    fish) RC_FILES=(~/.config/fish/config.fish) ;;
    *)    RC_FILES=(~/.profile) ;;
  esac
  for rc in "${RC_FILES[@]}"; do
    case "$rc" in
      *fish*) mkdir -p "$(dirname "$rc")"; grep -q 'source ~/.config/gitx/.env.fish' "$rc" 2>/dev/null || echo 'source ~/.config/gitx/.env.fish' >> "$rc" ;;
      *)      touch "$rc"; grep -q 'source ~/.config/gitx/.env' "$rc" 2>/dev/null       || echo 'source ~/.config/gitx/.env'       >> "$rc" ;;
    esac
  done
}

write_askpass(){
  mkdir -p "$GITX_CFG_DIR"
  cat >"$GITX_ASKPASS" <<'APS'
#!/usr/bin/env bash
# askpass for gitx: prints username or token when git asks.
case "$1" in
  *Username*) printf "%s" "${GITX_GH_USER:-}";;
  *Password*) printf "%s" "${GITHUB_TOKEN:-}";;
  *) printf "";;
esac
APS
  chmod +x "$GITX_ASKPASS"
  ok "Wrote AskPass helper -> $GITX_ASKPASS"
}

configure_github_auth(){
  local token login
  token="${GITHUB_TOKEN:-}"
  while [[ -z "$token" ]]; do
    warn "GITHUB_TOKEN is not set."
    info "Create a GitHub Personal Access Token (classic) with at least 'repo' scope."
    token="$(_read_from_tty -s "Paste GITHUB_TOKEN")"
    [[ -n "$token" ]] || { err "GITHUB_TOKEN cannot be empty."; token=""; }
  done
  while true; do
    login="$(validate_github_token "$token" || true)"
    [[ -n "$login" ]] && break
    err "Authentication failed. That token didn't work."
    token="$(_read_from_tty -s "Try again — paste a valid GITHUB_TOKEN")"
    [[ -n "$token" ]] || err "GITHUB_TOKEN cannot be empty."
  done
  ok "Authenticated with GitHub as '${login}'."
  persist_env "$login" "$token"
  write_askpass
}

# ---------- Install CLI ----------
write_gitx(){
  cat >"$GITX_TARGET" <<"EOF"
#!/usr/bin/env bash
# gitx — GitHub helper for publish, push, and pull (non-interactive)
set -euo pipefail

# UI
DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
info(){ printf "%s\n" "${DIM}==>${NC} $*"; }
ok(){   printf "%s\n" "${GREEN}✔${NC} $*"; }
warn(){ printf "%s\n" "${YELLOW}⚠${NC} $*"; }
err(){  printf "%s\n" "${RED}✖${NC} $*" 1>&2; }
die(){  err "$*"; exit 1; }

# Debug
DEBUG="${GITX_DEBUG:-0}"
if [[ "${1:-}" == "--debug" ]]; then DEBUG=1; shift; fi
[[ "$DEBUG" == "1" ]] && { PS4="+ [gitx:\${LINENO}] "; set -x; }

need(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
need git; need curl

# Always wire non-interactive auth
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS="${HOME}/.config/gitx/askpass.sh"

DEFAULT_BRANCH="${GITX_DEFAULT_BRANCH:-main}"
REMOTE_NAME="origin"
CURRENT_DIR="${PWD##*/}"

ensure_safe_dir(){
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$root" ]] || return 0
  git config --global --get-all safe.directory | grep -qx "$root" || git config --global --add safe.directory "$root" || true
}

ensure_repo(){
  if ! git rev-parse --git-dir >/dev/null 2>&1; then info "Initializing new git repository…"; git init; fi
  local cur; cur="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
  if [[ -z "$cur" ]]; then git checkout -b "$DEFAULT_BRANCH" || git switch -c "$DEFAULT_BRANCH"
  elif [[ "$cur" != "$DEFAULT_BRANCH" ]]; then git branch -M "$DEFAULT_BRANCH" || git switch -c "$DEFAULT_BRANCH"; fi
}

remote_exists(){ git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; }

get_git_user(){ git config --get user.name || true; }
get_git_email(){ git config --get user.email || true; }

require_identities(){
  [[ -n "${GITX_GH_USER:-}" ]] || die "GITX_GH_USER not set (installer should have created it)."
  [[ -n "${GITHUB_TOKEN:-}"  ]] || die "GITHUB_TOKEN not set (installer should have created it)."
  local u e; u="$(get_git_user)"; e="$(get_git_email)"
  [[ -n "$u" ]] || die "Git user.name not set (global)."
  [[ -n "$e" ]] || die "Git user.email not set (global)."
  printf "%s" "$GITX_GH_USER"
}

gh_repo_exists(){
  local user="$1" repo="$2"
  curl -fsS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${user}/${repo}" | grep -q '^200$'
}

gh_create_repo(){
  local user="$1" repo="$2" private="${3:-false}" status
  status="$(curl -fsS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${repo}\",\"private\":${private}}" \
    https://api.github.com/user/repos || true)"
  case "$status" in
    201) ok "GitHub repo created: ${user}/${repo}";;
    422) info "Repo already exists on GitHub: ${user}/${repo}";;
    *)   die "Failed to create repo (HTTP $status)";;
  esac
}

ensure_remote(){
  local user="$1" repo="$2" url="https://github.com/${user}/${repo}.git"
  if remote_exists; then
    local cur; cur="$(git remote get-url "$REMOTE_NAME")"
    [[ "$cur" == "$url" ]] || { info "Updating remote '$REMOTE_NAME' -> $url"; git remote set-url "$REMOTE_NAME" "$url"; }
  else
    info "Adding remote '$REMOTE_NAME' -> $url"; git remote add "$REMOTE_NAME" "$url"
  fi
}

git_push(){ git push -u "$REMOTE_NAME" "$DEFAULT_BRANCH"; }
git_pull_ff(){
  git fetch "$REMOTE_NAME" "$DEFAULT_BRANCH"
  git pull --ff-only "$REMOTE_NAME" "$DEFAULT_BRANCH" || { warn "Fast-forward failed; attempting rebase…"; git pull --rebase "$REMOTE_NAME" "$DEFAULT_BRANCH"; }
}

cmd_help(){
  cat <<'HLP'
gitx — GitHub helper for publish, push, and pull

USAGE:
  gitx publish [--debug] [--private]
  gitx push    [--debug] [--msg "commit message"]
  gitx pull    [--debug]
  gitx --help
HLP
}

cmd_publish(){
  local private=false; [[ "${1:-}" == "--private" ]] && { private=true; shift; }
  ensure_repo; ensure_safe_dir
  local gh_user repo; gh_user="$(require_identities)"; repo="${CURRENT_DIR}"

  gh_repo_exists "$gh_user" "$repo" || gh_create_repo "$gh_user" "$repo" "$private"
  ensure_remote "$gh_user" "$repo"

  git add -A
  if ! git diff --cached --quiet; then git commit -m "chore: initial commit via gitx"; else info "Nothing to commit."; fi
  git_push
  printf "%s\n" "✔ Published to https://github.com/${gh_user}/${repo}"
}

cmd_push(){
  local msg="chore: update via gitx"
  if [[ "${1:-}" == "--msg" ]]; then shift; msg="${1:-$msg}"; [[ -n "${1:-}" ]] && shift || true; fi
  ensure_repo; ensure_safe_dir

  if ! remote_exists; then
    local gh_user repo; gh_user="$(require_identities)"; repo="${CURRENT_DIR}"
    gh_repo_exists "$gh_user" "$repo" || gh_create_repo "$gh_user" "$repo" "false"
    ensure_remote "$gh_user" "$repo"
  fi

  git add -A
  if git status --porcelain | grep -q .; then git commit -m "$msg" || true; else info "Nothing changed; pushing current branch state."; fi
  git_push
  ok "Pushed to $REMOTE_NAME/$DEFAULT_BRANCH"
}

cmd_pull(){
  ensure_repo; ensure_safe_dir; remote_exists || die "No remote 'origin' configured. Run 'gitx publish' first."
  git_pull_ff; ok "Local branch is up-to-date with $REMOTE_NAME/$DEFAULT_BRANCH."
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

# ---------- Main ----------
main(){
  require_cmd git; require_cmd curl
  ensure_localbin
  configure_git_identity
  configure_github_auth
  write_gitx
  info "Done. Open a new shell or 'source' your rc to ensure env is loaded."
}
main "$@"
