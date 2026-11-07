#!/bin/bash

# Prevent interactive prompts during installation
export DEBIAN_FRONTEND=noninteractive

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script as root (sudo ./openvpn-install.sh)."
  exit 1
fi

echo "[+] Updating system packages..."
apt update && apt upgrade -y
apt install openvpn easy-rsa iptables curl -y

# Setup Easy-RSA Directory
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa || exit

# Initialize PKI and Build CA
echo "[+] Building Certificate Authority (CA)..."
./easyrsa init-pki
./easyrsa --batch build-ca nopass
./easyrsa --batch gen-dh

# Generate Server Certificate and Key
echo "[+] Generating server certificate and key..."
./easyrsa --batch gen-req server nopass
./easyrsa --batch sign-req server server

# Generate HMAC Signature (TLS-Auth/TLS-Crypt)
openvpn --genkey secret ta.key

# Copy files to OpenVPN configuration directory
cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem ta.key /etc/openvpn/

# Configure Server Settings
echo "[+] Creating server configuration file..."
cat << 'EOF' > /etc/openvpn/server.conf
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt ta.key
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
verb 3
explicit-exit-notify 1
EOF

# Enable IP Forwarding
echo "[+] Enabling kernel IP forwarding..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

# Configure Firewall (UFW / Iptables)
DEFAULT_INTERFACE=$(ip route show default | awk '/default/ {print $5}')
echo "[+] Configuring NAT and firewall rules for interface: $DEFAULT_INTERFACE"

iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$DEFAULT_INTERFACE" -j MASQUERADE
iptables-save > /etc/iptables.up.rules

# Create a rule to restore iptables on boot
cat << EOF > /etc/systemd/system/iptables-restore.service
[Unit]
Description=Restore iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables.up.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-restore.service

# Start and enable OpenVPN service
systemctl enable openvpn@server
systemctl start openvpn@server

echo "[+] OpenVPN installation completed successfully!"
echo "[+] Server is running on UDP port 1194."
