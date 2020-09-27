#!/usr/bin/env bash
# A sample application to be executed in the secured/firewalled network.
#
# Use `exec` as the last statement to make it the main process,
# so that it gets the termination signals properly (not via bash).
#
set -euo pipefail
exec transmission-daemon \
  --foreground \
  --config-dir /var/lib/transmission \
  --allowed=127.0.0.1,${LOCAL_IPS:-192.168.*.*,10.*.*.*} \
  --rpc-bind-address 0.0.0.0 \
  --encryption-preferred \
  --peerlimit-global 10000 \
  --peerlimit-torrent 1000 \
  --global-seedratio 0 \
  --download-dir /mnt/files \
  --no-incomplete-dir \
  --no-lpd \
  --no-portmap \
  ${PEER_PORT:+ --peerport ${PEER_PORT}}
