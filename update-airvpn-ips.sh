#!/usr/bin/env bash
# (Re-)generate the list of IP addresses of the VPN provider itself.
#
# The VPN provider must be explicitly allowed in the firewall rules,
# so that the tunnelling traffic goes unblocked.
#
# For this, the provider's APIs (including DNS-as-an-API) are queried,
# processed, and a single flat list of IP addresses is generated.
#
# The list is refreshed and re-applied to the firewall every few minutes.
#
# If the script loses the connection to the internet (i.e. it self-blocks),
# it uses the latest known lists. If no lists were retrieved, then the traffic
# is blocked without exceptions, and the system needs manual intervention.
#
# For the AirVPN-specific logic, see:
#
# * https://airvpn.org/faq/api/
# * https://airvpn.org/topic/14378-how-can-i-get-vpn-servers-entry-ip-addresses/
#
set -euo pipefail

# The primary DNS resolver to use. Assume that the local resolvers are blocked,
# so this one should be explicitly listed in the firewall exceptions.
# Any DNS can resolve both IPv4 (A) & IPv6 (AAAA), but we separate them anyway.
: ${NS_V4:="8.8.4.4"}
: ${NS_V6:="2001:4860:4860::8844"}

# Where the cache of the VPN provider's IP addresses should be stored.
# The main file is "all.txt". Other files can exist, one per requested scope.
: ${ALLOWED_IPS_DIR:="$(dirname $0)/cache/servers"}
: ${ALLOWED_IPS_FILE_V4:="${ALLOWED_IPS_DIR}/all.v4.txt"}
: ${ALLOWED_IPS_FILE_V6:="${ALLOWED_IPS_DIR}/all.v6.txt"}

# Which server scopes to resolve into the IP addresses. AirVPN has scopes
# for the whole world ("earth"), continents, countries, and specific servers
# (all of them have more than one IP address, including individual servers).
: ${SCOPES:="earth europe america asia nl de cz us"}

# Command-line arguments always override the env variables as the most specific.
if [[ $# -gt 0 ]]; then
  SCOPES="$*"
fi

# Always add AirVPN API's endpoints to the list of allowed IPs.
# Otherwise, we will not be able to talk to their API (if we need).
SCOPES="airvpn.org ${SCOPES}"

total_main_file_v4="${ALLOWED_IPS_FILE_V4}"
total_temp_file_v4="${ALLOWED_IPS_FILE_V4}.digged.tmp"
total_sort_file_v4="${ALLOWED_IPS_FILE_V4}.sorted.tmp"
total_main_file_v6="${ALLOWED_IPS_FILE_V6}"
total_temp_file_v6="${ALLOWED_IPS_FILE_V6}.digged.tmp"
total_sort_file_v6="${ALLOWED_IPS_FILE_V6}.sorted.tmp"

mkdir -p "${ALLOWED_IPS_DIR}"
echo -n >"${total_temp_file_v4}"
echo -n >"${total_temp_file_v6}"
for scope in $SCOPES; do

  scope_main_file_v4="${ALLOWED_IPS_DIR}/${scope}.v4.txt"
  scope_temp_file_v4="${ALLOWED_IPS_DIR}/${scope}.v4.txt.digged.tmp"
  scope_sort_file_v4="${ALLOWED_IPS_DIR}/${scope}.v4.txt.sorted.tmp"
  scope_main_file_v6="${ALLOWED_IPS_DIR}/${scope}.v6.txt"
  scope_temp_file_v6="${ALLOWED_IPS_DIR}/${scope}.v6.txt.digged.tmp"
  scope_sort_file_v6="${ALLOWED_IPS_DIR}/${scope}.v6.txt.sorted.tmp"

  # Scopes with dots are taken literally (e.g. "servername.airservers.org").
  # Other scopes are tried against several known endpoints (DNS conventions).
  if [[ "$scope" =~ '.' ]]; then
    hosts=("$scope")
  else
    hosts=(
      "${scope}.airservers.org"
      "${scope}.all.vpn.airdns.org"
      "${scope}2.all.vpn.airdns.org"
    )
  fi

  # Resolve each possible host for this scope.
  # Time-cap to avoid hangups: it either works fast, or it doesn't work at all.
  echo -n >"${scope_temp_file_v4}"
  echo -n >"${scope_temp_file_v6}"
  for host in "${hosts[@]}"; do
    if dig A @"${NS_V4}" "${host}" +short +tcp +time=1 +tries=3 | grep -v '^;' >>"${scope_temp_file_v4}"; then
      echo "Resolved ${scope} via ${host} (v4)"
    fi
    if dig AAAA @"${NS_V6}" "${host}" +short +tcp +time=1 +tries=3 | grep -v '^;' >>"${scope_temp_file_v6}"; then
      echo "Resolved ${scope} via ${host} (v6)"
    fi
  done

  # Deduplicate.
  sort --unique "${scope_temp_file_v4}" >"${scope_sort_file_v4}"
  sort --unique "${scope_temp_file_v6}" >"${scope_sort_file_v6}"

  # Atomically put over the resulting file for this scope.
  if [[ -s "${scope_sort_file_v4}" ]]; then
    mv -f "${scope_sort_file_v4}" "${scope_main_file_v4}"
  else
    echo "FAILED to resolve ${scope} to any IPv4 addresses. Leaving the file as is."
  fi
  if [[ -s "${scope_sort_file_v6}" ]]; then
    mv -f "${scope_sort_file_v6}" "${scope_main_file_v6}"
  else
    echo "FAILED to resolve ${scope} to any IPv6 addresses. Leaving the file as is."
  fi

  # Append the scope's IP addresses to the cumulative list of IP addresses
  # NB: even if resolving has failed, but there was previous data in this scope.
  if [[ -f "${scope_main_file_v4}" ]]; then
    cat "${scope_main_file_v4}" >>"${total_temp_file_v4}"
  fi
  if [[ -f "${scope_main_file_v6}" ]]; then
    cat "${scope_main_file_v6}" >>"${total_temp_file_v6}"
  fi

  # And cleanup.
  rm -f "${scope_temp_file_v4}" "${scope_sort_file_v4}"
  rm -f "${scope_temp_file_v6}" "${scope_sort_file_v6}"
done

# Deduplicate.
sort --unique "${total_temp_file_v4}" >"${total_sort_file_v4}"
sort --unique "${total_temp_file_v6}" >"${total_sort_file_v6}"

# Atomically put over the resulting file for the whole scan.
if [[ -s "${total_sort_file_v4}" ]]; then
  mv -f "${total_sort_file_v4}" "${total_main_file_v4}"
else
  echo "FAILED to resolve to any IPv4 addresses. Leaving the file as is."
fi
if [[ -s "${total_sort_file_v6}" ]]; then
  mv -f "${total_sort_file_v6}" "${total_main_file_v6}"
else
  echo "FAILED to resolve to any IPv6 addresses. Leaving the file as is."
fi

# And cleanup.
rm -f "${total_temp_file_v4}" "${total_sort_file_v4}"
rm -f "${total_temp_file_v6}" "${total_sort_file_v6}"
