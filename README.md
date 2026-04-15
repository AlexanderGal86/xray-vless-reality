# Xray VLESS+REALITY VPN Server

One-command deploy of a censorship-resistant VPN server with a web management dashboard.

Uses [Xray](https://github.com/XTLS/Xray-core) VLESS protocol with REALITY — traffic is indistinguishable from regular TLS 1.3 connections to Google, making it undetectable by DPI (Deep Packet Inspection).

## What you get

- **Xray VLESS+REALITY** on port 443 — looks like normal HTTPS to google.com
- **Web Dashboard** (port 8080, VPN-only access) — system stats, client management, netflow log
- **BBR** congestion control + optimized network buffers
- **Whitelist firewall** — only SSH (22), VPN (443), DHCP (68) open
- **Fail2ban** — auto-bans brute-force SSH attackers with escalating timeouts
- **Log rotation** — Xray logs rotated daily, kept 7 days
- **SSH hardening** — root login disabled, X11 off, max 3 auth tries

## Quick Start

### Option 1: Run on existing server

```bash
curl -sL https://raw.githubusercontent.com/AlexanderGal86/xray-vless-reality/main/vpn-setup.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/AlexanderGal86/xray-vless-reality.git
bash xray-vless-reality/vpn-setup.sh
```

### Option 2: Cloud-init (new VM)

Paste the contents of `cloud-init.yml` into the **User Data** field when creating a new VM on Hetzner, DigitalOcean, Vultr, AWS, etc.

After boot:

```bash
cat /opt/vpn-credentials.txt
```

## Requirements

- Ubuntu 22.04 or 24.04
- Root access
- Public IPv4 address

## After Setup

The script outputs:

1. **VLESS link** — copy into v2rayNG (Android) or v2rayN (Windows)
2. **QR code** — scan with v2rayNG
3. **Dashboard URL** — `http://<server-ip>:8080` (accessible only through VPN)

Credentials are saved to `/opt/vpn-credentials.txt` (mode 600).

## Dashboard

<details>
<summary>Features</summary>

- **Overview** — CPU, RAM, disk, uptime, network TX/RX, active connections, Xray status
- **Clients** — add/remove VPN clients, view traffic per client, QR codes, VLESS links
- **Netflow** — real-time access log with filtering by IP, domain, client

</details>

<details>
<summary>Security</summary>

- Accessible only through VPN tunnel (port 8080 blocked on public interface)
- Security headers: CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy
- Rate limiting: 120 req/min default, 10/min for client operations, 3/min for Xray restart
- XSS protection via DOM-based escaping

</details>

The dashboard source is in `dashboard/` for reference. The setup script embeds it automatically — no separate install needed.

## File Structure

```
vpn-setup.sh          # Self-contained setup script (~640 lines)
cloud-init.yml        # Cloud-init config with embedded script
dashboard/
  app.py              # Flask backend (reference copy)
  templates/
    index.html        # Dashboard UI (reference copy)
```

## Security Features

| Feature | Details |
|---------|---------|
| Firewall | Whitelist: INPUT DROP, only 22/443/68 allowed |
| Fail2ban | 5 retries, 1h ban escalating to 1 week |
| SSH | No root login, no X11, max 3 tries per connection |
| Xray config | Mode 600 (root only) |
| Dashboard | VPN-only access, rate limited, security headers |
| Log rotation | Daily, 7 days retention, copytruncate |

## Client Apps

| Platform | App |
|----------|-----|
| Android | [v2rayNG](https://github.com/2dust/v2rayNG/releases) |
| iOS | [Streisand](https://apps.apple.com/app/streisand/id6450534064) |
| Windows | [v2rayN](https://github.com/2dust/v2rayN/releases) |
| macOS | [V2BOX](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) |
| Linux | [v2rayA](https://github.com/v2rayA/v2rayA) |

## License

[Apache License 2.0](LICENSE)
