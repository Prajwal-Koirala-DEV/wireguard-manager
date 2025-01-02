#!/bin/bash

# WireGuard and nftables Configuration Script
# This script configures nftables rules to work with a WireGuard VPN server.
# It ensures that the necessary packages are installed, IP forwarding is enabled,
# and secure nftables rules are created for NAT, DNS, and firewall filtering.

# Function to check if your script is running in a GitHub Actions environment
function is-running-inside-github-action() {
    # Check if the script is running inside a GitHub Actions environment
    if [ -z "$GITHUB_REPOSITORY" ]; then
        # If the GITHUB_REPOSITORY variable is not set, it is not a GitHub Actions environment
        echo "GitHub Actions environment not detected."
        echo "This script is meant to be run in a GitHub Actions workflow."
        exit 1 # Exit with error since this script is meant for GitHub Actions
    else
        # If GITHUB_REPOSITORY is set, confirm the environment and display the repository name
        echo "GitHub Actions environment detected."
        echo "GitHub Repo: ${GITHUB_REPOSITORY}"
    fi
}

# Check if the script is running inside a GitHub Actions environment
# is-running-inside-github-action

# Ensure `sudo` is installed on the system
if [ ! -x "$(command -v sudo)" ]; then
    echo "Installing 'sudo'..."
    sudo apt-get update          # Update the system's package list to get the latest metadata
    sudo apt-get install -y sudo # Install sudo if not already present
fi

# Ensure `nftables` is installed
if [ ! -x "$(command -v nft)" ]; then
    echo "Installing 'nftables'..."
    sudo apt-get update              # Update the system's package list
    sudo apt-get install -y nftables # Install nftables if not already present
fi

# Ensure `coreutils` is installed (provides `cat` command)
if [ ! -x "$(command -v cat)" ]; then
    echo "Installing 'coreutils'..."
    sudo apt-get update               # Update the system's package list
    sudo apt-get install -y coreutils # Install coreutils if not already present
fi

# Check and enable IPv4 forwarding if not already enabled
if [ "$(sudo cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
    echo "IPv4 forwarding is disabled. Enabling now..."
    sudo sysctl -w net.ipv4.ip_forward=1 # Enable IPv4 forwarding at runtime
fi

# Check and enable IPv6 forwarding if not already enabled
if [ "$(sudo cat /proc/sys/net/ipv6/conf/all/forwarding)" != "1" ]; then
    echo "IPv6 forwarding is disabled. Enabling now..."
    sudo sysctl -w net.ipv6.conf.all.forwarding=1 # Enable IPv6 forwarding at runtime
fi

# Flush existing nftables rules to avoid conflicts
if [ "$(sudo nft list ruleset 2>/dev/null | wc -l)" -ge 2 ]; then
    echo "Flushing existing nftables rules..."
    sudo nft flush ruleset # Clear all existing rules in nftables
fi

# Define variables for interfaces, subnets, and ports
WIREGUARD_INTERFACE="wg0"                                                                        # WireGuard interface name, identifying the VPN interface for traffic routing
WIREGUARD_TABLE_NAME="${WIREGUARD_INTERFACE}-table"                                              # Name of the nftables table where all WireGuard-related rules are stored
NETWORK_INTERFACE="$(ip route | grep default | head --lines=1 | cut --delimiter=" " --fields=5)" # Get the default network interface (e.g., eth0) for internet-bound traffic masquerading
WIREGUARD_VPN_PORT="51820"                                                                       # UDP port used for WireGuard VPN communication (default WireGuard port)
WIREGUARD_DNS_PORT="53"                                                                          # Port used for DNS traffic (UDP and TCP) from VPN clients
WIREGUARD_IPv4_SUBNET="10.0.0.0/8"                                                               # IPv4 subnet assigned to VPN clients for NAT and routing
WIREGUARD_IPv6_SUBNET="fd00::/8"                                                                 # IPv6 subnet assigned to VPN clients for NAT and routing
WIREGUARD_HOST_IPV4="10.0.0.1"                                                                   # IPv4 address of the WireGuard server (private IP for VPN clients)
WIREGUARD_HOST_IPV6="fd00::1"                                                                    # IPv6 address of the WireGuard server (private IP for VPN clients)

# --- Create nftables table for WireGuard VPN server ---
sudo nft add table inet "${WIREGUARD_TABLE_NAME}" # Create a new nftables table named after the WireGuard interface for managing VPN traffic rules

# --- PREROUTING CHAIN (NAT rules before routing) ---
sudo nft add chain inet "${WIREGUARD_TABLE_NAME}" PREROUTING "{ type nat hook prerouting priority dstnat ; policy accept ; }" # PREROUTING chain processes incoming packets before routing, typically for destination NAT (e.g., forwarding requests)

# --- INPUT CHAIN (Filtering input traffic) ---
sudo nft add chain inet "${WIREGUARD_TABLE_NAME}" INPUT "{ type filter hook input priority filter ; policy accept ; }"                                                                                         # INPUT chain processes packets addressed to the server, policy is initially set to accept
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" INPUT ct state invalid log prefix "INVALID INPUT" drop                                                                                                        # Log and drop invalid packets
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" INPUT iifname "${NETWORK_INTERFACE}" udp dport ${WIREGUARD_VPN_PORT} log prefix "ACCEPT INPUT UDP" accept                                                     # Log and accept WireGuard UDP packets
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" INPUT iifname "${NETWORK_INTERFACE}" ip6 nexthdr udp udp dport ${WIREGUARD_VPN_PORT} log prefix "ACCEPT INPUT IPv6 UDP" accept                                # Log and accept WireGuard IPv6 UDP packets
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" INPUT ip saddr "${WIREGUARD_IPv4_SUBNET}" udp dport "${WIREGUARD_DNS_PORT}" ip daddr "${WIREGUARD_HOST_IPV4}" log prefix "ACCEPT INPUT IPv4 DNS UDP" accept   # Log and accept IPv4 DNS queries (UDP)
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" INPUT ip6 saddr "${WIREGUARD_IPv6_SUBNET}" udp dport "${WIREGUARD_DNS_PORT}" ip6 daddr "${WIREGUARD_HOST_IPV6}" log prefix "ACCEPT INPUT IPv6 DNS UDP" accept # Log and accept IPv6 DNS queries (UDP)
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" INPUT ip saddr "${WIREGUARD_IPv4_SUBNET}" tcp dport "${WIREGUARD_DNS_PORT}" ip daddr "${WIREGUARD_HOST_IPV4}" log prefix "ACCEPT INPUT IPv4 DNS TCP" accept   # Log and accept IPv4 DNS queries (TCP)
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" INPUT ip6 saddr "${WIREGUARD_IPv6_SUBNET}" tcp dport "${WIREGUARD_DNS_PORT}" ip6 daddr "${WIREGUARD_HOST_IPV6}" log prefix "ACCEPT INPUT IPv6 DNS TCP" accept # Log and accept IPv6 DNS queries (TCP)

# --- FORWARD CHAIN (Filtering forwarded traffic) ---
sudo nft add chain inet "${WIREGUARD_TABLE_NAME}" FORWARD "{ type filter hook forward priority filter ; policy accept ; }"                                                                                  # FORWARD chain processes packets routed through the server, policy set to accept initially
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" FORWARD ct state invalid log prefix "INVALID FORWARD" drop                                                                                                 # Log and drop invalid forwarded packets
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" FORWARD ct state related,established log prefix "ACCEPT FORWARD ESTABLISHED" accept                                                                        # Log and accept related/established forwarded packets
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" FORWARD ip saddr "${WIREGUARD_IPv4_SUBNET}" udp dport "${WIREGUARD_DNS_PORT}" ip daddr "${WIREGUARD_HOST_IPV4}" log prefix "FORWARD IPv4 DNS UDP" accept   # Log and forward IPv4 DNS queries (UDP) from VPN clients
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" FORWARD ip6 saddr "${WIREGUARD_IPv6_SUBNET}" udp dport "${WIREGUARD_DNS_PORT}" ip6 daddr "${WIREGUARD_HOST_IPV6}" log prefix "FORWARD IPv6 DNS UDP" accept # Log and forward IPv6 DNS queries (UDP) from VPN clients
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" FORWARD ip saddr "${WIREGUARD_IPv4_SUBNET}" tcp dport "${WIREGUARD_DNS_PORT}" ip daddr "${WIREGUARD_HOST_IPV4}" log prefix "FORWARD IPv4 DNS TCP" accept   # Log and forward IPv4 DNS queries (TCP) from VPN clients
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" FORWARD ip6 saddr "${WIREGUARD_IPv6_SUBNET}" tcp dport "${WIREGUARD_DNS_PORT}" ip6 daddr "${WIREGUARD_HOST_IPV6}" log prefix "FORWARD IPv6 DNS TCP" accept # Log and forward IPv6 DNS queries (TCP) from VPN clients

# --- OUTPUT CHAIN (Filtering output traffic) ---
sudo nft add chain inet "${WIREGUARD_TABLE_NAME}" OUTPUT "{ type filter hook output priority filter ; policy accept ; }"                                                      # OUTPUT chain processes packets generated by the server, policy set to accept initially
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" OUTPUT ct state invalid log prefix "INVALID OUTPUT" drop                                                                     # Log and drop invalid outgoing packets
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" OUTPUT ct state related,established log prefix "ACCEPT OUTPUT ESTABLISHED" accept                                            # Log and accept related/established outgoing packets
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" OUTPUT ip daddr "${WIREGUARD_IPv4_SUBNET}" udp sport "${WIREGUARD_DNS_PORT}" log prefix "ACCEPT OUTPUT IPv4 DNS UDP" accept  # Log and allow server-generated IPv4 DNS queries (UDP) to clients
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" OUTPUT ip6 daddr "${WIREGUARD_IPv6_SUBNET}" udp sport "${WIREGUARD_DNS_PORT}" log prefix "ACCEPT OUTPUT IPv6 DNS UDP" accept # Log and allow server-generated IPv6 DNS queries (UDP) to clients
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" OUTPUT ip daddr "${WIREGUARD_IPv4_SUBNET}" tcp sport "${WIREGUARD_DNS_PORT}" log prefix "ACCEPT OUTPUT IPv4 DNS TCP" accept  # Log and allow server-generated IPv4 DNS queries (TCP) to clients
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" OUTPUT ip6 daddr "${WIREGUARD_IPv6_SUBNET}" tcp sport "${WIREGUARD_DNS_PORT}" log prefix "ACCEPT OUTPUT IPv6 DNS TCP" accept # Log and allow server-generated IPv6 DNS queries (TCP) to clients
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" OUTPUT ip daddr "${WIREGUARD_HOST_IPV4}" udp sport "${WIREGUARD_DNS_PORT}" log prefix "ACCEPT OUTPUT DNS to IPv4" accept     # Log and allow outgoing DNS queries (UDP) to WireGuard server IPv4 address
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" OUTPUT ip6 daddr "${WIREGUARD_HOST_IPV6}" udp sport "${WIREGUARD_DNS_PORT}" log prefix "ACCEPT OUTPUT DNS to IPv6" accept    # Log and allow outgoing DNS queries (UDP) to WireGuard server IPv6 address

# --- POSTROUTING CHAIN (NAT rules after routing) ---
sudo nft add chain inet "${WIREGUARD_TABLE_NAME}" POSTROUTING "{ type nat hook postrouting priority srcnat ; policy accept ; }"                                                # POSTROUTING chain processes packets after routing, typically for source NAT (masquerading)
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" POSTROUTING ip saddr "${WIREGUARD_IPv4_SUBNET}" oifname "${NETWORK_INTERFACE}" log prefix "MASQ POSTROUTING IPv4" masquerade  # Log and apply NAT (masquerading) for IPv4 packets from VPN clients
sudo nft add rule inet "${WIREGUARD_TABLE_NAME}" POSTROUTING ip6 saddr "${WIREGUARD_IPv6_SUBNET}" oifname "${NETWORK_INTERFACE}" log prefix "MASQ POSTROUTING IPv6" masquerade # Log and apply NAT (masquerading) for IPv6 packets from VPN clients

# View the nftables ruleset to verify the configuration
sudo nft list ruleset

# View the nftables ruleset to verify the configuration
sudo nft list ruleset

# View all the blocked logs.
# journalctl -f
