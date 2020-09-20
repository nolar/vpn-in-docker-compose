FROM ubuntu:20.04
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get update -y -qq \
 && apt-get install -y \
        curl jq toilet colorized-logs rsync \
        dnsutils iputils-ping traceroute iproute2 iptables tcpdump \
        openvpn \
        transmission-daemon \
 && apt-get autoremove -y \
 && apt-get clean -y \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/*
