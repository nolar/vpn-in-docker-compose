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

# For how long (minutes) to cache the resolved country of the IP addresses.
# The information itself changes rarely, but it can be resolved with mistakes.
# For scale: 1d ≈ 1.5k mins, 1mo = 44k.
: ${COUNTRY_CACHE_TIME:=50000}

# Which IP to ping/traceroute for checking the connection.
# Just google for "pingable ip".
: ${STATUS_IPv4:="139.130.4.5"}
: ${STATUS_IPv6:="2001:4860:4860::8888"}

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

# Detect the IP address of the traffic, i.e. how the internet sees us.
function get_my_ip() {
  # myip=$( dig $flags TXT +short o-o.myaddr.l.google.com @ns1.google.com | sed 's/"//g' )
  resolver=""  #$(dig $flags +short resolver1.opendns.com. @"${NS}" +time=1 +tries=1 | sed -e 's/;;.*//')
  resolver=${resolver:-resolver1.opendns.com.}
  myip=$(dig "$@" ANY +short myip.opendns.com. "@${resolver}" +time=1 +tries=1 | sed -e 's/;;.*//')
  echo "$myip"
}

# Detect the next-hop IP address with the default routing: is it VPN or a local network?
# 10.*.*.* is a VPN (AirVPN). Everything else is considered to be a local network.
function get_next_hop() {
  local flags="$1"  # -4 or -6
  local status_ip="$2"
  traceroute $flags -n -m1 -q1 "${status_ip}" 2>/dev/null | tail -n+2 | awk '{print $2}' || true
}

# Detect the country of our current IP address, i.e. the VPN's outgoing gate.
# Cache it to reduce the load on the APIs, and to fit into their limits.
function get_ip_country() {
  local ip="$1"
  local cache="/cache/countries/${ip}.txt"

  if [[ -z "${ip}" ]]; then
    echo ""
  elif [[ -e "${cache}" && $(find "${cache}" -mmin "-${COUNTRY_CACHE_TIME}") ]]; then
    cat "${cache}"
  else
    country=$(curl -s "https://api.ipstack.com/${ip}?access_key=${IPSTACK_API_KEY}" --connect-timeout 10 | jq -r .country_name)
    if [[ -n "${country}" || "$country" != null ]]; then
      mkdir -p $(dirname "$cache")
      echo "${country}" >"$cache"
    fi
    echo "${country}"
  fi
}

function report_myip() {
  if [[ -z "$2" ]]; then
    echo "Current $1 address cannot be detected:" | ansi gray
    echo "----" | show | ansi yellow
  else
    echo "Current $1 address (for information):" | ansi gray
    echo "$2" | show | ansi brightwhite
  fi
}

function report_country() {
  if [[ -z "$2" || "$2" == null ]]; then
    echo "$1 country cannot be detected:" | ansi gray
    echo "-=-=-=-" | show --filter border | ansi yellow
  elif [[ "$2" == Germany ]]; then
    echo "$1 country must NOT be Germany" | ansi red
    echo "$2" | show --filter border | ansi red blink invert
  else
    echo "$1 country is as expected:" | ansi gray
    echo "$2" | show --filter border | ansi green
  fi
}

function report_nexthop() {
  if [[ -z "$2" ]]; then
    echo "Next-hop $1 address is absent (blocked):" | ansi gray
    echo "-*-*-*-" | show | ansi yellow
  elif [[ "$2" != "$3"* ]]; then
    echo "Next-hop $1 address must start with $3" | ansi red
    echo "$2" | show | ansi red
  else
    echo "Next-hop $1 address is as expected:" | ansi gray
    echo "$2" | show | ansi green
  fi
}

# Generate the ANSI output and write it to a file.
started=$(now)
{
  echo "started $started // updated $(now)" | ansi midgray
  echo

  myip4=$(get_my_ip -4)
  myip6=$(get_my_ip -6)
  report_myip IPv4 "${myip4}"
  report_myip IPv6 "${myip6}"

  country4=$(get_ip_country "${myip4}")
  country6=$(get_ip_country "${myip6}")
  report_country IPv4 "${country4}"
  report_country IPv6 "${country6}"

  nexthop4=$(get_next_hop -4 "${STATUS_IPv4}")
  nexthop6=$(get_next_hop -6 "${STATUS_IPv6}")
  report_nexthop IPv4 "${nexthop4}" "10."
  report_nexthop IPv6 "${nexthop6}" "fd7d:76ee:"

  # Print some additional information about the networking setup.
  # It is better to always see it directly rather than interpreted.
  echo
  echo "Available interfaces:" | ansi bold
  ip -oneline -color a show | awk '{print $2 "\t" $3 "\t" $4}'

  # Show next hops per interface, expecting "Operation not permitted" or alike.
  # We already have this for the main route, but also check for every interface
  # to make sure these interfaces are firewalled as needed -- for extra safety.
  echo
  echo "Next v4 hops per interface (only tun*/wg* should be permitted):" | ansi bold
  ip -o a | awk '{print $2}' | sort -u | grep -v '^lo' | xargs -I {} bash -c 'echo -en "{}\t"; traceroute -4 -n -m1 -q3 -i {} "'"${STATUS_IPv4}"'" 2>&1 | tail -n+2 || true'
  echo
  echo "Next v6 hops per interface (only tun*/wg* should be permitted):" | ansi bold
  ip -o a | awk '{print $2}' | sort -u | grep -v '^lo' | xargs -I {} bash -c 'echo -en "{}\t"; traceroute -6 -n -m1 -q3 -i {} "'"${STATUS_IPv6}"'" 2>&1 | tail -n+2 || true'

  echo
} >"$temp_file" || true
mv -f "${temp_file}" "${ansi_file}"  # atomic switch

# Generate the HTML file, to be served separately.
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<style>body {zoom: 150%;}</style>'
  echo '<meta http-equiv="refresh" content="1" />'
  ansi2html <"${ansi_file}"
} >"${temp_file}" || true
mv -f "${temp_file}" "${html_file}"  # atomic switch

# Generate the text file, just in case.
{
  ansi2txt <"${ansi_file}"
} >"${temp_file}" || true
mv -f "${temp_file}" "${text_file}"  # atomic switch
