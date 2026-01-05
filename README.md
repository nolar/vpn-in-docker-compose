# VPN-in-Docker with a network lock

This is an educational project to demonstrate how to secure a Docker network with a VPN tunnel. It should not be used for any illegal activities, obviously.

The setup is organized as a collection of containers, each doing its job:

* **Network** — a shared networking/firewalling namespace for all containers. 
* **WireGuard** — tunnels the traffic through VPN (WireGuard/AmneziaWG).
* **Firewall** — blocks the untunnelled traffic with a firewall (iptables).
* **RuleMaker** — generates the firewall rules to be applied atomically.
* **Status** — monitors the status of the setup and prints it to stdout.
* **WebView** — publishes the monitor's status via HTTP (static nginx).

Any amount of other containers can be added to run arbitrary applications:

* **Transmission** — run securely as a sample application.

All components are optional and can be disabled. Though, without some of them, the solution makes no sense and will not function (the traffic will be blocked, or the apps will never start).

The setup does not affect other containers or applications running in the same Docker.

[AirVPN](https://airvpn.org/) is used as a VPN provider, but any other WireGuard-compatible one can be used (if you have a config file for WireGuard and know their IP ranges for monitoring/alerting).


## Usage

Optional: register at and get an API key from https://ipstack.com/, put it to `ipstack.env`.

Mandatory: put your WireGuard VPN config file to `wireguard/wg0.conf` (any other `wg*` name should work, even a few of them at the same time). If there is a problem with resolv-conf not found (e.g. in Ubuntu images), comment out the `DNS=…` line.

Start the setup:

```shell script
docker compose build
docker compose up
```

Then, open:

* http://localhost:9090/
* http://localhost:9091/

Or download and install [transmission-remote-gui](https://github.com/transmission-remote-gui/transgui) and configure a connection with `localhost` as the hostname.

Download [Ubuntu via BitTorrent](https://ubuntu.com/download/alternative-downloads) (either server or desktop, any version).

Stop with Ctrl+C (docker compose will stop the containers).

To clean it up:

```shell script
docker compose down --volumes --remove-orphans
```


## IPv6 support

IPv6 over the VPN tunnel (if available) is fully supported.

IPv6 on the physical layer is supported only hypothetically — all IPv6 firewall rules mirror the same logic for IPv4. However, I was unable to make IPv6 work in OrbStack with firewall on: it always leads to "Address unreachable" in the "rulemaker" container with the default bridged network (i.e. not the special-purpose VPN network of all other containers) — thus preventing the DNS resolution of VPN servers, thus preventing adding them to the allow-lists, thus preventing the connections to the IPv6 VPN servers.

In other words, the underlying physical IPv6 is likely non-functional at all. But even if it is functional, it will be restricted the same as IPv4 — with the exception of some protocol-specific nuances like link-local and multicast addresses.

As this is an educational project, playing with IPv6 is left as an exercise for the reader.


## Monitoring

When the network is fully secured, you will see this status:

* The VPN's detected country is in green (acceptable).
* The default next-hop IP address is in green (acceptable).
* `eth*` interfaces show "Operation not permitted".
* `wg*` interfaces show some pinging and timing.

![](screenshots/protected.png)

---

When VPN is down, but the traffic is still secured:

* The VPN's detected country is absent (acceptable).
* The default next-hop IP address is absent (acceptable).
* `eth*` interfaces show "Operation not permitted".
* `wg*` interfaces are absent or blocked.

![](screenshots/disconnected.png)

To simulate:

```shell script
docker compose stop wireguard
```

To restore:

```shell script
docker compose start wireguard 
```

---

When the network is exposed, the status reporting looks like this:
 
* The VPN's detected country is in red and flashing (compromised).
* The default next-hop IP address is in red (compromised).
* `eth*` interfaces show some pinging and timing (they must not).
* `wg*` interfaces are either absent or show something.

![](screenshots/exposed.png)

To simulate:

```shell script
docker compose stop wireguard firewall transmission
docker compose exec network iptables -F
docker compose exec network iptables -P INPUT ACCEPT
docker compose exec network iptables -P OUTPUT ACCEPT
docker compose exec network ip6tables -F
docker compose exec network ip6tables -P INPUT ACCEPT
docker compose exec network ip6tables -P OUTPUT ACCEPT
```

To restore:

```shell script
docker compose start wireguard firewall transmission
```

Please note that to expose yourself, you need to do both: configure the firewall to pass the traffic **AND** shut down the VPN connection. As long as the VPN connection is alive, the traffic goes through it even if the firewall is in the permissive mode.


## Implementation details

### Shared network container

All of the containers use the shared network space of a special pseudo-container: it sleeps forever, and is only used as a shared network namespace with iptables.

**Why not Docker networks?** In that case, each container has its own iptables namespace, and so the firewall rules do not apply to all of them equally. With the shared container's network, they all run in the same networking context.
