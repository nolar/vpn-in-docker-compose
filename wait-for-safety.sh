#!/usr/bin/env bash
# Wait until the network is secured, and start a program.
#
# The "secured network" is detected by a firewall rules
# that block all traffic by default. If the network becomes
# unsecured later, the wrapped program is not stopped.
#
# The script is intended to be used as an entrypoint or
# a wrapper script for the containers running in parallel
# to the VPN and firewall containers: since they all start
# at the same time, the applications should not be started
# before the network is secured.
#
# Usage (as a wrapper):
#   ADD wait-for-safety.sh /
#   CMD /wait-for-safety.sh some-app
#
# Usage (as an entry point):
#   ADD wait-for-safety.sh /
#   ENTRYPOINT ["/wait-for-safety.sh"]
#   CMD some-app
#
#set -x  # for debugging
set -euo pipefail

while ! iptables -n -L | egrep "Chain INPUT \(policy DROP\)" >/dev/null; do
  echo "Waiting for the firewall..."
  sleep 1
done

while ! iptables -n -L | egrep "Chain OUTPUT \(policy DROP\)" >/dev/null; do
  echo "Waiting for the firewall..."
  sleep 1
done

echo "The firewall's block-rule is found, the firewall is ready."
exec "$@"
