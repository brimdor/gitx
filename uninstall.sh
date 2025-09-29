#!/usr/bin/env bash
# uninstall.sh — safely remove the `gitx` CLI
# Default:
#   • Remove ~/.local/bin/gitx
#   • Leave your shell rc files alone
#
# Flags:
#   --purge  Also remove PATH lines added by installer + 'source ~/.config/gitx/.env'
#   --debug  Verbose tracing
#   --help   Show help

set -euo pipefail

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
say()  { printf "%s\n" "$*"; }
info() { printf "%s\n" "${DIM}==>${NC} $*"; }
ok()   { printf "%s\n" "${GREEN}✔${NC} $*"; }
warn() { printf "%s\n" "${YELLOW}⚠${NC} $*"; }
err()  { printf "%s\n" "${RED}✖${NC} $*" 1>&2; }
die()  { err "$*"; exit 1; }

DEBUG=0
PURGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) DEBUG=1; shift ;;
    --purge) PURGE=1; shift ;;
    --help|-h)
      cat <<'HLP'
uninstall.sh — remove the gitx CLI

USAGE:
  ./uninstall.sh [--purge] [--debug]

OPTIONS:
  --purge   Also remove PATH lines the installer added to your shell rc files
            and any 'source ~/.config/gitx/.env' lines (bash/zsh/fish).
  --debug   Enable verbose tracing.
  --help    Show this help.
HLP
      exit 0 ;;
    *) die "Unknown option: $1 (use --help)";;
  esac
done

[[ "$DEBUG" == "1" ]] && { PS4="+ [uninstall:\${LINENO}] "; set -x; }

GITX_BIN="$HOME/.local/bin/gitx"
LOCAL_BIN_DIR="$HOME/.local/bin"
GITX_ENV_FILE="$HOME/.config/gitx/.env"
GITX_CFG_DIR="$HOME/.config/gitx"

remove_gitx() {
  if [[ -f "$GITX_BIN" ]]; then
    rm -f "$GITX_BIN"
    ok "Removed $GITX_BIN"
  else
    info "gitx not found at $GITX_BIN (already removed)."
  fi
}

purge_path_lines() {
  info "Purging PATH and env sourcing lines added by the installer…"

  case "${SHELL##*/}" in
    bash) RC_FILES=(~/.bashrc ~/.bash_profile ~/.profile) ;;
    zsh)  RC_FILES=(~/.zshrc ~/.zprofile ~/.zshenv) ;;
    fish) RC_FILES=(~/.config/fish/config.fish) ;;
    *)    RC_FILES=(~/.profile); warn "Unknown shell '${SHELL##*/}'; scanning ~/.profile only." ;;
  esac

  for rc in "${RC_FILES[@]}"; do
    [[ -f "$rc" ]] || continue
    tmp="${rc}.gitx-uninstall.tmp"

    if [[ "$rc" == *"config/fish/config.fish" ]]; then
      # Remove fish PATH line and env source line
      sed -e '/^[[:space:]]*set[[:space:]]\+-gx[[:space:]]\+PATH[[:space:]]\+~\/\.local\/bin[[:space:]]\+\$PATH[[:space:]]*$/d' \
          -e '/^[[:space:]]*source[[:space:]]\+~\/\.config\/gitx\/\.env[[:space:]]*$/d' \
          "$rc" > "$tmp" || true
    else
      # Remove bash/zsh PATH line and env source line
      sed -e '/^[[:space:]]*export[[:space:]]\+PATH="\$HOME\/\.local\/bin:\$PATH"[[:space:]]*$/d' \
          -e '/^[[:space:]]*source[[:space:]]\+~\/\.config\/gitx\/\.env[[:space:]]*$/d' \
          "$rc" > "$tmp" || true
    fi

    if ! cmp -s "$rc" "$tmp"; then
      mv "$tmp" "$rc"
      ok "Cleaned entries in $(basename "$rc")"
    else
      rm -f "$tmp"
      info "No matching entries in $(basename "$rc")"
    fi
  done

  # Remove env file and possibly the directory
  if [[ -f "$GITX_ENV_FILE" ]]; then
    rm -f "$GITX_ENV_FILE"
    ok "Removed $GITX_ENV_FILE"
  fi
  if [[ -d "$GITX_CFG_DIR" ]]; then
    rmdir "$GITX_CFG_DIR" 2>/dev/null && ok "Removed empty $GITX_CFG_DIR" || true
  fi

  # If running in a sourced context, update PATH in the current session.
  if [[ "${BASH_SOURCE[0]:-}" != "$0" || "${ZSH_EVAL_CONTEXT:-}" == *:file ]]; then
    case "${SHELL##*/}" in
      fish)
        # Best-effort: remove ~/.local/bin from current PATH (fish syntax varies per session)
        # Users can restart fish to fully refresh.
        true
        ;;
      *)
        # Safe, quote-proof PATH filter:
        # Rebuild PATH excluding $HOME/.local/bin
        P_REMOVE="$HOME/.local/bin"
        NEWPATH="$(awk -v RS=: -v ORS=: -v P="$P_REMOVE" 'NF && $0!=P {printf "%s", $0 ORS}' <<<"$PATH")"
        NEWPATH="${NEWPATH%:}"
        export PATH="$NEWPATH"
        ok "PATH updated for current session."
        ;;
    esac
  else
    info "Restart your shell or 'source' your rc file(s) to refresh PATH."
  fi
}

maybe_remove_empty_dir() {
  if [[ "$PURGE" -eq 1 && -d "$LOCAL_BIN_DIR" ]]; then
    if rmdir "$LOCAL_BIN_DIR" 2>/dev/null; then
      ok "Removed empty directory $LOCAL_BIN_DIR"
    else
      info "$LOCAL_BIN_DIR not empty; leaving it."
    fi
  fi
}

main() {
  remove_gitx
  if [[ "$PURGE" -eq 1 ]]; then
    purge_path_lines
    maybe_remove_empty_dir
  else
    info "Kept your PATH configuration. Use --purge to remove installer-added PATH and env sourcing lines."
  fi
  ok "Uninstall complete."
}

main "$@"
