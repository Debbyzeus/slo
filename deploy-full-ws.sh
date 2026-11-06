#!/bin/bash
# ==============================================================================
# Title:        Complete Secure WebSocket SSH (WSS) + Nginx Automated Deployment
# Description:  Installs Python WebSocket bridge, configures local port, installs
#               Nginx, and automatically creates the reverse proxy block for WSS.
# Target OS:    Ubuntu / Debian (Root access required)
# ==============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[-] Error: This script must be run as root (use sudo).${NC}"
  exit 1
fi

echo -e "${CYAN}[+] Starting Secure WebSocket SSH Deployment...${NC}"

# 1. Prompt for Domain and Ports
read -p "[?] Enter your domain name (e.g., yourdomain.com): " DOMAIN_NAME
if [ -z "$DOMAIN_NAME" ]; then
  echo -e "${RED}[-] Domain name cannot be empty.${NC}"
  exit 1
fi

WS_LOCAL_PORT="8080"

# 2. Update and install dependencies
echo -e "${CYAN}[+] Installing system dependencies (Python, Nginx, Certbot)...${NC}"
apt-get update -y
apt-get install -y python3 python3-pip python3-websockets nginx certbot python3-certbot-nginx git

# 3. Create Python WebSocket bridge script
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

    async def receive_from_ws():
        try:
            async data_stream in websocket:
                pass
        except Exception:
            pass

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

# 4. Create Systemd Service for Python Script
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

# 5. Configure Nginx Reverse Proxy
echo -e "${CYAN}[+] Configuring Nginx Reverse Proxy for $DOMAIN_NAME...${NC}"
cat << EOF > /etc/nginx/sites-available/ssh-ws
server {
    listen 80;
    server_name $DOMAIN_NAME;

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

# 6. Request SSL Certificate using Certbot
echo -e "${CYAN}[+] Requesting SSL Certificate via Certbot (Ensure domain DNS points to this server)...${NC}"
certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos -m admin@$DOMAIN_NAME --redirect || {
  echo -e "${RED}[!] Certbot SSL generation failed. Ensure your DNS points directly to this VPS (DNS-only mode) before running SSL setup.${NC}"
}

echo -e "\n=================================================================="
echo -e "${GREEN}[✔] Setup Complete Successfully!${NC}"
echo -e "=================================================================="
echo -e "Domain Name   : ${CYAN}https://$DOMAIN_NAME or wss://$DOMAIN_NAME${NC}"
echo -e "Python WS     : ${CYAN}$(systemctl is-active ssh-ws)${NC}"
echo -e "Nginx Proxy   : ${CYAN}$(systemctl is-active nginx)${NC}"
echo -e ""
echo -e "Remember to enable Cloudflare Orange Cloud (Proxied) if desired,"
echo -e "and set SSL/TLS mode to 'Full' in your Cloudflare dashboard."
echo -e "=================================================================="
