# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VPN-in-Docker: a Docker Compose setup that routes container traffic through a WireGuard VPN tunnel, secured by iptables firewall rules that block all non-VPN traffic. Uses AirVPN as the default provider but supports any WireGuard-compatible VPN.

## Commands

```bash
docker compose build        # Build custom containers
docker compose up           # Start all services
docker compose down --volumes --remove-orphans  # Full cleanup
```

No tests, linters, or CI exist. The project is entirely shell scripts and Docker configuration.

## Architecture

Most containers share a single network namespace via `network_mode: service:network` — this ensures iptables rules apply uniformly. Exceptions: **rulemaker** uses the default bridge network (so its DNS resolution isn't blocked by the firewall it generates), and **webview** has its own network (no need to be firewalled).

### Container Roles

- **network** — Sleeps forever; exists solely as a shared network namespace. All ports are exposed here (not on individual containers).
- **rulemaker** — Resolves VPN server IPs via DNS, generates iptables rules, writes dump files to `cache/iptables/`.
- **firewall** — Polls for iptables dump files and atomically applies them via `iptables-restore` in the shared network namespace.
- **wireguard** — LinuxServer.io WireGuard image; creates `wg*` interfaces in the shared namespace.
- **status** — Periodically checks connectivity (IP detection, traceroute, country lookup via ipstack.com API) and writes ANSI/HTML/text reports.
- **webview** — Nginx serving the HTML status page.
- **transmission** — Sample app. Uses `wait-for-safety.sh` entrypoint to block startup until firewall DROP policies are active.

### Key Scripts

- `generate-firewall.sh` — Builds iptables rules: DROP-all default, allow loopback/VPN interfaces/local IPs/DNS/VPN server IPs. Runs in rulemaker container, dumps rules via `iptables-save`.
- `apply-firewall.sh` — Watches for updated dump files, applies them atomically with `iptables-restore`. Runs in firewall container.
- `update-airvpn-ips.sh` — Resolves AirVPN server hostnames (via `dig`) across multiple scopes (earth, europe, specific countries). Writes IP lists to `cache/servers/`.
- `wait-for-safety.sh` — Entrypoint wrapper that polls `iptables -L` until INPUT/OUTPUT policies are DROP before executing the wrapped command.
- `report-status.sh` — Detects current IP, country (via ipstack.com), next-hop routing, and per-interface connectivity. Outputs colorized ANSI via `toilet`.
- `transmission.sh` — Launches `transmission-daemon` with config flags.

### Data Flow

1. `update-airvpn-ips.sh` resolves VPN IPs → writes to `cache/servers/`
2. `generate-firewall.sh` reads VPN IPs + config → generates iptables rules → dumps to `cache/iptables/`
3. `apply-firewall.sh` detects new dump files → applies atomically via `iptables-restore`
4. `wait-for-safety.sh` detects DROP policy → starts wrapped application

### Network Layout

- VPN network subnet: `172.30.172.0/24` (IPv4), `fdaa:bbbb:cccc:dddd::/64` (IPv6)
- DNS: `8.8.4.4` / `8.8.8.8`
- Status check IPs: `139.130.4.5` (v4), `2620:fe::fe` (v6)
- Firewall strategy: DROP by default, with explicit ACCEPT for VPN interfaces (`wg+`, `tun+`), local subnets, DNS, and VPN server IPs. Uses DROP (not REJECT) for blocked traffic so apps retry rather than close connections during VPN reconnects.

### Configuration

- `wireguard/wg0.conf` — WireGuard config (not committed)
- `ipstack.env` — IPStack API key for country detection (not committed; see `ipstack.env.example`)
- Subnets and allowed IPs are configured via environment variables in `docker-compose.yaml`
