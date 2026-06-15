#!/usr/bin/env bash
# install.sh — stand up a WireGuard VPN gateway on a fresh Linux server.
#              Supports Debian/Ubuntu (apt), Arch (pacman) and Fedora/RHEL (dnf).
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
  --endpoint <h>      host clients dial: an IP/DNS name, 'auto' (public IP, for a
                      VPS) or 'lan' (this box's LAN/host-only IP, for VMs)
  --interface <if>    WAN uplink for NAT         (default: auto-detect default route)
  --no-ufw            don't touch the firewall
  -y, --yes           assume yes (non-interactive)
  --list-interfaces   list NICs + IPs (to pick --interface/--endpoint) and exit
  -h, --help          show this help
EOF
}

# ── detection helpers (defined before arg-parse so --list-interfaces can use them) ─
detect_wan_if() {
  ip -4 route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# real, usable NICs — skips loopback and virtual/overlay interfaces so VMs and
# multi-NIC hosts present a clean list (name-agnostic: ethN, enpXsY, ensXX, …)
list_interfaces() {
  ip -o link show up 2>/dev/null \
    | awk -F': ' '{print $2}' | sed 's/@.*//' \
    | grep -vE '^(lo|wg[0-9]*|docker[0-9]*|br-.*|veth.*|tailscale[0-9]*|virbr.*)$'
}

# best address for clients to *dial* on a LAN/VM: prefer a private IPv4 that is
# NOT the VirtualBox NAT range (10.0.2.0/24, which is unreachable from the host).
detect_lan_ip() {
  local ips ip
  ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  ip="$(printf '%s\n' "$ips" | grep -vE '^10\.0\.2\.' | head -1)"
  [[ -z "$ip" ]] && ip="$(printf '%s\n' "$ips" | head -1)"
  printf '%s' "$ip"
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

# print NICs + IPv4s, plus suggested WAN/endpoint — for choosing flags in a VM
print_interfaces() {
  printf '%sdetected interfaces:%s\n' "$C_CYAN$C_B" "$C_R"
  local i ips
  while read -r i; do
    [[ -z "$i" ]] && continue
    ips="$(ip -4 -o addr show dev "$i" scope global 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
    printf '  %-14s %s\n' "$i" "${ips:-(no ipv4)}"
  done < <(list_interfaces)
  printf '%sdefault route / suggested --interface:%s %s\n' "$C_GRY" "$C_R" "$(detect_wan_if || echo '?')"
  printf '%ssuggested --endpoint lan:%s %s\n'              "$C_GRY" "$C_R" "$(detect_lan_ip || echo '?')"
}

# ── arg parse (CLI flags override config + defaults) ─────────────────────────────
for a in "$@"; do
  case "$a" in
    -h|--help)         usage; exit 0;;
    --list-interfaces) print_interfaces; exit 0;;
  esac
done
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

# ── steps ────────────────────────────────────────────────────────────────────────
detect_pkg_mgr() {
  if   command -v apt-get >/dev/null; then echo apt
  elif command -v pacman  >/dev/null; then echo pacman
  elif command -v dnf     >/dev/null; then echo dnf
  else echo ""; fi
}

install_packages() {
  local mgr; mgr="$(detect_pkg_mgr)"
  case "$mgr" in
    apt)
      log "installing packages via apt (wireguard, qrencode, ufw, curl) …"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq wireguard wireguard-tools qrencode ufw curl iproute2 >/dev/null
      ;;
    pacman)
      log "installing packages via pacman (wireguard-tools, qrencode, ufw, curl) …"
      pacman -Sy --needed --noconfirm wireguard-tools qrencode ufw curl iproute2 >/dev/null
      ;;
    dnf)
      log "installing packages via dnf (wireguard-tools, qrencode, ufw, curl) …"
      dnf install -y wireguard-tools qrencode ufw curl iproute >/dev/null
      ;;
    *)
      die "no supported package manager found (need apt, pacman, or dnf).
       Install these manually, then re-run: wireguard-tools qrencode ufw curl"
      ;;
  esac
  ok "packages installed ($mgr)"
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
  local endpoint
  case "$WG_ENDPOINT" in
    auto) endpoint="$(detect_public_ip)";;   # public IP — for a VPS / real internet host
    lan)  endpoint="$(detect_lan_ip)";;      # LAN / host-only IP — for VMs & local testing
    *)    endpoint="$WG_ENDPOINT";;          # explicit IP or DNS name
  esac
  [[ -n "$endpoint" ]] || warn "could not determine an endpoint — set --endpoint <host> later"

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
  [[ -f /etc/default/ufw ]] && \
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

  if ufw status | grep -q "Status: active"; then
    ufw reload >/dev/null
    ok "UFW rules updated and reloaded"
  elif confirm "Enable UFW now? SSH ($ssh_port/tcp) is already allowed."; then
    ufw --force enable >/dev/null
    systemctl enable ufw >/dev/null 2>&1 || true   # persist across reboots (Arch/others)
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
if [[ -z "$WAN_IF" ]]; then
  err "could not auto-detect the WAN interface."
  print_interfaces
  die "re-run with:  --interface <name>"
fi
log "target: WAN interface ${C_CYAN}$WAN_IF${C_R}  (egress / NAT)"

install_packages
ensure_forwarding
generate_server_keys
write_server_conf
configure_ufw
enable_service
print_summary
