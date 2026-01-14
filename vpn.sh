#!/usr/bin/env bash
set -euo pipefail

# tested on Ubuntu 24.04.3 LTS

# Config
VPN_USER="user"
VPN_PASS="STRONG_PASSWORD"
POOL_CIDR="10.10.10.0/24"
DNS_SERVERS="1.1.1.1,8.8.8.8"
CA_DN="CN=VPN Root CA"
SERVER_DN="CN=server"

# Packages (Ubuntu 24.04)
sudo apt-get update
sudo apt-get -y install --no-install-recommends software-properties-common
sudo add-apt-repository -y universe
sudo apt-get update
sudo apt-get -y install --no-install-recommends \
  strongswan strongswan-pki strongswan-starter \
  nftables curl ca-certificates

install_if_available() {
  local pkg="$1"
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    sudo apt-get -y install --no-install-recommends "$pkg"
  fi
}

# Optional plugin packages (vary by Ubuntu release)
for pkg in \
  libcharon-extra-plugins \
  libcharon-extauth-plugins \
  libstrongswan-extra-plugins \
  libtss2-tcti-tabrmd0 \
  strongswan-plugin-eap-mschapv2; do
  install_if_available "$pkg"
done

# Enable service (ipsec.conf + strongswan-starter)
sudo systemctl enable --now strongswan-starter

# Routing / sysctl
sudo tee /etc/sysctl.d/99-ipsec-vpn.conf >/dev/null <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sudo sysctl --system

# Detect WAN interface + public IP
WAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
PUBLIC_IP="$(curl -4 -fsS https://ifconfig.me)"
echo "WAN_IF=$WAN_IF"
echo "PUBLIC_IP=$PUBLIC_IP"

# strongSwan cert dirs
sudo mkdir -p /etc/ipsec.d/{cacerts,certs,private}
sudo chmod 700 /etc/ipsec.d/private

# Basic config (keep default plugin includes)
sudo tee /etc/strongswan.conf >/dev/null <<'EOF'
charon {
    load_modular = yes
    plugins {
        include strongswan.d/charon/*.conf
        eap-mschapv2 {
            load = yes
        }
    }
}
include strongswan.d/*.conf
EOF

# Generate certificates (use `ipsec pki`)
# CA key
sudo ipsec pki --gen --type rsa --size 4096 --outform pem \
  | sudo tee /etc/ipsec.d/private/ca-key.pem >/dev/null

# CA cert
sudo ipsec pki --self --ca --lifetime 3650 \
  --in /etc/ipsec.d/private/ca-key.pem --type rsa \
  --dn "$CA_DN" --outform pem \
  | sudo tee /etc/ipsec.d/cacerts/ca-cert.pem >/dev/null

# Server key
sudo ipsec pki --gen --type rsa --size 4096 --outform pem \
  | sudo tee /etc/ipsec.d/private/server-key.pem >/dev/null

# Server cert (SAN MUST contain public IP)
sudo ipsec pki --pub --in /etc/ipsec.d/private/server-key.pem --type rsa \
  | sudo ipsec pki --issue \
      --lifetime 1825 \
      --cacert /etc/ipsec.d/cacerts/ca-cert.pem \
      --cakey  /etc/ipsec.d/private/ca-key.pem \
      --dn "$SERVER_DN" \
      --san "$PUBLIC_IP" \
      --flag serverAuth \
      --flag ikeIntermediate \
      --outform pem \
  | sudo tee /etc/ipsec.d/certs/server-cert.pem >/dev/null

# ipsec.conf (strongswan-starter)
# IMPORTANT:
# - leftid must be the public IP WITHOUT "vpn-"
# - eap_identity=%identity (not %any) for macOS username/password profile
sudo tee /etc/ipsec.conf >/dev/null <<EOF
config setup
    uniqueids=no

conn ikev2-vpn
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes

    left=%any
    leftid=${PUBLIC_IP}
    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0

    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=${POOL_CIDR}
    rightdns=${DNS_SERVERS}
    eap_identity=%identity

    ike=aes256-sha256-prfsha256-modp2048!
    esp=aes256gcm16!
EOF

# Credentials
sudo tee /etc/ipsec.secrets >/dev/null <<EOF
: RSA server-key.pem
${VPN_USER} : EAP "${VPN_PASS}"
EOF
sudo chmod 600 /etc/ipsec.secrets

# Firewall/NAT (nftables)
sudo tee /etc/nftables.conf >/dev/null <<EOF
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iif "lo" accept
    ct state established,related accept

    # SSH
    tcp dport 22 accept

    # IKEv2
    udp dport 500 accept
    udp dport 4500 accept

    # optional ICMP
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;

    ct state established,related accept

    # allow VPN clients to forward traffic
    ip saddr ${POOL_CIDR} accept
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority srcnat;
    policy accept;

    oifname "${WAN_IF}" ip saddr ${POOL_CIDR} masquerade
  }
}
EOF

sudo systemctl enable --now nftables
sudo nft -f /etc/nftables.conf

# Restart strongSwan and verify
sudo systemctl restart strongswan-starter
sudo ipsec rereadall

sudo ipsec statusall

# Optional: show CA cert details (for manual trust import)
echo
echo "=== CA certificate details ==="
sudo openssl x509 -in /etc/ipsec.d/cacerts/ca-cert.pem -noout -subject -issuer -fingerprint -sha256
echo
echo "CA path: /etc/ipsec.d/cacerts/ca-cert.pem"
echo "Server cert path: /etc/ipsec.d/certs/server-cert.pem"
echo "Server key path: /etc/ipsec.d/private/server-key.pem"
echo
echo "Logs: sudo journalctl -u strongswan-starter -f"
