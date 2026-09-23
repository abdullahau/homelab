#!/usr/bin/env bash
# Capture every packet the LG TV sends and receives.
# The host becomes the TV's gateway, so the switch stops hiding the traffic.
#
#   sudo ./tv-capture.sh setup   add the rules, then capture separately
#   sudo ./tv-capture.sh start   add the rules and capture here
#   sudo ./tv-capture.sh stop    remove the rules
set -euo pipefail

TV=192.168.0.196
MAC=b0:37:95:aa:c6:72
HOST=192.168.0.100
LAN=enxc8a362d8c536
OUT=${OUT:-/docker/webos/capture}

[[ $EUID -eq 0 ]] || { echo "Run this with sudo."; exit 1; }

setup() {
  mkdir -p "$OUT"
  chown "${SUDO_USER:-root}" "$OUT"

  # Drop any rules from an earlier run, so setup can repeat safely.
  clear_rules

  # Without this the host tells the TV to talk to the router directly.
  sysctl -qw "net.ipv4.conf.$LAN.send_redirects=0"
  sysctl -qw net.ipv4.conf.all.send_redirects=0
  sysctl -qw net.ipv4.ip_forward=1

  # Docker sets the FORWARD policy to DROP, so allow the TV explicitly.
  iptables -I FORWARD 1 -s "$TV" -j ACCEPT
  iptables -I FORWARD 1 -d "$TV" -j ACCEPT

  # NAT the TV behind the host, so replies come back through the host.
  iptables -t nat -I POSTROUTING 1 -s "$TV" -o "$LAN" -j MASQUERADE

  # Apps hardcode their own resolver: the Netflix client uses 8.8.8.8 and
  # skips AdGuard. Send every port 53 packet to AdGuard instead.
  # This only works while the TV routes through this host.
  # It covers IPv4 UDP and TCP. DNS over HTTPS on port 443 still passes,
  # and so does anything the TV sends over IPv6.
  iptables -t nat -I PREROUTING 1 -s "$TV" -p udp --dport 53 -j DNAT --to "$HOST:53"
  iptables -t nat -I PREROUTING 1 -s "$TV" -p tcp --dport 53 -j DNAT --to "$HOST:53"

  # Let the normal user run tcpdump, so the capture needs no further sudo.
  # sudo resets PATH, so look in Homebrew's prefix before the system one.
  # setcap refuses a symlink, and Homebrew's bin entry is one, so resolve it.
  local td
  td=$(PATH="/home/linuxbrew/.linuxbrew/bin:$PATH" command -v tcpdump) \
    || { echo "tcpdump not found. Run: brew install tcpdump"; exit 1; }
  td=$(readlink -f "$td")
  setcap cap_net_raw,cap_net_admin=eip "$td"
  echo "Gave $td raw-socket capability."

  echo "The host is ready. Now set the TV to a manual IP:"
  echo "  IP $TV / mask 255.255.255.0 / gateway 192.168.0.100 / DNS 192.168.0.100"
}

start() {
  setup
  echo
  echo "Writing to $OUT. Press Ctrl-C to stop."
  # Filter on the MAC, not the IP. "host $TV" compiles to an IPv4-only
  # match and records no IPv6 at all. This LAN runs both.
  tcpdump -i "$LAN" -n -s0 -U \
          -w "$OUT/tv-%Y%m%d-%H%M%S.pcap" -G 3600 -W 24 \
          "ether host $MAC"
}

clear_rules() {
  for proto in udp tcp; do
    while iptables -t nat -C PREROUTING -s "$TV" -p "$proto" --dport 53 \
                   -j DNAT --to "$HOST:53" 2>/dev/null; do
      iptables -t nat -D PREROUTING -s "$TV" -p "$proto" --dport 53 \
               -j DNAT --to "$HOST:53"
    done
  done
  while iptables -t nat -C POSTROUTING -s "$TV" -o "$LAN" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s "$TV" -o "$LAN" -j MASQUERADE
  done
  while iptables -C FORWARD -s "$TV" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -s "$TV" -j ACCEPT
  done
  while iptables -C FORWARD -d "$TV" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -d "$TV" -j ACCEPT
  done
}

stop() {
  clear_rules
  # setup zeroes both of these, so restore both.
  sysctl -qw "net.ipv4.conf.$LAN.send_redirects=1"
  sysctl -qw net.ipv4.conf.all.send_redirects=1
  echo "The rules are removed. Set the TV back to automatic IP."
}

case "${1:-}" in
  setup) setup ;;
  start) start ;;
  stop)  stop ;;
  *)     echo "Usage: sudo $0 {setup|start|stop}"; exit 1 ;;
esac
