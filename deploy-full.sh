#!/bin/bash
# ==============================================================================
# Title:        Unified SlowDNS + Secure WebSocket SSH Deployment Script
# Description:  Automates installation of Go, DNSTT server, Python WebSocket bridge,
#               Nginx SSL reverse proxy, and systemd services.
# Target OS:    Ubuntu / Debian (Root access required)
# ==============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 1. Root Check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[-] Error: This script must be run as root (use sudo).${NC}"
  exit 1
fi

echo -e "${CYAN}[+] Starting Unified Server Deployment...${NC}"

# 2. User Input
read -p "[?] Enter your domain / Nameserver subdomain (e.g., t.yourdomain.com): " NS_DOMAIN
if [ -z "$NS_DOMAIN" ]; then
  echo -e "${RED}[-] Domain/Nameserver cannot be empty.${NC}"
  exit 1
fi

WS_LOCAL_PORT="8080"
DNSTT_PORT="5300"

# 3. System Dependencies Update
echo -e "${CYAN}[+] Updating package lists and installing dependencies...${NC}"
apt-get update -y
apt-get install -y wget git iptables net-tools python3 python3-pip python3-websockets nginx certbot python3-certbot-nginx

# ==============================================================================
# PART 1: SlowDNS (DNSTT) Server Setup
# ==============================================================================
echo -e "${CYAN}[+] Installing Go for SlowDNS...${NC}"
GO_VERSION="1.21.1"
wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
rm -f go${GO_VERSION}.linux-amd64.tar.gz

export PATH=$PATH:/usr/local/go/bin
if ! grep -q "/usr/local/go/bin" /etc/profile; then
  echo 'export PATH=$PATH:/usr/local/go/bin' | tee -a /etc/profile
fi

echo -e "${CYAN}[+] Compiling DNSTT server...${NC}"
mkdir -p /opt/slowdns
cd /opt/slowdns
if [ ! -d "dnstt" ]; then
  git clone https://www.bamsoftware.com/git/dnstt.git
fi
cd dnstt/dnstt-server
go build -o dnstt-server

echo -e "${CYAN}[+] Generating SlowDNS cryptographic security keys...${NC}"
./dnstt-server -gen-key -privkey-file /opt/slowdns/server.key -pubkey-file /opt/slowdns/server.pub

echo -e "${CYAN}[+] Creating SlowDNS systemd service...${NC}"
cat << EOF > /etc/systemd/system/slowdns.service
[Unit]
Description=SlowDNS Tunnel Server (DNSTT)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/slowdns/dnstt/dnstt-server
ExecStart=/opt/slowdns/dnstt/dnstt-server/dnstt-server -udp :$DNSTT_PORT -privkey-file /opt/slowdns/server.key $NS_DOMAIN 127.0.0.1:22
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slowdns
systemctl restart slowdns

echo -e "${CYAN}[+] Configuring iptables port redirection (Port 53 -> $DNSTT_PORT)...${NC}"
PRIMARY_INTERFACE=$(ip route show default | awk '/default/ {print $5}')
if [ -z "$PRIMARY_INTERFACE" ]; then
  PRIMARY_INTERFACE="eth0"
fi

iptables -I INPUT -p udp --dport 53 -j ACCEPT
iptables -I INPUT -p udp --dport $DNSTT_PORT -j ACCEPT
iptables -t nat -I PREROUTING -i "$PRIMARY_INTERFACE" -p udp --dport 53 -j REDIRECT --to-ports $DNSTT_PORT

# ==============================================================================
# PART 2: Secure WebSocket SSH (WSS) + Nginx Setup
# ==============================================================================
echo -e "${CYAN}[+] Creating Python WebSocket forwarder script...${NC}"
mkdir -p /opt/ssh-ws

cat << 'EOF' > /opt/ssh-ws/ws-ssh.py
#!/usr/bin/env python3
import asyncio
import websockets
import sys

async def forward(ws, reader, writer):
    try:
        while True:
            data = await reader.read(4096)
            if not data:
                break
            await ws.send(data)
    except Exception:
        pass
    finally:
        writer.close()

async def handler(websocket, path=None):
    try:
        reader, writer = await asyncio.open_connection('127.0.0.1', 22)
    except Exception as e:
        print(f"[-] Failed to connect to local SSH: {e}")
        return

    async def forward_ws_to_ssh():
        try:
            async for message in websocket:
                if isinstance(message, str):
                    message = message.encode('latin1')
                writer.write(message)
                await writer.drain()
        except Exception:
            pass
        finally:
            writer.close()

    await asyncio.gather(
        forward(websocket, reader, writer),
        forward_ws_to_ssh()
    )

async def main(port):
    print(f"[*] Starting WebSocket SSH Server on port {port}...")
    async with websockets.serve(handler, "127.0.0.1", port):
        await asyncio.Future()

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    try:
        asyncio.run(main(port))
    except KeyboardInterrupt:
        print("\n[!] Server stopped.")
EOF

chmod +x /opt/ssh-ws/ws-ssh.py

echo -e "${CYAN}[+] Setting up background systemd service for Python WS...${NC}"
cat << EOF > /etc/systemd/system/ssh-ws.service
[Unit]
Description=SSH WebSocket Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/ssh-ws/ws-ssh.py $WS_LOCAL_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ssh-ws
systemctl restart ssh-ws

echo -e "${CYAN}[+] Configuring Nginx Reverse Proxy for $NS_DOMAIN...${NC}"
cat << EOF > /etc/nginx/sites-available/ssh-ws
server {
    listen 80;
    server_name $NS_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$WS_LOCAL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

ln -sf /etc/nginx/sites-available/ssh-ws /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx

echo -e "${CYAN}[+] Requesting SSL Certificate via Certbot...${NC}"
certbot --nginx -d "$NS_DOMAIN" --non-interactive --agree-tos -m admin@$NS_DOMAIN --redirect || {
  echo -e "${RED}[!] Certbot SSL generation failed. Ensure your DNS points directly to this VPS (DNS-only mode) if generating a fresh Let's Encrypt certificate.${NC}"
}

# ==============================================================================
# Summary Output
# ==============================================================================
echo -e "\n=================================================================="
echo -e "${GREEN}[✔] Unified Deployment Completed Successfully!${NC}"
echo -e "=================================================================="
echo -e "Domain / Nameserver : ${CYAN}$NS_DOMAIN${NC}"
echo -e "SlowDNS Status      : ${CYAN}$(systemctl is-active slowdns)${NC}"
echo -e "WebSocket Status    : ${CYAN}$(systemctl is-active ssh-ws)${NC}"
echo -e "Nginx Status        : ${CYAN}$(systemctl is-active nginx)${NC}"
echo -e ""
echo -e "SLOWDNS PUBLIC KEY (For Client Configuration):"
echo -e "------------------------------------------------------------------"
cat /opt/slowdns/server.pub
echo -e "------------------------------------------------------------------"
echo -e "=================================================================="
