#!/usr/bin/env bash
# install.sh — stand up a WireGuard VPN gateway on a fresh Ubuntu/Debian server.
#
#   PORTABLE   nothing is hardcoded — the WAN interface, public IP and SSH port
#              are all auto-detected (override any of them with flags).
#   IDEMPOTENT safe to re-run; existing server keys and client peers are preserved.
#   SAFE       your live SSH port is allowed in the firewall BEFORE UFW is enabled,
#              so a mistake here can't lock you out of the machine.
#
# Usage:
#   sudo ./install.sh
#   sudo ./install.sh --endpoint vpn.example.com --port 51820
#   sudo ./install.sh --subnet 10.13.13.0/24 --dns 9.9.9.9 --no-ufw --yes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ASSUME_YES=0
USE_UFW=1

usage() {
  cat <<EOF
${C_CYAN}${C_B}wireguard-gateway installer${C_R}

  sudo ./install.sh [options]

Options:
  --port <n>          UDP listen port            (default 51820)
  --subnet <cidr>     VPN subnet                 (default 10.66.66.0/24)
  --server-ip <ip>    gateway VPN address        (default 10.66.66.1)
  --dns "<a, b>"      DNS pushed to clients      (default 1.1.1.1, 1.0.0.1)
  --endpoint <host>   public host clients dial   (default: auto-detect public IP)
  --interface <if>    WAN uplink for NAT         (default: auto-detect default route)
  --no-ufw            don't touch the firewall
  -y, --yes           assume yes (non-interactive)
  -h, --help          show this help
EOF
}

# ── arg parse (CLI flags override config + defaults) ─────────────────────────────
for a in "$@"; do [[ "$a" == -h || "$a" == --help ]] && { usage; exit 0; }; done
require_root "$@"
wg_load_config

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       WG_PORT="$2";       shift 2;;
    --subnet)     WG_SUBNET="$2";     shift 2;;
    --server-ip)  WG_SERVER_IP="$2";  shift 2;;
    --dns)        WG_DNS="$2";        shift 2;;
    --endpoint)   WG_ENDPOINT="$2";   shift 2;;
    --interface)  WAN_IF="$2";        shift 2;;
    --no-ufw)     USE_UFW=0;          shift;;
    -y|--yes)     ASSUME_YES=1;       shift;;
    *) die "unknown option: $1  (try --help)";;
  esac
done
WG_CONF="$WG_DIR/$WG_IF.conf"

# ── detection ────────────────────────────────────────────────────────────────────
detect_wan_if() {
  ip -4 route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

detect_public_ip() {
  local ip url
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || true
    [[ "$ip" =~ ^[0-9.]+$ ]] && { echo "$ip"; return 0; }
  done
  # fallback: primary address on the WAN interface
  ip -4 addr show "$WAN_IF" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}

detect_ssh_port() {
  local p
  p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  [[ -z "$p" ]] && p="$(ss -tlnH 'sport = :ssh' 2>/dev/null | awk '{split($4,a,":"); print a[length(a)]; exit}')"
  echo "${p:-22}"
}

# ── steps ────────────────────────────────────────────────────────────────────────
install_packages() {
  command -v apt-get >/dev/null || die "this installer targets Debian/Ubuntu (apt-get not found)"
  log "installing packages: wireguard, wireguard-tools, qrencode, ufw, curl …"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard wireguard-tools qrencode ufw curl iproute2 >/dev/null
  ok "packages installed"
}

ensure_forwarding() {
  log "enabling IPv4 forwarding (persistent) …"
  local f=/etc/sysctl.d/99-wireguard-gateway.conf
  echo "net.ipv4.ip_forward = 1" > "$f"
  sysctl -q -p "$f" >/dev/null 2>&1 || sysctl -q -w net.ipv4.ip_forward=1 >/dev/null
  ok "net.ipv4.ip_forward = 1  ($f)"
}

generate_server_keys() {
  umask 077
  mkdir -p "$WG_DIR"
  if [[ -f "$WG_DIR/server.key" ]]; then
    ok "server keypair already present — keeping it"
  else
    log "generating server keypair …"
    wg genkey | tee "$WG_DIR/server.key" | wg pubkey > "$WG_DIR/server.pub"
    chmod 600 "$WG_DIR/server.key"
    ok "server keypair created"
  fi
  SERVER_PRIV="$(cat "$WG_DIR/server.key")"
  SERVER_PUB="$(cat "$WG_DIR/server.pub")"
}

write_server_conf() {
  local endpoint="$WG_ENDPOINT"
  [[ "$endpoint" == auto ]] && endpoint="$(detect_public_ip)"
  [[ -n "$endpoint" ]] || warn "could not determine a public endpoint — set --endpoint later"

  # preserve any existing [Peer] blocks across re-runs
  local peers=""
  [[ -f "$WG_CONF" ]] && peers="$(awk '/^\[Peer\]/{p=1} p{print}' "$WG_CONF")"

  log "writing $WG_CONF …"
  umask 077
  {
    echo "# Managed by wireguard-gateway — github.com/heian-sukuna/wireguard-gateway"
    echo "# The [Interface] block is regenerated on each install; [Peer] blocks are preserved."
    echo "[Interface]"
    echo "Address    = $WG_SERVER_IP/${WG_SUBNET#*/}"
    echo "ListenPort = $WG_PORT"
    echo "PrivateKey = $SERVER_PRIV"
    echo
    echo "PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE"
    echo "PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE"
    [[ -n "$peers" ]] && { echo; echo "$peers"; }
  } > "$WG_CONF"
  chmod 600 "$WG_CONF"

  # state file so add-client/status don't have to re-detect anything
  cat > "$WG_DIR/gateway.env" <<EOF
WG_IF=$WG_IF
WG_PORT=$WG_PORT
WG_SUBNET=$WG_SUBNET
WG_SERVER_IP=$WG_SERVER_IP
WG_DNS=$WG_DNS
WG_ENDPOINT=$endpoint
WAN_IF=$WAN_IF
EOF
  PUBLIC_ENDPOINT="$endpoint"
  ok "server config written  (endpoint ${endpoint:-?}:$WG_PORT · nat via $WAN_IF)"
}

configure_ufw() {
  [[ $USE_UFW -eq 1 ]] || { warn "skipping firewall setup (--no-ufw)"; return; }
  command -v ufw >/dev/null || { warn "ufw not installed — skipping"; return; }

  local ssh_port; ssh_port="$(detect_ssh_port)"
  log "configuring UFW  (detected SSH on port $ssh_port) …"

  # CRITICAL ORDER: allow SSH *first* so enabling the firewall can never lock us out.
  ufw allow "$ssh_port/tcp" comment 'SSH (auto-detected by wireguard-gateway)' >/dev/null
  ufw allow "$WG_PORT/udp" comment 'WireGuard' >/dev/null
  ufw route allow in on "$WG_IF" out on "$WAN_IF" >/dev/null 2>&1 || true

  # forwarded packets must be accepted for the VPN to route traffic out
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

  if ufw status | grep -q "Status: active"; then
    ufw reload >/dev/null
    ok "UFW rules updated and reloaded"
  elif confirm "Enable UFW now? SSH ($ssh_port/tcp) is already allowed."; then
    ufw --force enable >/dev/null
    ok "UFW enabled"
  else
    warn "UFW left disabled — rules are staged; run 'ufw enable' when ready"
  fi
}

enable_service() {
  log "enabling wg-quick@$WG_IF …"
  systemctl enable "wg-quick@$WG_IF" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "wg-quick@$WG_IF"; then
    # apply the refreshed config without dropping live peers
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") 2>/dev/null \
      || systemctl restart "wg-quick@$WG_IF"
  else
    systemctl start "wg-quick@$WG_IF"
  fi
  systemctl is-active --quiet "wg-quick@$WG_IF" \
    && ok "wg-quick@$WG_IF is up" \
    || die "wg-quick@$WG_IF failed to start — check: journalctl -u wg-quick@$WG_IF"
}

print_summary() {
  hr
  ok "WireGuard gateway is live."
  printf '\n'
  printf '  %sinterface%s  %s\n' "$C_GRY" "$C_R" "$WG_IF"
  printf '  %sendpoint%s   %s:%s/udp\n' "$C_GRY" "$C_R" "${PUBLIC_ENDPOINT:-<set --endpoint>}" "$WG_PORT"
  printf '  %ssubnet%s     %s  (gateway %s)\n' "$C_GRY" "$C_R" "$WG_SUBNET" "$WG_SERVER_IP"
  printf '  %sserver pub%s %s\n' "$C_GRY" "$C_R" "$SERVER_PUB"
  printf '\n'
  log "next steps:"
  printf '    %s1.%s add a device:   %ssudo ./add-client.sh phone%s\n' "$C_MAG$C_B" "$C_R" "$C_CYAN" "$C_R"
  printf '    %s2.%s watch traffic:  %ssudo ./wg-status.sh --watch%s\n' "$C_MAG$C_B" "$C_R" "$C_CYAN" "$C_R"
  printf '    %s3.%s if behind a router, forward %s%s/udp%s to this host\n' "$C_MAG$C_B" "$C_R" "$C_YEL" "$WG_PORT" "$C_R"
  hr
}

# ── run ──────────────────────────────────────────────────────────────────────────
banner
[[ "$WAN_IF" == auto ]] && WAN_IF="$(detect_wan_if)"
[[ -n "$WAN_IF" ]] || die "could not detect the WAN interface — pass --interface <iface>"
log "target: WAN interface ${C_CYAN}$WAN_IF${C_R}"

install_packages
ensure_forwarding
generate_server_keys
write_server_conf
configure_ufw
enable_service
print_summary
