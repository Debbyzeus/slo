#!/bin/bash
# ==============================================================================
# Title:        SlowDNS (DNSTT) Fully Executable Automated Deployment Script
# Description:  Automates Go installation, DNSTT compilation, key generation,
#               systemd background service, and iptables port forwarding.
# Target OS:    Ubuntu / Debian (Root access required)
# ==============================================================================

set -e

# Colors for terminal styling
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 1. Check for Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[-] Error: This script must be run as root (use sudo).${NC}"
  exit 1
fi

echo -e "${CYAN}[+] Starting SlowDNS Server Deployment...${NC}"

# 2. Prompt for Nameserver Subdomain
read -p "[?] Enter your Nameserver subdomain (e.g., t.yourdomain.com): " NS_DOMAIN
if [ -z "$NS_DOMAIN" ]; then
  echo -e "${RED}[-] Nameserver domain cannot be empty.${NC}"
  exit 1
fi

# 3. System Dependencies Update
echo -e "${CYAN}[+] Updating package lists and installing dependencies...${NC}"
apt-get update -y && apt-get install -y wget git iptables net-tools

# 4. Install Go (Latest Stable)
echo -e "${CYAN}[+] Installing Go programming language...${NC}"
GO_VERSION="1.21.1"
wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
rm -f go${GO_VERSION}.linux-amd64.tar.gz

export PATH=$PATH:/usr/local/go/bin
if ! grep -q "/usr/local/go/bin" /etc/profile; then
  echo 'export PATH=$PATH:/usr/local/go/bin' | tee -a /etc/profile
fi

# 5. Clone and Compile DNSTT Server
echo -e "${CYAN}[+] Cloning and compiling DNSTT server...${NC}"
mkdir -p /opt/slowdns
cd /opt/slowdns

if [ ! -d "dnstt" ]; then
  git clone https://www.bamsoftware.com/git/dnstt.git
fi

cd dnstt/dnstt-server
go build -o dnstt-server

# 6. Generate Cryptographic Keys
echo -e "${CYAN}[+] Generating cryptographic security keys...${NC}"
./dnstt-server -gen-key -privkey-file /opt/slowdns/server.key -pubkey-file /opt/slowdns/server.pub

# 7. Create Systemd Service for Persistence
echo -e "${CYAN}[+] Creating background systemd service...${NC}"
cat << EOF > /etc/systemd/system/slowdns.service
[Unit]
Description=SlowDNS Tunnel Server (DNSTT)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/slowdns/dnstt/dnstt-server
ExecStart=/opt/slowdns/dnstt/dnstt-server/dnstt-server -udp :5300 -privkey-file /opt/slowdns/server.key $NS_DOMAIN 127.0.0.1:22
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slowdns
systemctl restart slowdns

# 8. Configure Firewall and NAT Port Forwarding (Port 53 -> 5300)
echo -e "${CYAN}[+] Configuring network packet redirection...${NC}"
PRIMARY_INTERFACE=$(ip route show default | awk '/default/ {print $5}')

if [ -z "$PRIMARY_INTERFACE" ]; then
  PRIMARY_INTERFACE="eth0"
  echo -e "${RED}[!] Default interface lookup failed. Falling back to 'eth0'.${NC}"
fi

iptables -I INPUT -p udp --dport 53 -j ACCEPT
iptables -I INPUT -p udp --dport 5300 -j ACCEPT
iptables -t nat -I PREROUTING -i "$PRIMARY_INTERFACE" -p udp --dport 53 -j REDIRECT --to-ports 5300

# Save rules persistently if netfilter-persistent is available
if dpkg -l | grep -q iptables-persistent; then
  netfilter-persistent save
fi

# 9. Output Results
echo -e "\n=================================================================="
echo -e "${GREEN}[✔] SlowDNS Server Deployed and Running Successfully!${NC}"
echo -e "=================================================================="
echo -e "Nameserver Domain : ${CYAN}$NS_DOMAIN${NC}"
echo -e "Service Status    : ${CYAN}$(systemctl is-active slowdns)${NC}"
echo -e ""
echo -e "COPY THIS PUBLIC KEY FOR YOUR CLIENT CONFIGURATION:"
echo -e "------------------------------------------------------------------"
cat /opt/slowdns/server.pub
echo -e "------------------------------------------------------------------"
echo -e "=================================================================="
