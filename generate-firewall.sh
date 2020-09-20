#!/usr/bin/env bash
# Generate & apply the firewall rules to block all the traffic except VPN.
#
# A few necessary exceptions from blocking:
#
# * Loopback interfaces and IP addresses.
# * Local network traffic (home WiFi or Docker's bridged network).
# * DNS resolvers to resolve the VPN's hostnames to IP addresses.
# * VPN-tunnelled traffic itself.
#
# IPv6 is blocked: I do not understand it, so I cannot configure it.
#
# Two modes of usage are supported (not intentionally, but as a side effect):
#
# * Recommended: In a standalone networking context (`network_mode: bridge`),
#   the script generates the iptables (v4 & v6) files, which are later used
#   to atomically apply the firewall rules in the actual VPN-secured context.
#   The local container's firewall is modified, but it affects nothing.
#
# * In the VPN-secured networking context (`network_mode: service:network`),
#   the script modifies the firewall of all secured containers in-place.
#   Not recommended: This will affect other applications and the VPN client,
#   which will be losing connectivity while the firewall is only partially
#   configured after the flush and before the rules are added (it takes time).
#
# BEWARE: INPUT/OUTPUT is not the destination of the traffic itself,
# but the firewall's internal tables for before/after routing.
#
set -euo pipefail

# For obvious reasons, only root can run the script.
# Do not flood with errors if executed as a non-root user.
if [ "$(id -u)" != "0" ]; then
  echo >&2 "FATAL ERROR: This script must be executed as root (sudo)!"
  exit 1
fi

# Fatality mode.
error_handler() {
  echo >&2 "---=== Firewall has failed! ===---"
  exit 1
}
trap "error_handler" ERR INT TERM

# Get the IPs resolved for the VPN servers, as many as possible (if set).
# If neither of these vars is set, ignore. If set, but unreadable, then fail.
# The cache is populated by `update-airvpn-ips.sh` before the firewall script.
if [[ "${ALLOWED_IPS_FILE:-}" || "${ALLOWED_IPS_DIR:-}" ]]; then
  ALLOWED_IPS=$(cat "${ALLOWED_IPS_FILE:-${ALLOWED_IPS_DIR}/all.txt}")
else
  ALLOWED_IPS=""
fi

# One special IP or a range (but only one) that is used for monitoring/alerting.
# Its traffic, even when blocked, is not logged as suspicious.
: ${STATUS_IP:=""}

# Specially allowed IPs needed for the setup to function.
: ${SPECIAL_IPS:=""}

# Which IPs to treat as a local network. By default, all private networks are
# considered safe. It is better to narrow this list with more specific ranges.
: ${LOCAL_IPS:="192.168.0.0/16 172.16.0.0/12 10.0.0.0/8"}

# If there is a DNS resolver, allow its traffic too.
: ${NS:="8.8.4.4 8.8.8.8"}

# OpenVPN interfaces where the traffic is fully allowed.
: ${VPN_INTERFACES:="tun+"}

# Where to put the resulting dump files.
: ${IPTABLES_FILE_V4:="/tmp/iptables.txt"}
: ${IPTABLES_FILE_V6:="/tmp/ip6tables.txt"}

echo "Generating the firewall rules..."

# Block anything by default, even if there is no single rule.
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP
ip6tables -P INPUT DROP
ip6tables -P OUTPUT DROP
ip6tables -P FORWARD DROP

# Start from scratch each time.
iptables -F
iptables -X
iptables -t mangle -F
iptables -t mangle -X
ip6tables -F
ip6tables -X
ip6tables -t mangle -F
ip6tables -t mangle -X

# To be safer with Docker, allow its internal DNS traffic with bridged networks.
# The normal -F/-X would block us forever, as Docker's DNS will be blocked.
# 127.0.0.11 is an internal DNS resolver of bridged Docker networks.
#iptables -t nat -F INPUT
#iptables -t nat -F OUTPUT
#iptables -t nat -F PREROUTING
#iptables -t nat -F POSTROUTING
#iptables -t nat -A OUTPUT -d 127.0.0.11/32 -j DOCKER_OUTPUT
#iptables -t nat -A POSTROUTING -d 127.0.0.11/32 -j DOCKER_POSTROUTING
#ip6tables -t nat -F INPUT
#ip6tables -t nat -F OUTPUT
#ip6tables -t nat -F PREROUTING
#ip6tables -t nat -F POSTROUTING

# Malicious packets. Learned them from multiple places.
iptables -A INPUT -m state --state INVALID -j LOG --log-prefix "Blocked invalid: "
iptables -A INPUT -m state --state INVALID -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL ACK,RST,SYN,FIN -j LOG --log-prefix "Blocked syn-a: "
iptables -A INPUT -p tcp --tcp-flags ALL ACK,RST,SYN,FIN -j DROP
iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j LOG --log-prefix "Blocked syn-b: "
iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j LOG --log-prefix "Blocked syn-c: "
iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
iptables -A INPUT -f -j LOG --log-prefix "Blocked fragmented: "
iptables -A INPUT -f -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j LOG --log-prefix "Blocked xmas: "
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j LOG --log-prefix "Blocked null: "
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP

# System or intra-host traffic.
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# VPN-tunnelled traffic.
for tun in $VPN_INTERFACES; do
  iptables -A INPUT -i "$tun" -j ACCEPT
  iptables -A OUTPUT -o "$tun" -j ACCEPT
  ip6tables -A INPUT -i "$tun" -j ACCEPT
  ip6tables -A OUTPUT -o "$tun" -j ACCEPT
done

# Non-VPN traffic that is coming to us in response to our outgoing traffic.
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

# Local broadcasting from us or to us. TODO: Is it needed? For what?
iptables -A INPUT -d 255.255.255.255 -j ACCEPT
iptables -A OUTPUT -d 255.255.255.255 -j ACCEPT

# Friendly traffic with the local and/or Docker bridged networks.
# Note A: to our own ips in those networks (i.e. eth0), but initiated by others.
# Note B: to other ips in those networks, but initiated by us.
for ip in $LOCAL_IPS; do
  iptables -A INPUT -d "$ip" -j ACCEPT  # see note A
  iptables -A OUTPUT -d "$ip" -j ACCEPT # see note B
done

# Special-purpose addresses, DNS resolvers, VPN servers (initial connections).
for ip in ${NS} ${SPECIAL_IPS} ${ALLOWED_IPS}; do
  iptables -A OUTPUT -d "$ip" -j ACCEPT
done

# Catch all unwanted traffic. Ignore the IPs that we use for status checking
# (pinging/tracerouting), which generate the unwanted traffic by design.
iptables -A INPUT -j LOG --log-prefix "Blocked IPv4 input: " ${STATUS_IP:+ ! -d "${STATUS_IP}"}
iptables -A OUTPUT -j LOG --log-prefix "Blocked IPv4 output: " ${STATUS_IP:+ ! -d "${STATUS_IP}"}
iptables -A FORWARD -j LOG --log-prefix "Blocked IPv4 forward: "
ip6tables -A INPUT -j LOG --log-prefix "Blocked IPv6 input: "
ip6tables -A OUTPUT -j LOG --log-prefix "Blocked IPv6 output: "
ip6tables -A FORWARD -j LOG --log-prefix "Blocked IPv6 forward: "

# Block all other traffic.
#   DROP-vs-REJECT? When OpenVPN is down temporarily or is reconnecting,
#   REJECT notifies all applications and they close their connections.
#   With DROP, the apps treat the packets as lost on the way, and thus retry.
iptables -A INPUT -j DROP
iptables -A OUTPUT -j DROP
iptables -A FORWARD -j REJECT --reject-with icmp-admin-prohibited
ip6tables -A INPUT -j DROP
ip6tables -A OUTPUT -j REJECT
ip6tables -A FORWARD -j REJECT

echo "The firewall is configured."

# Dump the filewall. It is atomically restored in the real networking container.
# For this to work, it should atomically appear: hence, a temp file and `mv`.
temp_file_v4="${IPTABLES_FILE_V4}.tmp"
temp_file_v6="${IPTABLES_FILE_V6}.tmp"
iptables-save -t filter >"${temp_file_v4}"
iptables-save -t mangle >>"${temp_file_v4}"
ip6tables-save -t filter >"${temp_file_v6}"
ip6tables-save -t mangle >>"${temp_file_v6}"
mv "${temp_file_v4}" "${IPTABLES_FILE_V4}"
mv "${temp_file_v6}" "${IPTABLES_FILE_V6}"
echo "The firewall is saved (v4 & v6)."
