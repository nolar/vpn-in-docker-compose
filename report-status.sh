#!/usr/bin/env bash
# Generate the status report as ANSI and HTML and text files.
#
# The ANSI form is also shown on stdout. The HTML form is stored on a volume,
# and is server by a separately running web server (in another container).
#
set -euo pipefail
shopt -s nocasematch
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin

# IPStack is used to detect the country name from an IP address.
# Open https://ipstack.com/ and sign-up for a free plan: 10'000 requests/month.
# The script caches the results for 5-10 mins, making ~8640-4320 reqs/month.
: ${IPSTACK_API_KEY:?"Sign-up for IPStack.com's free plan and get an API key."}

# For how long (seconds) to cache the resolved country of the IP addresses.
# The information itself changes rarely, but it can be resolved with mistakes.
# 5-10 mins are good enough to match IPStack's free plan even if running 24/7.
: ${COUNTRY_CACHE_TIME:=600}

# Which IP to ping/traceroute for checking the connection.
# Just google for "pingable ip".
: ${STATUS_IP:="139.130.4.5"}

# The DNS resolver that is un-blocked in the firewall.
: ${NS:="8.8.4.4"}

# Where the status files are stored before showing. Note: they are cached.
: ${STATUS_DIR:="/tmp"}
temp_file="${STATUS_DIR}/index.temp"
ansi_file="${STATUS_DIR}/index.ansi"
html_file="${STATUS_DIR}/index.html"
text_file="${STATUS_DIR}/index.txt"

# ANSI code: can be either color/mode names, or purpose names (e.g. "title").
# Multiple codes can be combined, e.g. `echo hello | ansi red blink invert`.
declare -A ANSI=(
  [brightwhite]='0;97'
  [midgray]='0;37'
  [gray]='1;30'
  [red]='0;31'
  [green]='0;32'
  [yellow]='0;33'
  [bold]='1'
  [blink]='5'
  [invert]='7'
)

# Wrap every line of the input into ANSI code. Unlike the whole-block wrapping,
# per-line wrapping is needed to fit into docker-compose, which adds its own
# colorful prefixes for each container, and they break the block's ANSI codes.
# For example: both the container name and the country name are ANSI-coded,
# but the country name is multiline here, each line must be ANSI-coded the same:
#     status_1       | ┌─────────────────────┐
#     status_1       | │┏━╸┏━╸┏━┓┏┳┓┏━┓┏┓╻╻ ╻│
#     status_1       | │┃╺┓┣╸ ┣┳┛┃┃┃┣━┫┃┗┫┗┳┛│
#     status_1       | │┗━┛┗━╸╹┗╸╹ ╹╹ ╹╹ ╹ ╹ │
#     status_1       | └─────────────────────┘
function ansi() {
  local esc=$(printf '\033')
  local codes=""
  for code_or_name in "$@"; do
    codes="${codes};${ANSI[$code_or_name]:-$code_or_name}"
  done
  sed -e "s/^/${esc}[${codes}m/g" -e "s/\$/${esc}[0m/g"
}

# Stylise the text on the input with big letters and maybe a border.
function show() {
  toilet --width 100 -f future --filter crop "$@"
}

# A unified date-time format.
function now() {
  date +'%Y-%m-%d %H:%M:%S'
}

# Generate the ANSI output and write it to a file.
started=$(now)
{
  echo "started $started // updated $(now)" | ansi midgray
  echo

  # TODO: can we also prevent the OpenDNS resolver from being blocked by the firewall?
  # Detect the IP address of the traffic, i.e. how the internet sees us.
  # myip=$( dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | sed 's/"//g' )
  resolver=$(dig +short resolver1.opendns.com @"${NS}" +time=1 +tries=1 | sed -e 's/;;.*//')
  resolver=${resolver:-resolver1.opendns.com}
  myip=$(dig +short myip.opendns.com "@${resolver}" +time=1 +tries=1 | sed -e 's/;;.*//')
  if [[ -z "$myip" ]]; then
    echo "Current IP address cannot be detected:" | ansi gray
    echo "?.?.?.?" | show | ansi yellow
  else
    echo "Current IP address (for information):" | ansi gray
    echo "${myip}" | show | ansi brightwhite
  fi

  # Detect the country of our current IP address, i.e. the VPN's outgoing gate.
  # Cache it to reduce the load on the APIs, and to fit into their limits.
  country_cache="/tmp/country-of-${myip}.txt"
  if [[ -e "${country_cache}" && $(find "${country_cache}" -mmin "+${COUNTRY_CACHE_TIME}") ]]; then
    country=$(cat "${country_cache}")
  else
    country=$(curl -s https://ipvigilante.com/ --connect-timeout 1 | jq -r .data.country_name)
    if [[ -z "${country}" ]]; then
      country=$(curl -s "http://api.ipstack.com/${myip}?access_key=${IPSTACK_API_KEY}" --connect-timeout 1 | jq -r .country_name)
    fi
    if [[ -n "${country}" || "$country" != null ]]; then
      mkdir -p $(dirname "$country_cache")
      echo "${country}" >"$country_cache"
    fi
  fi
  if [[ -z "$country" || "$country" == null ]]; then
    echo "Country cannot be detected:" | ansi gray
    echo "-=-=-=-" | show --filter border | ansi yellow
  elif [[ "$country" == Germany ]]; then
    echo "Country must NOT be Germany" | ansi red
    echo "${country}" | show --filter border | ansi red blink invert
  else
    echo "Country is as expected:" | ansi gray
    echo "${country}" | show --filter border | ansi green
  fi

  # Detect the next-hop IP address with the default routing: is it VPN or a local network?
  # 10.*.*.* is a VPN (AirVPN). Everything else is considered to be a local network.
  nexthop=$(traceroute -n -m1 -q1 "${STATUS_IP}" 2>/dev/null | tail -n+2 | awk '{print $2}' || true)
  if [[ -z "${nexthop}" ]]; then
    echo "Next-hop IP address is absent (blocked):" | ansi gray
    echo "-*-*-*-" | show | ansi yellow
  elif [[ "${nexthop}" != "10."* ]]; then
    echo "Next-hop IP address must be 10.*.*.*:" | ansi red
    echo "${nexthop}" | show | ansi red
  else
    echo "Next-hop IP address is as expected:" | ansi gray
    echo "${nexthop}" | show | ansi green
  fi

  # Print some additional information about the networking setup.
  # It is better to alwats see it directly rather than interpreted.
  echo
  echo "Available interfaces:" | ansi bold
  ip -oneline -color a show | awk '{print $2 "\t" $3 "\t" $4}'

  echo
  echo "Next hops per interface (only tun* should be permitted):" | ansi bold
  ip -o a | awk '{print $2}' | sort -u | grep -v '^lo' | xargs -n1 -I {} bash -c 'echo -en "{}\t"; traceroute -n -m1 -q3 -i {} "'"${STATUS_IP}"'" 2>&1 | tail -n+2 || true'

  echo
} >"$temp_file" 2>&1 || true
mv -f "${temp_file}" "${ansi_file}"  # atomic switch

# Generate the HTML file, to be served separately.
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<style>body {zoom: 150%;}</style>'
  echo '<meta http-equiv="refresh" content="1" />'
  ansi2html <"${ansi_file}"
} >"${temp_file}" 2>&1 || true
mv -f "${temp_file}" "${html_file}"  # atomic switch

# Generate the text file, just in case.
{
  ansi2txt <"${ansi_file}"
} >"${temp_file}" 2>&1 || true
mv -f "${temp_file}" "${text_file}"  # atomic switch
