#!/bin/bash

# Specter OS transparent Tor routing script
# Redirects all TCP traffic through Tor's TransPort
# and DNS traffic through Tor's DNSPort

TOR_UID=$(id -u debian-tor)
TRANS_PORT="9040"
DNS_PORT="5353"

# Clear existing rules
iptables -F
iptables -t nat -F

# Allow Tor's own traffic to go out directly, avoiding a routing loop
iptables -t nat -A OUTPUT -m owner --uid-owner $TOR_UID -j RETURN

# Allow local loopback traffic
iptables -t nat -A OUTPUT -o lo -j RETURN

# Redirect DNS requests to Tor's DNSPort
iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT

# Redirect all outgoing TCP connections to Tor's TransPort
iptables -t nat -A OUTPUT -p tcp --syn -j REDIRECT --to-ports $TRANS_PORT

# Drop all other outgoing UDP to block leaks (except what was already redirected above)
iptables -A OUTPUT -p udp -j DROP

echo "Tor transparent routing rules applied."
