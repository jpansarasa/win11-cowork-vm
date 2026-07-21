# shellcheck shell=bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

log()  { printf '[cowork] %s\n' "$*"; }
warn() { printf '[cowork] WARN: %s\n' "$*" >&2; }
die()  { printf '[cowork] ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"; }
confirm() { local a; read -r -p "$1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }
cpu_has_virt() { printf '%s' "$1" | grep -Eq '(vmx|svm)'; }

# config.env is tracked and holds portable defaults. Site-specific values (a
# topic URL, a hostname) belong in config.local.env, which is gitignored — so a
# public clone can never leak them. Sourced second, so it wins.
load_config() {
  source "${REPO_ROOT}/config.env"
  if [ -f "${REPO_ROOT}/config.local.env" ]; then
    source "${REPO_ROOT}/config.local.env"
  fi
}
