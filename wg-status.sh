#!/usr/bin/env bash
# wg-status.sh — neon live status board for the WireGuard gateway.
#
#   sudo ./wg-status.sh            one-shot snapshot
#   sudo ./wg-status.sh --watch    refresh every 2s (ctrl-c to exit)
#
# Read-only: -e is intentionally omitted so empty handshake/transfer fields
# never abort the render.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root "$@"
wg_load_config
[[ -f "$WG_DIR/gateway.env" ]] && . "$WG_DIR/gateway.env"

# map a public key back to a friendly client name via clients/*.conf
peer_label() {
  local target="$1" f p
  for f in "$SCRIPT_DIR"/clients/*.conf; do
    [[ -e "$f" ]] || continue
    p="$(awk -F'= *' '/PrivateKey/{print $2; exit}' "$f" | wg pubkey 2>/dev/null)"
    [[ "$p" == "$target" ]] && { basename "$f" .conf; return; }
  done
  echo "${target:0:10}…"
}

render() {
  clear 2>/dev/null || true
  printf '%s' "$C_MAG$C_B"
  cat <<'BANNER'
   ╦ ╦╔═╗   ╔═╗╔═╗╔╦╗╔═╗╦ ╦╔═╗╦ ╦
   ║║║║ ╦   ║ ╦╠═╣ ║ ║╣ ║║║╠═╣╚╦╝
   ╚╩╝╚═╝   ╚═╝╩ ╩ ╩ ╚═╝╚╩╝╩ ╩ ╩
BANNER
  printf '%s' "$C_R"

  if ! wg show "$WG_IF" >/dev/null 2>&1; then
    err "interface $WG_IF is down (start it: systemctl start wg-quick@$WG_IF)"
    return
  fi

  local port pubkey peers now
  port="$(wg show "$WG_IF" listen-port 2>/dev/null)"
  pubkey="$(cat "$WG_DIR/server.pub" 2>/dev/null || echo '?')"
  peers="$(wg show "$WG_IF" peers 2>/dev/null | grep -c . || true)"
  now="$(date -u +'%Y-%m-%d %H:%M:%SZ')"

  printf '  %sinterface%s %s%-6s%s  %sport%s %-6s  %sendpoint%s %s\n' \
    "$C_GRY" "$C_R" "$C_CYAN$C_B" "$WG_IF" "$C_R" \
    "$C_GRY" "$C_R" "$port" "$C_GRY" "$C_R" "${WG_ENDPOINT:-?}:${WG_PORT:-?}"
  printf '  %ssrv pub%s   %s\n'   "$C_GRY" "$C_R" "$pubkey"
  printf '  %speers%s     %s%s connected%s\n' "$C_GRY" "$C_R" "$C_GRN$C_B" "$peers" "$C_R"
  hr
  printf '  %s%-20s %-15s %-13s %-11s%s\n' "$C_B" "PEER" "VPN IP" "HANDSHAKE" "TRANSFER" "$C_R"

  local now_epoch; now_epoch="$(date +%s)"
  local pk aip hs rx tx label ago color
  while read -r pk; do
    [[ -z "$pk" ]] && continue
    aip="$(wg show "$WG_IF" allowed-ips      2>/dev/null | awk -v k="$pk" '$1==k{print $2}')"
    hs="$( wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v k="$pk" '$1==k{print $2}')"
    read -r rx tx < <(wg show "$WG_IF" transfer 2>/dev/null | awk -v k="$pk" '$1==k{print $2, $3}')
    hs="${hs:-0}"; rx="${rx:-0}"; tx="${tx:-0}"
    label="$(peer_label "$pk")"
    if (( hs > 0 )); then
      ago="$(( now_epoch - hs ))s ago"
      (( now_epoch - hs > 180 )) && color="$C_YEL" || color="$C_GRN"
    else
      ago="never"; color="$C_GRY"
    fi
    printf '  %-20s %-15s %s%-13s%s %s↓%-8s%s %s↑%s\n' \
      "$label" "${aip%/*}" "$color" "$ago" "$C_R" \
      "$C_CYAN" "$(human "$rx")" "$C_R" "$C_MAG" "$(human "$tx")$C_R"
  done < <(wg show "$WG_IF" peers 2>/dev/null)

  hr
  printf '  %supdated %s · ctrl-c to exit%s\n' "$C_DIM" "$now" "$C_R"
}

if [[ "${1:-}" == --watch || "${1:-}" == -w ]]; then
  trap 'printf "%s\n" "$C_R"; exit 0' INT
  while :; do render; sleep 2; done
else
  render
fi
