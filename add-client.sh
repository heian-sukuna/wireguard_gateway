#!/usr/bin/env bash
# add-client.sh — create a WireGuard peer.
# Appends a [Peer] to the server, applies it live (no other peers dropped),
# writes a full-tunnel client config and prints a phone-scannable QR code.
#
#   sudo ./add-client.sh phone
#   sudo ./add-client.sh laptop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root "$@"

NAME="${1:-}"
[[ -n "$NAME" ]] || die "usage: $0 <client-name>    e.g.  $0 phone"
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "client name may only contain letters, digits, '-' and '_'"

wg_load_config
# the state written by install.sh is authoritative if present
[[ -f "$WG_DIR/gateway.env" ]] && { . "$WG_DIR/gateway.env"; WG_CONF="$WG_DIR/$WG_IF.conf"; }

[[ -f "$WG_CONF" ]]          || die "$WG_CONF not found — run ./install.sh first"
[[ -f "$WG_DIR/server.pub" ]] || die "server public key missing — run ./install.sh first"

SERVER_PUB="$(cat "$WG_DIR/server.pub")"
ENDPOINT="$WG_ENDPOINT"
[[ -z "$ENDPOINT" || "$ENDPOINT" == auto ]] && \
  die "no public endpoint recorded — re-run ./install.sh --endpoint <host>"

# ── choose the next free address in the /24 ──────────────────────────────────────
BASE="$(wg_subnet_base)"                       # e.g. 10.66.66
esc="${BASE//./\\.}"
last="$(grep -oE "AllowedIPs *= *${esc}\.[0-9]+" "$WG_CONF" 2>/dev/null \
        | grep -oE '[0-9]+$' | sort -n | tail -1)"
next=$(( ${last:-1} + 1 ))
[[ $next -lt 255 ]] || die "subnet $WG_SUBNET has no free addresses left"
CLIENT_IP="$BASE.$next"

CLIENT_DIR="$SCRIPT_DIR/clients"
CLIENT_CONF="$CLIENT_DIR/$NAME.conf"
[[ -e "$CLIENT_CONF" ]] && die "client '$NAME' already exists ($CLIENT_CONF)"

# ── keys ─────────────────────────────────────────────────────────────────────────
umask 077
mkdir -p "$CLIENT_DIR"
priv="$(wg genkey)"
pub="$(printf '%s' "$priv" | wg pubkey)"
psk="$(wg genpsk)"

# ── append peer to the server config ─────────────────────────────────────────────
{
  echo
  echo "[Peer]"
  echo "# $NAME  (added $(date -u +%Y-%m-%dT%H:%MZ))"
  echo "PublicKey    = $pub"
  echo "PresharedKey = $psk"
  echo "AllowedIPs   = $CLIENT_IP/32"
} >> "$WG_CONF"

# ── write the client config ──────────────────────────────────────────────────────
cat > "$CLIENT_CONF" <<EOF
# wireguard-gateway client: $NAME
[Interface]
PrivateKey = $priv
Address    = $CLIENT_IP/32
DNS        = $WG_DNS

[Peer]
PublicKey           = $SERVER_PUB
PresharedKey        = $psk
Endpoint            = $ENDPOINT:$WG_PORT
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF"

# ── apply to the live interface without disturbing existing peers ────────────────
if systemctl is-active --quiet "wg-quick@$WG_IF"; then
  wg set "$WG_IF" peer "$pub" preshared-key <(printf '%s' "$psk") allowed-ips "$CLIENT_IP/32"
  ok "peer applied to live interface $WG_IF"
fi

ok "client '$NAME' created  →  $CLIENT_CONF   (VPN IP $CLIENT_IP)"
hr
log "scan with the WireGuard mobile app:"
echo
qrencode -t ansiutf8 < "$CLIENT_CONF"
echo
if qrencode -o "$CLIENT_DIR/$NAME.png" < "$CLIENT_CONF" 2>/dev/null; then
  log "QR also saved as image  →  $CLIENT_DIR/$NAME.png"
fi
hr
