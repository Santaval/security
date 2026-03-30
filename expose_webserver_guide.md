# Exposing a Web Server to the Internet via the Edge-Firewall

## Overview

This guide explains how to make a web server running inside the DMZ segment reachable from the internet (WAN). The technique used is **DNAT (Destination NAT)**, also known as **port forwarding**.

Flask's built-in development server is **not suitable for internet exposure** — it is single-threaded and lacks security hardening. This guide uses **Gunicorn** as the WSGI application server and **Nginx** as the production-grade reverse proxy listening on port 80.

The traffic flow is:

```
Internet → WAN IP (172.24.131.210:80) → Edge-Firewall (DNAT) → Nginx (192.168.20.10:80) → Gunicorn (127.0.0.1:5000) → Flask App
```

---

## Prerequisites

- The Edge-Firewall from the main lab guide is already configured (NAT + forwarding rules in place).
- The DMZ host (`192.168.20.10`) is running Ubuntu with internet access via the firewall.

---

## Step 1 — Prepare the Flask App on the DMZ Host

On the DMZ host (`192.168.20.10`), create the application file:

```python
# webserver.py
from flask import Flask
app = Flask(__name__)

@app.route('/')
def home():
    return "<h1>Hello from my Ubuntu Server!</h1>"

if __name__ == "__main__":
    app.run(host='0.0.0.0')
```

Install Flask and Gunicorn:

```bash
pip install flask gunicorn
```

> **Note:** Do **not** start Flask directly with `python3 webserver.py`. Gunicorn will serve the app instead.

---

## Step 2 — Run Flask with Gunicorn

Gunicorn handles concurrent requests and is safe to expose behind a reverse proxy. Bind it to localhost only — Nginx will proxy to it:

```bash
gunicorn --workers 3 --bind 127.0.0.1:5000 webserver:app
```

Verify it is listening on localhost:
```bash
ss -tlnp | grep 5000
```

Expected output should show `127.0.0.1:5000` — **not** `0.0.0.0:5000`. Gunicorn must not be directly reachable from the network; only Nginx talks to it.

---

## Step 3 — Install and Configure Nginx as a Reverse Proxy

All commands in this step are run **on the DMZ host**.

### 3.1 Install Nginx

```bash
sudo apt install nginx -y
```

### 3.2 Create the site configuration

Create `/etc/nginx/sites-available/flask_app`:

```nginx
server {
    listen 80;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

### 3.3 Enable the site and disable the default

```bash
sudo ln -s /etc/nginx/sites-available/flask_app /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
```

### 3.4 Test and reload Nginx

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Verify Nginx is listening on port 80:
```bash
ss -tlnp | grep 80
```

---

## Step 4 — Configure Port Forwarding on the Edge-Firewall

All commands below are run **on the Edge-Firewall**, not the DMZ host.

### 4.1 Add a DNAT rule (port forwarding)

Redirect incoming WAN traffic on port 80 to Nginx on the DMZ host:

```bash
sudo iptables -t nat -A PREROUTING -i ens160 -p tcp --dport 80 -j DNAT --to-destination 192.168.20.10:80
```

> **What this does:** Any packet arriving on `ens160` (WAN) destined for port 80 gets its destination rewritten to `192.168.20.10:80` before routing takes place.

### 4.2 Allow the forwarded traffic through the FORWARD chain

```bash
sudo iptables -A FORWARD -i ens160 -o ens192 -p tcp --dport 80 -d 192.168.20.10 -j ACCEPT
```

### 4.3 Verify the rules

Check the NAT table:
```bash
sudo iptables -t nat -L PREROUTING -v -n
```

Check the FORWARD chain:
```bash
sudo iptables -L FORWARD -v -n
```

---

## Step 5 — Test the Exposure

From any machine on the internet (or another host outside your network), run:

```bash
curl http://172.24.131.210
```

Expected response:
```html
<h1>Hello from my Ubuntu Server!</h1>
```

You can also open `http://172.24.131.210` in a browser.

---

## Step 6 — Make the Rules Persistent

`iptables` rules are lost on reboot. Save them so they are restored automatically:

```bash
sudo apt install iptables-persistent -y
sudo netfilter-persistent save
```

Rules are saved to `/etc/iptables/rules.v4` and loaded at boot.

To ensure Nginx and Gunicorn also start on reboot, enable Nginx as a systemd service (on the DMZ host):

```bash
sudo systemctl enable nginx
```

For Gunicorn, create a systemd unit file at `/etc/systemd/system/flask_app.service` on the DMZ host:

```ini
[Unit]
Description=Gunicorn instance for Flask app
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu
ExecStart=/usr/local/bin/gunicorn --workers 3 --bind 127.0.0.1:5000 webserver:app
Restart=always

[Install]
WantedBy=multi-user.target
```

Enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable flask_app
sudo systemctl start flask_app
```

---

## Summary of iptables Rules Added

| Table | Chain | Rule | Purpose |
|---|---|---|---|
| `nat` | `PREROUTING` | `-i ens160 -p tcp --dport 80 -j DNAT --to 192.168.20.10:80` | Redirect WAN port 80 → Nginx on DMZ host port 80 |
| `filter` | `FORWARD` | `-i ens160 -o ens192 -p tcp --dport 80 -d 192.168.20.10 -j ACCEPT` | Allow forwarded traffic to reach Nginx |

---

## Network Diagram

```
                    ┌──────────────────────────────────────────┐
  Internet          │            Edge-Firewall                 │
  ──────────────────┤  ens160: 172.24.131.210                  │
  → :80             │  PREROUTING DNAT → 192.168.20.10:80      │
                    │  ens192: 192.168.20.1       ─────────────┼──→ Nginx (192.168.20.10:80)
                    └──────────────────────────────────────────┘         ↓
                                                                  Gunicorn (127.0.0.1:5000)
                                                                         ↓
                                                                    Flask App
```
