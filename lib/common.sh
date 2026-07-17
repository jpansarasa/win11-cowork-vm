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

load_config() { source "${REPO_ROOT}/config.env"; }
