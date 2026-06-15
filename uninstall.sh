#!/usr/bin/env bash
# uninstall.sh — tear down the WireGuard gateway. Leaves your SSH/UFW base intact.
#
#   sudo ./uninstall.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root "$@"
wg_load_config
[[ -f "$WG_DIR/gateway.env" ]] && . "$WG_DIR/gateway.env"

confirm "Stop wg-quick@$WG_IF and remove $WG_DIR (server keys + peers)?" || die "aborted"

systemctl disable --now "wg-quick@$WG_IF" 2>/dev/null || true
ok "wg-quick@$WG_IF stopped and disabled"

if command -v ufw >/dev/null && [[ -n "${WG_PORT:-}" ]]; then
  ufw delete allow "$WG_PORT/udp" >/dev/null 2>&1 || true
  ufw route delete allow in on "$WG_IF" out on "${WAN_IF:-eth0}" >/dev/null 2>&1 || true
  ok "WireGuard firewall rules removed (SSH rule left untouched)"
fi

rm -f /etc/sysctl.d/99-wireguard-gateway.conf
rm -rf "$WG_DIR"
ok "removed $WG_DIR and forwarding sysctl"
warn "local client configs in ./clients were NOT deleted — remove them manually if you wish"
