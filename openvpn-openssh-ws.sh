#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script as root: sudo ./aio-setup.sh"
  exit 1
fi

echo "[+] Updating packages and installing dependencies..."
apt update && apt install -y openvpn easy-rsa python3 iptables curl openssl

# 1. Quick OpenVPN Setup
echo "[+] Configuring OpenVPN server..."
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa
./easyrsa init-pki
./easyrsa --batch build-ca nopass
./easyrsa --batch gen-dh
./easyrsa --batch gen-req server nopass
./easyrsa --batch sign-req server server
openvpn --genkey secret ta.key
cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem ta.key /etc/openvpn/

cat << 'EOF' > /etc/openvpn/server.conf
port 1194
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt ta.key
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

systemctl enable openvpn@server
systemctl start openvpn@server

# 2. Python SSL WebSocket Proxy Bridge (Port 443 -> Local OpenVPN 1194)
echo "[+] Setting up Python SSL WebSocket proxy on port 443..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/openvpn/key.pem -out /etc/openvpn/cert.pem -subj "/CN=vpn"

cat << 'EOF' > /usr/local/bin/wss-ovpn.py
import socket, ssl, threading

def proxy(client):
    try:
        req = client.recv(4096).decode('utf-8', errors='ignore')
        if "Upgrade: websocket" in req or "upgrade: websocket" in req.lower():
            for line in req.split('\r\n'):
                if line.lower().startswith('sec-websocket-key:'):
                    import base64, hashlib
                    key = line.split(':')[1].strip()
                    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                    client.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode())
                    break
        target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target.connect(('127.0.0.1', 1194))
        
        while True:
            client.settimeout(0.5); target.settimeout(0.5)
            try:
                data = client.recv(4096)
                if not data: break
                target.sendall(data)
            except socket.timeout: pass
            try:
                data = target.recv(4096)
                if not data: break
                client.sendall(data)
            except socket.timeout: pass
    except: pass
    finally: client.close()

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certfile='/etc/openvpn/cert.pem', keyfile='/etc/openvpn/key.pem')

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', 443))
server.listen(100)

while True:
    client_sock, _ = server.accept()
    try:
        secure_client = context.wrap_socket(client_sock, server_side=True)
        threading.Thread(target=proxy, args=(secure_client,), daemon=True).start()
    except:
        client_sock.close()
EOF

chmod +x /usr/local/bin/wss-ovpn.py

# 3. Systemd Service for WSS Bridge
cat << 'EOF' > /etc/systemd/system/wss-ovpn.service
[Unit]
Description=Python WSS to OpenVPN Bridge
After=network.target openvpn@server.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/wss-ovpn.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wss-ovpn.service
systemctl start wss-ovpn.service

# 4. Firewall NAT Routing
DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}')
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$DEFAULT_IF" -j MASQUERADE
iptables-save > /etc/iptables.up.rules

echo "[+] Installation complete!"
echo "[+] OpenSSH is running on default port 22."
echo "[+] OpenVPN is wrapped in a Secure WebSocket (WSS) listening on port 443."
