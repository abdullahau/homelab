# Hysteria2 on Oracle Phoenix (`oracle` / 129.146.179.208)

A single-user Hysteria2 (QUIC) proxy endpoint on the Oracle Cloud Phoenix VPS,
used to get US-egress internet from macOS / iOS / iPadOS clients.

**Live location:** `~/Developer/dotfiles/hysteria` on the VPS (user `ubuntu`, branch `vps`).
**Reference copy:** `/docker/hysteria` on the homelab (this directory).

> Moving this directory **breaks the running container**: Docker resolves the
> bind-mount source paths at container-create time, so an already-running
> container keeps working while the old path is gone, then fails on the next
> restart/reboot (Docker recreates the missing source as an empty *directory*).
> After any move, re-run `docker compose -f hysteria-docker-compose.yml up -d
> --force-recreate` from the new location and confirm with
> `docker inspect hysteria --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}'`.

---

## Why this and not Hiddify Manager

The Hiddify *app* (the App Store client) does **not** require Hiddify *Manager*
(the server appliance). The client imports any `hysteria2://` URI, so we get the
polished client with a 20-line compose file instead of a server appliance.

This matters because Hiddify Manager takes ownership of the host's networking —
nginx/haproxy on 80/443, cert issuance, and **firewall management**. This VPS
already has hand-maintained rules that nothing else owns:

```
nat PREROUTING  -i enp0s6 -p tcp --dport 32400 -j DNAT --to ${HOST_TS_IP}:32400
nat POSTROUTING -d ${HOST_TS_IP}/32 -p tcp --dport 32400 -j MASQUERADE
filter FORWARD  -d ${HOST_TS_IP}/32 -p tcp --dport 32400 -j ACCEPT
```

That is the **Plex reverse path** to the homelab. Alongside it are Tailscale's
`ts-input` / `ts-forward` / `ts-postrouting` chains. Do not install anything on
this box that manages iptables for you.

---

## Why Hysteria2 specifically

Dubai → Phoenix is **~256 ms RTT**. Over that path a normal TCP tunnel is
*receive-window limited*, not bandwidth limited: throughput = window ÷ RTT.
A 1 MiB window gives `1048576 × 8 ÷ 0.256 ≈ 33 Mbps`, which is exactly what the
Tailscale exit node delivers on macOS/iOS.

You cannot fix that on iOS — there is no sysctl access. Hysteria2 sidesteps it
entirely: the tunnel is QUIC/UDP, so the OS TCP stack no longer governs the long
leg. The client manages its own flow-control windows in userspace, and its
"brutal" congestion control **sends at a declared rate** rather than backing off
on loss.

---

## Files

| File | Committed? | Purpose |
|---|---|---|
| `hysteria-docker-compose.yml` | yes | the service |
| `config.yaml.template` | yes | config with `${HYSTERIA_PASSWORD}` placeholder |
| `render.sh` | yes | renders template + `.env` → `config.yaml` |
| `.env.example` | yes | shows required vars |
| `README.md` | yes | this file |
| `.env` | **no** | the actual password (mode 600) |
| `config.yaml` | **no** | rendered, contains the password (mode 600) |
| `certs/` | **no** | TLS keypair |

### Why the template + render step

**Hysteria does not expand `${VAR}` in its config file.** Its documented env
vars (`HYSTERIA_LOG_LEVEL`, `HYSTERIA_ACME_DIR`, …) are a fixed set of runtime
knobs, and the docs state config-file values take precedence over them. There is
no `HYSTERIA_AUTH_PASSWORD` override.

Docker Compose's `.env` interpolation does **not** help either — Compose
substitutes variables inside the *compose file*, never inside a mounted volume.

So a literal `password: ${HYSTERIA_PASSWORD}` in `config.yaml` would set the
password to the 21-character string `${HYSTERIA_PASSWORD}`. `render.sh` does the
substitution at deploy time, which keeps the secret in `.env` and out of git.

---

## Replicating from scratch

```bash
mkdir -p ~/Developer/dotfiles/hysteria/certs && cd ~/Developer/dotfiles/hysteria
# copy in: hysteria-docker-compose.yml config.yaml.template render.sh .env.example

cp .env.example .env
sed -i "s|replace-me|$(openssl rand -base64 32 | tr -d '/+=' | head -c 40)|" .env
chmod 600 .env

./render.sh                       # -> config.yaml (mode 600)

# self-signed cert, ECDSA P-256 (cheaper handshakes than RSA on a QUIC tunnel)
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout certs/key.pem -out certs/cert.pem -days 3650 \
  -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com"
chmod 600 certs/key.pem && chmod 644 certs/cert.pem

docker compose -f hysteria-docker-compose.yml up -d
```

Then add the OCI ingress rule below.

---

## OCI ingress rule — REQUIRED, and easy to forget

Oracle gives the instance a **private** address (`10.0.0.42` on `enp0s6`) and
1:1 NATs the public IP (`129.146.179.208`). The port is unreachable from the
internet until it is opened in the VCN, no matter what is listening locally.

**Console → Networking → Virtual Cloud Networks → *your VCN* → Security Lists
→ Default Security List → Add Ingress Rule:**

| Field | Value |
|---|---|
| Stateless | No |
| Source Type | CIDR |
| Source CIDR | `0.0.0.0/0` |
| IP Protocol | **UDP** |
| Destination Port Range | `443` |

UDP, not TCP — Hysteria2 is QUIC. A TCP/443 rule does nothing here.

Verify from outside: `nc -zvu 129.146.179.208 443` (UDP probes are unreliable;
the real test is just connecting a client).

## iptables — nothing to do, deliberately

Local `INPUT` policy on this VPS is `ACCEPT` with no restrictive rules, so no
local firewall change is needed. Filtering happens at the OCI security list.

`network_mode: host` means the container binds UDP 443 directly and adds **no**
NAT or filter rules. It does not interfere with Tailscale or the Plex DNAT — and
that isolation is the whole reason for this design. Verify after any change:

```bash
sudo iptables -t nat -S | grep 32400     # Plex DNAT must still be present
sudo iptables -S | grep -c ts-           # Tailscale chains must still be present
tailscale status
```

---

## Client setup

Any of these work: **Hiddify** (free, App Store, iOS/iPadOS/macOS),
**Shadowrocket** (~$3), **Stash**, **sing-box**.

Print the import URI (run on the VPS):

```bash
cd ~/Developer/dotfiles/hysteria && echo "hysteria2://$(grep HYSTERIA_PASSWORD .env | cut -d= -f2-)@129.146.179.208:443/?insecure=1&sni=www.bing.com#Oracle-Phoenix"
```

`insecure=1` is required while using the self-signed cert. Paste into the client
as "Add from clipboard" / "Import from URL".

### Bandwidth — the one setting that actually matters

Hysteria2's brutal congestion control **transmits at the rate you declare**. It
does not probe for capacity. So the number must be right:

- too high → you manufacture packet loss and bufferbloat
- too low  → you leave throughput unused

Measured home line (Dubai, off-net Ookla servers): **~310 down / ~116 up Mbps**.
Set the client to roughly 80–90 % of that:

```
down: 280 mbps
up:   100 mbps
```

Set these on the **client**. The server config intentionally declares no
bandwidth limit, so it honours the client's hint (`ignoreClientBandwidth`
defaults to false). Re-check if the ISP plan changes.

Hysteria's default QUIC receive windows (~20 MB connection) already cover a
256 ms path — 20 MB ÷ 0.256 s ≈ 625 Mbps — so no QUIC tuning is needed.

---

## Certificates

### Current: self-signed

Fine here. The goal is throughput, not evading DPI, and the client pins nothing.
Cost: the client needs `insecure=1`, and a TLS-fingerprinting observer can tell
the cert is not real. Expires **2036-08-03**.

### Optional upgrade: ACME (needs a real domain)

Only worth it if you want the endpoint to genuinely pass as a website. Point an
A record at `129.146.179.208`, then replace the `tls:` block in
`config.yaml.template` with:

```yaml
acme:
  domains:
    - vpn.example.com
  email: you@example.com
  # http-01 needs TCP/80 open in OCI *and* free on the host
```

Then re-run `./render.sh`, add a **TCP/80** OCI ingress rule, restart, and drop
`insecure=1` from the client URI. Certs persist in Hysteria's ACME dir — add a
volume for it so they survive container recreation.

---

## Operations

```bash
cd ~/Developer/dotfiles/hysteria
docker compose -f hysteria-docker-compose.yml up -d      # start / apply changes
docker compose -f hysteria-docker-compose.yml down       # stop
docker compose -f hysteria-docker-compose.yml pull && \
  docker compose -f hysteria-docker-compose.yml up -d    # update
docker logs -f hysteria                                  # logs
ss -lnup | grep :443                                     # confirm listener
```

Password rotation: edit `.env` → `./render.sh` → `up -d` → re-import the client URI.

### Self-test without leaving the box

Confirms cert, auth and egress in one shot:

```bash
PW=$(grep HYSTERIA_PASSWORD ~/Developer/dotfiles/hysteria/.env | cut -d= -f2-)
printf 'server: 127.0.0.1:443\nauth: %s\ntls:\n  sni: www.bing.com\n  insecure: true\nsocks5:\n  listen: 127.0.0.1:11080\n' "$PW" > /tmp/hy-c.yaml
docker run --rm -d --name hy-test --network host -v /tmp/hy-c.yaml:/c.yaml:ro tobyxdd/hysteria:latest client -c /c.yaml
curl -s --socks5-hostname 127.0.0.1:11080 https://ifconfig.me   # expect 129.146.179.208
docker rm -f hy-test && rm /tmp/hy-c.yaml
```

A **wrong** password returns `HTTP status code: 404` — that is correct. The
masquerade serves the proxied site to unauthenticated probes instead of an
auth error, so the port does not advertise itself as a proxy.

---

## Gotchas

- **[RESOLVED 2026-08-07]** ~~IPv6 on this VPS is half-open — ICMPv6 passes, TCP does not.~~ Fixed by adding an OCI Security List **egress rule: Destination `::/0`, All Protocols**. Kept below because the diagnostic path is reusable.
- **IPv6 on this VPS was half-open — ICMPv6 passed, TCP did not.** Symptom: the
  log fills with `TCP error ... dial tcp6 [...]: i/o timeout` and every
  dual-stack site stalls behind a Happy-Eyeballs fallback. Diagnosis (verified
  2026-08-06):

  | layer | result |
  |---|---|
  | global v6 address on `enp0s6` | present (`2603:c020:24:f3ff::/64`, SLAAC) |
  | `::/0` default route via RA | present |
  | ping6 link-local gateway | **works**, 0.2 ms |
  | ping6 `2606:4700:4700::1111` | **works**, 10 ms |
  | TCP connect to any v6 host :443 | **times out** |
  | `ip6tables` | `INPUT/FORWARD/OUTPUT ACCEPT`, nothing blocking |

  Routing and address assignment are fine; the host firewall is open. Packets
  are being dropped in the **OCI Security List**, which permits ICMPv6 but has
  no rule covering IPv6 TCP. OCI security lists are *stateful*, so a single
  **egress rule (Destination `::/0`, All Protocols)** allows return traffic and
  fixes it. The Default Security List's blanket egress rule is `0.0.0.0/0` —
  **IPv4 only** — which is why this is easy to miss after enabling IPv6.

  Note that fixing this **does not improve throughput** — v6 and v4 take the
  same paths with the same congestion control. It removes connection *stalls*,
  nothing more. The 10-second alternative that fixes the same symptom is
  client-side: Hiddify → Settings → Config Options → **IPv6 Mode →
  `ipv4_only`**. A server-side `direct` outbound with `mode: 4` does **not**
  work here, because TUN-mode clients hand the proxy *literal* v6 addresses —
  there is no hostname left to re-resolve.
- **DNS must be resolved at the VPS, not inherited from the host.** The single
  highest-impact setting in this config. `/etc/resolv.conf` on the VPS points at
  Tailscale MagicDNS (`100.100.100.100`), whose resolver is `${HOST_TS_IP}` —
  **AdGuard Home on the homelab, in Dubai**. Without an explicit `resolver:`
  block, Hysteria inherits that, and three things go wrong at once:

  1. every lookup makes a **~256 ms round trip to Dubai** before the connection
     even starts;
  2. ad/tracker domains come back as `0.0.0.0` / `::` from AdGuard, so Hysteria
     dials `0.0.0.0:443` and logs `connection refused` — **benign, but it was
     168 of 251 errors in a 10-minute window**;
  3. CDNs and geo-checks resolve from **Dubai**, handing back UAE/EU edge nodes
     while you egress from Phoenix — quietly defeating the point of a US VPS.

  The `resolver:` block in `config.yaml.template` pins lookups to `1.1.1.1`
  (anycast, hits a US PoP from Phoenix). Result: 251 errors/10 min → **0**.
  Tradeoff: ads are no longer blocked through the tunnel. To keep blocking,
  point `resolver.udp.addr` at AdGuard's *public* anycast resolver
  (`94.140.14.14:53`) instead — latency stays fixed, but the benign
  `connection refused` lines come back.
- **UDP-hostile networks.** Some hotel/corporate/captive networks block UDP or
  throttle QUIC. There is no TCP fallback configured. If you hit this often, add
  a VLESS/Trojan TCP inbound alongside — different tool (sing-box/Xray), same box.
- **Streaming is a separate problem.** `129.146.0.0/16` is Oracle Cloud
  (AS31898), a hosting ASN. Netflix/Hulu/Max block datacenter ranges, and no
  protocol choice changes that. Throughput and geo-unblocking are independent —
  if playback is blocked, Smart DNS is the different tool for that job.
- **Do not point this at the tailnet.** Egress uses the VPS default route. Both
  paths to Phoenix can coexist; A/B them freely.
- **Samba was removed from this VPS** (2026-08-06). `/etc/samba/smb.conf` is
  still a symlink to `~/Developer/dotfiles/samba/smb.conf`, which shares
  `/data`, `/mnt/hdd` and `~/Developer`. None of those paths exist here, but
  `smbd` was listening on `0.0.0.0:445`. If a dotfiles bootstrap ever reinstalls
  `samba` on a VPS, those shares come back facing the internet. Guard the
  install step so it only runs on the homelab.
- **`rpcbind` is still listening on `0.0.0.0:111`.** Pulled in by `nfs-common`;
  there are zero NFS mounts on this box. Remove with
  `sudo apt-get purge -y nfs-common rpcbind` if NFS is never needed here.
