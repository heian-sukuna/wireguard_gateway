#!/usr/bin/env bash
# remove-client.sh — revoke a WireGuard peer and delete its local config + QR.
#
#   sudo ./remove-client.sh phone
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root "$@"

NAME="${1:-}"
[[ -n "$NAME" ]] || die "usage: $0 <client-name>    e.g.  $0 phone"

wg_load_config
[[ -f "$WG_DIR/gateway.env" ]] && { . "$WG_DIR/gateway.env"; WG_CONF="$WG_DIR/$WG_IF.conf"; }

CLIENT_CONF="$SCRIPT_DIR/clients/$NAME.conf"
[[ -f "$CLIENT_CONF" ]] || die "no client config found for '$NAME' ($CLIENT_CONF)"
[[ -f "$WG_CONF" ]]     || die "$WG_CONF not found"

confirm "Revoke client '$NAME'? This is irreversible." || die "aborted"

# derive the peer's public key from its stored private key
pub="$(awk -F'= *' '/PrivateKey/{print $2; exit}' "$CLIENT_CONF" | wg pubkey)"
[[ -n "$pub" ]] || die "could not derive public key from $CLIENT_CONF"

# drop it from the live interface
if systemctl is-active --quiet "wg-quick@$WG_IF"; then
  wg set "$WG_IF" peer "$pub" remove 2>/dev/null || true
  ok "peer removed from live interface $WG_IF"
fi

# strip the matching [Peer] paragraph from the server config (literal match — keys
# contain '+' and '/', which would be unsafe in a regex)
tmp="$(mktemp)"
awk -v key="$pub" '
  BEGIN { RS=""; FS="\n" }
  { if (index($0, "PublicKey") && index($0, key)) next; print $0 "\n" }
' "$WG_CONF" > "$tmp"
mv "$tmp" "$WG_CONF"
chmod 600 "$WG_CONF"

rm -f "$CLIENT_CONF" "$SCRIPT_DIR/clients/$NAME.png"
ok "client '$NAME' revoked and local files removed"
