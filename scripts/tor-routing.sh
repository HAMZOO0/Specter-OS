#!/bin/bash
#
# Specter OS - transparent Tor routing and kill-switch
#
# Installed as /usr/local/bin/tor-routing.sh and executed by
# tor-routing.service before any network interface is brought up.
#
# Policy: fail closed.
#   * Every IPv4 packet that is not produced by the Tor daemon, not
#     loopback, and not redirected into Tor is dropped.
#   * All IPv6 traffic is dropped and IPv6 is disabled in the kernel.
#   * ICMP is dropped (it cannot be carried by Tor and reveals the real IP).
#   * TCP is redirected to Tor's TransPort, DNS (UDP/53) to Tor's DNSPort.

set -euo pipefail

TOR_UID="$(id -u debian-tor)"
TRANS_PORT="9040"
DNS_PORT="5353"
VIRT_NET="10.192.0.0/10"      # must match VirtualAddrNetworkIPv4 in torrc

# --------------------------------------------------------------------
# 1. Default-deny first, so a failure later in this script leaves the
#    machine offline rather than leaking.
# --------------------------------------------------------------------
iptables  -P INPUT   DROP
iptables  -P FORWARD DROP
iptables  -P OUTPUT  DROP
ip6tables -P INPUT   DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT  DROP

for t in filter nat mangle raw; do
    iptables  -t "$t" -F
    iptables  -t "$t" -X
    ip6tables -t "$t" -F 2>/dev/null || true
    ip6tables -t "$t" -X 2>/dev/null || true
done

# --------------------------------------------------------------------
# 2. IPv6: disable in the kernel and allow loopback only.
# --------------------------------------------------------------------
sysctl -q -w net.ipv6.conf.all.disable_ipv6=1
sysctl -q -w net.ipv6.conf.default.disable_ipv6=1
sysctl -q -w net.ipv6.conf.lo.disable_ipv6=1

ip6tables -A INPUT  -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# --------------------------------------------------------------------
# 3. NAT: transparent redirection into Tor.
# --------------------------------------------------------------------
# Tor's own connections leave untouched (avoids a routing loop).
iptables -t nat -A OUTPUT -m owner --uid-owner "$TOR_UID" -j RETURN

# DNS to Tor's DNSPort.
iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"

# .onion / automapped virtual addresses to the TransPort.
iptables -t nat -A OUTPUT -p tcp -d "$VIRT_NET" --syn -j REDIRECT --to-ports "$TRANS_PORT"

# Loopback stays local.
iptables -t nat -A OUTPUT -o lo -j RETURN
iptables -t nat -A OUTPUT -d 127.0.0.0/8 -j RETURN

# Every other new TCP connection to the TransPort.
iptables -t nat -A OUTPUT -p tcp --syn -j REDIRECT --to-ports "$TRANS_PORT"

# --------------------------------------------------------------------
# 4. Filter INPUT.
# --------------------------------------------------------------------
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# DHCP replies (needed to obtain a LAN address; never routed off-link).
iptables -A INPUT -p udp --sport 67 --dport 68 -j ACCEPT

# --------------------------------------------------------------------
# 5. Filter OUTPUT (kill-switch).
# --------------------------------------------------------------------
iptables -A OUTPUT -m conntrack --ctstate INVALID -j DROP
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Tor daemon is the only process allowed to reach the network.
iptables -A OUTPUT -m owner --uid-owner "$TOR_UID" -p tcp --syn \
         -m conntrack --ctstate NEW -j ACCEPT

# Redirected traffic arrives on loopback.
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT

# DHCP requests on the local link.
iptables -A OUTPUT -p udp --sport 68 --dport 67 -j ACCEPT

# Everything else (ICMP, non-DNS UDP, non-Tor TCP) is rejected.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Specter OS: Tor routing and kill-switch active (IPv4 via Tor, IPv6 and ICMP blocked)."
