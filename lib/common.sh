#!/usr/bin/env bash
# lib/common.sh — shared helpers + cyberpunk palette for the WireGuard Gateway toolkit.
# Sourced by install.sh, add-client.sh, remove-client.sh, wg-status.sh, uninstall.sh.
# Not meant to be executed directly.

# ── neon palette (256-color; auto-disabled when not a TTY or when NO_COLOR set) ──
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_CYAN=$'\e[38;5;51m'  ; C_MAG=$'\e[38;5;201m' ; C_GRN=$'\e[38;5;46m'
  C_YEL=$'\e[38;5;226m'  ; C_RED=$'\e[38;5;196m' ; C_GRY=$'\e[38;5;240m'
  C_B=$'\e[1m'           ; C_DIM=$'\e[2m'        ; C_R=$'\e[0m'
else
  C_CYAN= ; C_MAG= ; C_GRN= ; C_YEL= ; C_RED= ; C_GRY= ; C_B= ; C_DIM= ; C_R=
fi

# ── logging ─────────────────────────────────────────────────────────────────────
log()  { printf '%s[»]%s %s\n' "$C_CYAN$C_B" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_GRN$C_B" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL$C_B" "$C_R" "$*" >&2; }
err()  { printf '%s[✗]%s %s\n' "$C_RED$C_B" "$C_R" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s%s%s\n' "$C_GRY" "──────────────────────────────────────────────────────────────" "$C_R"; }

banner() {
  # Borders are generated to a fixed interior width so they can never drift, and
  # the content is ASCII-only so printf pads by display columns in any locale.
  local w=34 bar l1 l2
  printf -v bar '%*s' "$w" ''; bar="${bar// /─}"
  l1="  WIREGUARD :: GATEWAY"
  l2="  zero-trust personal VPN"
  printf '%s'          "$C_CYAN$C_B"
  printf '   ┌%s┐\n'    "$bar"
  printf '   │%s%*s│\n' "$l1" "$(( w - ${#l1} ))" ''
  printf '   │%s%*s│\n' "$l2" "$(( w - ${#l2} ))" ''
  printf '   └%s┘\n'    "$bar"
  printf '%s\n'        "$C_R"
}

# ── interaction ─────────────────────────────────────────────────────────────────
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "this must run as root — try:  sudo $0 $*"
}

# confirm "question"  → returns 0 on yes. Honors a global ASSUME_YES=1 for non-interactive runs.
confirm() {
  [[ "${ASSUME_YES:-0}" -eq 1 ]] && return 0
  local reply
  read -rp "$(printf '%s[?]%s %s [y/N] ' "$C_MAG$C_B" "$C_R" "$1")" reply || true
  [[ "$reply" =~ ^[Yy] ]]
}

# ── formatting ──────────────────────────────────────────────────────────────────
# human <bytes> → "12MiB"
human() {
  local b="${1:-0}" units=(B KiB MiB GiB TiB) i=0
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  while (( b >= 1024 && i < 4 )); do b=$(( b / 1024 )); i=$(( i + 1 )); done
  printf '%s%s' "$b" "${units[$i]}"
}

# ── configuration (defaults ← config/gateway.conf ← env) ─────────────────────────
# Precedence, lowest→highest: built-in defaults, config/gateway.conf, environment,
# and finally CLI flags (applied by the caller after this runs).
wg_load_config() {
  local root cfg
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cfg="$root/config/gateway.conf"
  if [[ -f "$cfg" ]]; then
    log "loading overrides from config/gateway.conf"
    # shellcheck disable=SC1090
    source "$cfg"
  fi

  WG_IF="${WG_IF:-wg0}"
  WG_PORT="${WG_PORT:-51820}"
  WG_SUBNET="${WG_SUBNET:-10.66.66.0/24}"
  WG_SERVER_IP="${WG_SERVER_IP:-10.66.66.1}"
  WG_DNS="${WG_DNS:-1.1.1.1, 1.0.0.1}"
  WG_ENDPOINT="${WG_ENDPOINT:-auto}"
  WAN_IF="${WAN_IF:-auto}"
  WG_DIR="${WG_DIR:-/etc/wireguard}"
  WG_CONF="$WG_DIR/$WG_IF.conf"
}

# wg_subnet_base → first three octets of WG_SUBNET, e.g. "10.66.66"
wg_subnet_base() { local n="${WG_SUBNET%/*}"; echo "${n%.*}"; }
