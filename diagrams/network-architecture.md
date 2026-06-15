# Network Architecture

How a client's traffic flows through the gateway. The encrypted tunnel
terminates on the server; the server then NATs the decrypted traffic out of its
WAN interface, so the whole internet sees the **server's** IP, not the client's.

```
   ┌────────────┐        encrypted WireGuard tunnel        ┌──────────────────────┐
   │   CLIENT   │   (UDP :51820, ChaCha20-Poly1305)        │      GATEWAY          │
   │ phone /    │ ───────────────────────────────────────▶ │  wg0  10.66.66.1      │
   │ laptop     │        AllowedIPs = 0.0.0.0/0            │  ───────────────────  │
   │ 10.66.66.2 │ ◀─────────────────────────────────────── │  ip_forward = 1       │
   └────────────┘                                          │  iptables MASQUERADE  │
                                                            └───────────┬──────────┘
                                                                        │  WAN (eno1)
                                                                        ▼
                                                                  ┌───────────┐
                                                                  │  INTERNET │
                                                                  └───────────┘
```

## Path of a packet

1. Client encrypts the packet and sends it to `server:51820/udp`.
2. `wg0` decrypts it; because `ip_forward=1`, the kernel routes it toward the WAN.
3. `iptables -t nat POSTROUTING MASQUERADE` rewrites the source to the server's
   WAN address.
4. Replies return to the server, are matched by conntrack, re-encrypted, and sent
   back down the tunnel to the client.

## Reachability requirement

The client must be able to reach `server:51820/udp` from the internet. That means
the server needs **one inbound UDP port**. On a home connection behind NAT/CGNAT
or a Cloudflare Tunnel this port is usually *not* reachable — see the README
"Reachability" section for the options (port-forward, cloud VPS, or Tailscale).
