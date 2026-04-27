#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════════
#  VPN Server Setup — Xray VLESS+REALITY + Dashboard
#  Runs on Ubuntu 22.04 / 24.04. Fully self-contained.
# ═══════════════════════════════════════════════════════════

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   VPN Server — Automated Setup       ║"
echo "  ║   Xray VLESS+REALITY + Dashboard     ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

# ── 1. Auto-detect server IP and interface ───────────────
SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}')
IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++)if($i=="dev")print $(i+1)}')

if [ -z "$SERVER_IP" ] || [ -z "$IFACE" ]; then
    echo "[ERROR] Cannot detect server IP or network interface."
    exit 1
fi

echo "[*] Server IP:  $SERVER_IP"
echo "[*] Interface:  $IFACE"

# ── 2. Install system packages ───────────────────────────
echo "[*] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-flask python3-psutil qrencode curl unzip openssl fail2ban > /dev/null 2>&1
pip3 install --break-system-packages flask-limiter > /dev/null 2>&1
echo "[+] Packages installed"

# ── 3. Install Xray ─────────────────────────────────────
echo "[*] Installing Xray..."
bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1
echo "[+] Xray installed: $(xray version 2>/dev/null | head -1)"

# ── 4. Generate keys ────────────────────────────────────
echo "[*] Generating keys..."
XRAY_KEYS=$(xray x25519)
PRIV_KEY=$(echo "$XRAY_KEYS" | grep 'PrivateKey' | awk '{print $NF}')
PUB_KEY=$(echo "$XRAY_KEYS" | grep 'Password' | awk '{print $NF}')
CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)

echo "[+] REALITY keys generated"
echo "[+] Client UUID: $CLIENT_UUID"

# ── 5. Create directories ───────────────────────────────
mkdir -p /opt/vpn-dashboard/templates /opt/vpn-dashboard/static /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chown nobody:nogroup /var/log/xray/access.log /var/log/xray/error.log
chmod 644 /var/log/xray/error.log

# ── 5b. Download Chart.js (served locally due to CSP) ───
echo "[*] Downloading Chart.js..."
curl -sL https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js \
  -o /opt/vpn-dashboard/static/chart.min.js
echo "[+] Chart.js downloaded"

# ── 6. Sysctl — BBR and network optimization ────────────
echo "[*] Applying network optimizations..."

sed -i '/# === Xray VPN optimization ===/,/^$/d' /etc/sysctl.conf 2>/dev/null || true

cat >> /etc/sysctl.conf << 'SYSCTL'

# === Xray VPN optimization ===
net.ipv4.ip_forward=1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.netdev_max_backlog = 16384

SYSCTL
sysctl -p > /dev/null 2>&1
echo "[+] BBR enabled, buffers optimized"

# ── 6b. DNS-over-TLS (system-level) ─────────────────────
echo "[*] Configuring DNS-over-TLS..."
cat > /etc/systemd/resolved.conf << 'DNSEOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
FallbackDNS=1.0.0.1#cloudflare-dns.com 8.8.4.4#dns.google
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
DNSEOF
systemctl restart systemd-resolved 2>/dev/null || true
echo "[+] System DNS-over-TLS configured"

# ── 7. Xray config ──────────────────────────────────────
echo "[*] Writing Xray config..."
cat > /usr/local/etc/xray/config.json << XRAYEOF
{
  "dns": {
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://8.8.8.8/dns-query"
    ],
    "queryStrategy": "UseIPv4"
  },
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CLIENT_UUID}",
            "flow": "xtls-rprx-vision",
            "email": "default@vpn"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.google.com:443",
          "xver": 0,
          "serverNames": ["www.google.com", "google.com"],
          "privateKey": "${PRIV_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic", "fakedns"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "dns",
      "tag": "dns-out"
    },
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "protocol": ["dns"],
        "outboundTag": "dns-out"
      }
    ]
  }
}
XRAYEOF
chmod 644 /usr/local/etc/xray/config.json
echo "[+] Xray config written"

# ── 8. Dashboard app.py ─────────────────────────────────
echo "[*] Writing dashboard..."
cat > /opt/vpn-dashboard/app.py << 'APPEOF'
#!/usr/bin/env python3
"""VPN Dashboard — Xray VLESS+REALITY management"""

import json, os, subprocess, uuid, time, re, threading, secrets
from collections import deque
from datetime import datetime
from flask import Flask, render_template, jsonify, request, Response
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import psutil

app = Flask(__name__)

limiter = Limiter(get_remote_address, app=app,
                  default_limits=["120 per minute"], storage_uri="memory://")

@app.after_request
def security_headers(response):
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-XSS-Protection'] = '1; mode=block'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Content-Security-Policy'] = (
        "default-src 'self'; script-src 'self' 'unsafe-inline'; "
        "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
        "connect-src 'self'; frame-ancestors 'none'")
    return response

XRAY_CONFIG = '/usr/local/etc/xray/config.json'
CLIENTS_DB = '/opt/vpn-dashboard/clients.json'
ACCESS_LOG = '/var/log/xray/access.log'
METRICS_FILE = '/opt/vpn-dashboard/metrics_history.json'
SERVER_IP = '__SERVER_IP__'
SERVER_PORT = 443
REALITY_SNI = 'www.google.com'
REALITY_FP = 'chrome'
REALITY_PBK = '__REALITY_PBK__'
REALITY_SID = '__REALITY_SID__'
XRAY_API = '127.0.0.1:10085'
NET_IFACE = '__NET_IFACE__'

_TR = {'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'yo','ж':'zh',
       'з':'z','и':'i','й':'y','к':'k','л':'l','м':'m','н':'n','о':'o',
       'п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'h','ц':'ts',
       'ч':'ch','ш':'sh','щ':'shch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya'}
def translit_name(s):
    out = []
    for ch in s:
        low = ch.lower(); t = _TR.get(low)
        if t is None: out.append(ch)
        elif ch == low: out.append(t)
        else: out.append(t[:1].upper() + t[1:])
    return re.sub(r'[^A-Za-z0-9 _-]', '', ''.join(out))[:32]

metrics_history = deque(maxlen=2880)
_prev_net = {'tx': 0, 'rx': 0, 'ts': 0}

def metrics_collector():
    global _prev_net
    if os.path.exists(METRICS_FILE):
        try:
            with open(METRICS_FILE) as f:
                for item in json.load(f): metrics_history.append(item)
        except Exception: pass
    save_counter = 0
    while True:
        try:
            cpu = psutil.cpu_percent(interval=1)
            mem = psutil.virtual_memory()
            net = psutil.net_io_counters(pernic=True)
            ens = net.get(NET_IFACE, psutil.net_io_counters())
            now = time.time()
            dt = now - _prev_net['ts'] if _prev_net['ts'] else 30
            tx_rate = max(0, (ens.bytes_sent - _prev_net['tx']) / dt) if _prev_net['tx'] else 0
            rx_rate = max(0, (ens.bytes_recv - _prev_net['rx']) / dt) if _prev_net['rx'] else 0
            _prev_net = {'tx': ens.bytes_sent, 'rx': ens.bytes_recv, 'ts': now}
            conns = 0
            try:
                for c in psutil.net_connections('tcp'):
                    if c.laddr and c.laddr.port == 443 and c.status == 'ESTABLISHED': conns += 1
            except Exception: pass
            metrics_history.append({'ts':int(now),'cpu':cpu,'mem':mem.percent,
                'tx':int(tx_rate),'rx':int(rx_rate),'conns':conns})
            save_counter += 1
            if save_counter >= 10:
                save_counter = 0
                try:
                    with open(METRICS_FILE, 'w') as f: json.dump(list(metrics_history), f)
                except Exception: pass
        except Exception: pass
        time.sleep(30)

def load_json(path, default=None):
    try:
        with open(path) as f: return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default if default is not None else {}

def save_json(path, data):
    with open(path, 'w') as f: json.dump(data, f, indent=2, ensure_ascii=False)

def restart_xray():
    subprocess.run(['systemctl', 'restart', 'xray'], capture_output=True, timeout=10)
    time.sleep(0.5)

def restart_xray_bg():
    def _r():
        time.sleep(1.5)
        subprocess.run(['systemctl', 'restart', 'xray'], capture_output=True, timeout=10)
    threading.Thread(target=_r, daemon=True).start()

def vless_link(client_uuid, name='VPN', sid=None):
    return (f"vless://{client_uuid}@{SERVER_IP}:{SERVER_PORT}"
            f"?encryption=none&flow=xtls-rprx-vision&security=reality"
            f"&sni={REALITY_SNI}&fp={REALITY_FP}&pbk={REALITY_PBK}"
            f"&sid={sid or REALITY_SID}&type=tcp#{name}")

def qr_svg(data):
    try:
        r = subprocess.run(['qrencode','-t','SVG','-o','-','-l','M'],
                           input=data, capture_output=True, text=True, timeout=5)
        return r.stdout
    except Exception: return None

def xray_stats(pattern=''):
    try:
        r = subprocess.run(['xray','api','statsquery',f'--server={XRAY_API}',f'-pattern={pattern}'],
                           capture_output=True, text=True, timeout=5)
        out = r.stdout.strip()
        if not out: return {}
        data = json.loads(out)
        return {item['name']: int(item.get('value',0)) for item in data.get('stat',[])}
    except Exception: return {}

def client_traffic():
    raw = xray_stats('user')
    traffic = {}
    for name, value in raw.items():
        parts = name.split('>>>')
        if len(parts) >= 4:
            email, direction = parts[1], parts[3]
            if email not in traffic: traffic[email] = {'uplink':0,'downlink':0}
            traffic[email][direction] = value
    return traffic

def parse_access_log(limit=500):
    if not os.path.exists(ACCESS_LOG): return []
    try:
        r = subprocess.run(['tail','-n',str(limit),ACCESS_LOG], capture_output=True, text=True, timeout=5)
        entries = []
        for line in reversed(r.stdout.strip().split('\n')):
            if not line.strip(): continue
            m = re.match(r'(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2})\S*\s+from\s+(?:\w+:)?([\d.]+:\d+)\s+(\w+)\s+(\w+):([\w\d.:\[\]/-]+)\s*(?:\[([^\]]*)\])?\s*(?:email:\s*(\S+))?', line)
            if m:
                entries.append({'time':m.group(1),'source':m.group(2),'status':m.group(3),
                    'proto':m.group(4),'dest':m.group(5),'route':m.group(6) or '','email':m.group(7) or '-'})
        return entries
    except Exception: return []

@app.route('/')
def index(): return render_template('index.html')

@app.route('/api/system')
def api_system():
    cpu = psutil.cpu_percent(interval=0.5)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    uptime = int(time.time() - psutil.boot_time())
    net = psutil.net_io_counters(pernic=True)
    ens = net.get(NET_IFACE, psutil.net_io_counters())
    xray_active = subprocess.run(['systemctl','is-active','xray'], capture_output=True, text=True).stdout.strip() == 'active'
    conns = 0
    try:
        for c in psutil.net_connections('tcp'):
            if c.laddr and c.laddr.port == 443 and c.status == 'ESTABLISHED': conns += 1
    except Exception: pass
    return jsonify({'cpu':cpu,'cores':psutil.cpu_count(),'mem_total':mem.total,'mem_used':mem.used,
        'mem_pct':mem.percent,'disk_total':disk.total,'disk_used':disk.used,'disk_pct':disk.percent,
        'uptime':uptime,'net_tx':ens.bytes_sent,'net_rx':ens.bytes_recv,
        'net_pkt_tx':ens.packets_sent,'net_pkt_rx':ens.packets_recv,'xray':xray_active,'connections':conns})

@app.route('/api/history')
def api_history():
    r = request.args.get('range', '1h')
    cutoff = time.time() - {'1h': 3600, '6h': 21600, '24h': 86400}.get(r, 3600)
    return jsonify([m for m in metrics_history if m['ts'] >= cutoff])

@app.route('/api/netflow/stats')
def api_netflow_stats():
    entries = parse_access_log(500)
    protos = {}
    for e in entries:
        protos[e['proto']] = protos.get(e['proto'], 0) + 1
    dests = {}
    for e in entries:
        host = e['dest'].rsplit(':', 1)[0]
        dests[host] = dests.get(host, 0) + 1
    top_dests = sorted(dests.items(), key=lambda x: -x[1])[:10]
    sources = {}
    for e in entries:
        ip = e['source'].rsplit(':', 1)[0]
        sources[ip] = sources.get(ip, 0) + 1
    top_sources = sorted(sources.items(), key=lambda x: -x[1])[:10]
    clients = {}
    for e in entries:
        clients[e['email']] = clients.get(e['email'], 0) + 1
    return jsonify({
        'protocols': protos,
        'top_destinations': [{'host': h, 'count': c} for h, c in top_dests],
        'top_sources': [{'ip': ip, 'count': c} for ip, c in top_sources],
        'per_client': [{'email': k, 'count': v} for k, v in sorted(clients.items(), key=lambda x: -x[1])]})

@app.route('/api/clients')
def api_clients():
    config = load_json(XRAY_CONFIG); db = load_json(CLIENTS_DB, {}); traffic = client_traffic()
    clients = []
    for ib in config.get('inbounds', []):
        if ib.get('protocol') == 'vless':
            for c in ib.get('settings',{}).get('clients',[]):
                cid = c['id']; email = c.get('email',''); meta = db.get(cid,{})
                t = traffic.get(email, {'uplink':0,'downlink':0})
                clients.append({'id':cid,'email':email,
                    'name':meta.get('name', email.split('@')[0] if email else cid[:8]),
                    'created':meta.get('created','-'),'up':t['uplink'],'down':t['downlink'],
                    'link':vless_link(cid, meta.get('name','VPN'), meta.get('shortId')),
                    'sid':meta.get('shortId') or REALITY_SID,
                    'pooled':not meta.get('shortId')})
            break
    return jsonify(clients)

@app.route('/api/clients', methods=['POST'])
@limiter.limit("10 per minute")
def api_add_client():
    data = request.get_json() or {}; name = translit_name(data.get('name','').strip())
    if not name: return jsonify({'error':'Name required'}), 400
    cid = str(uuid.uuid4()); email = f"{re.sub(r'[^a-z0-9]', '-', name.lower())}@vpn"
    sid = secrets.token_hex(8)
    config = load_json(XRAY_CONFIG); pooled = False
    for ib in config.get('inbounds',[]):
        if ib.get('protocol') == 'vless':
            ib['settings']['clients'].append({'id':cid,'flow':'xtls-rprx-vision','email':email})
            sids = ib.setdefault('streamSettings',{}).setdefault('realitySettings',{}).setdefault('shortIds',[])
            if len(sids) < 8:
                sids.append(sid)
            else:
                sid = REALITY_SID; pooled = True
            break
    save_json(XRAY_CONFIG, config)
    db = load_json(CLIENTS_DB, {})
    db[cid] = {'name':name,'email':email,'shortId':sid,
               'created':datetime.now().strftime('%Y-%m-%d %H:%M')}
    save_json(CLIENTS_DB, db); restart_xray_bg()
    return jsonify({'id':cid,'name':name,'email':email,'shortId':sid,'pooled':pooled,
                    'link':vless_link(cid,name,sid),'created':db[cid]['created']})

@app.route('/api/clients/<cid>', methods=['DELETE'])
@limiter.limit("10 per minute")
def api_del_client(cid):
    config = load_json(XRAY_CONFIG); found = False
    db = load_json(CLIENTS_DB, {}); victim_sid = db.get(cid,{}).get('shortId')
    for ib in config.get('inbounds',[]):
        if ib.get('protocol') == 'vless':
            before = len(ib['settings']['clients'])
            ib['settings']['clients'] = [c for c in ib['settings']['clients'] if c['id'] != cid]
            found = before > len(ib['settings']['clients'])
            if found and victim_sid and victim_sid != REALITY_SID:
                still_used = any(m.get('shortId') == victim_sid
                                 for k,m in db.items() if k != cid)
                if not still_used:
                    sids = ib.get('streamSettings',{}).get('realitySettings',{}).get('shortIds',[])
                    if victim_sid in sids: sids.remove(victim_sid)
            break
    if not found: return jsonify({'error':'Not found'}), 404
    save_json(XRAY_CONFIG, config)
    db.pop(cid, None); save_json(CLIENTS_DB, db)
    restart_xray_bg(); return jsonify({'ok':True})

@app.route('/api/clients/<cid>/qr')
def api_qr(cid):
    db = load_json(CLIENTS_DB, {}); meta = db.get(cid,{})
    svg = qr_svg(vless_link(cid, meta.get('name','VPN'), meta.get('shortId')))
    if svg: return Response(svg, mimetype='image/svg+xml')
    return jsonify({'error':'QR failed'}), 500

@app.route('/api/netflow')
def api_netflow(): return jsonify(parse_access_log(500))

@app.route('/api/xray/restart', methods=['POST'])
@limiter.limit("3 per minute")
def api_restart_xray():
    restart_xray()
    active = subprocess.run(['systemctl','is-active','xray'], capture_output=True, text=True).stdout.strip() == 'active'
    return jsonify({'ok':active})

if __name__ == '__main__':
    if not os.path.exists(CLIENTS_DB): save_json(CLIENTS_DB, {})
    threading.Thread(target=metrics_collector, daemon=True).start()
    app.run(host='0.0.0.0', port=8080, debug=False)
APPEOF

sed -i "s|__SERVER_IP__|${SERVER_IP}|g" /opt/vpn-dashboard/app.py
sed -i "s|__REALITY_PBK__|${PUB_KEY}|g" /opt/vpn-dashboard/app.py
sed -i "s|__REALITY_SID__|${SHORT_ID}|g" /opt/vpn-dashboard/app.py
sed -i "s|__NET_IFACE__|${IFACE}|g" /opt/vpn-dashboard/app.py
echo "[+] Dashboard app.py written"

# ── 9. Dashboard HTML ───────────────────────────────────
# HTML is stored as a separate file to keep the script readable
python3 -c "
import urllib.request, base64
# Write the HTML template inline
" 2>/dev/null || true

cp /opt/vpn-dashboard/templates/index.html /opt/vpn-dashboard/templates/index.html.bak 2>/dev/null || true
cat > /opt/vpn-dashboard/templates/index.html << 'HTMLEOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VPN Dashboard</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#0f172a;--card:#1e293b;--card2:#334155;--border:#475569;--text:#f1f5f9;--text2:#94a3b8;--blue:#3b82f6;--green:#22c55e;--red:#ef4444;--amber:#f59e0b;--purple:#a855f7}
body{font-family:system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
a{color:var(--blue)}
header{background:#0d1325;border-bottom:1px solid var(--card2);padding:8px 16px;display:flex;flex-direction:column;gap:8px;position:sticky;top:0;z-index:100}
header h1{font-size:18px;font-weight:700;white-space:nowrap}
header h1 span{color:var(--blue)}
nav{display:flex;gap:4px}
nav button{background:none;border:none;color:var(--text2);padding:8px 16px;cursor:pointer;font-size:14px;border-radius:6px;transition:.15s;flex:1;text-align:center}
nav button:hover{color:var(--text);background:var(--card)}
nav button.active{color:var(--blue);background:rgba(59,130,246,.12)}
main{max-width:1280px;margin:0 auto;padding:24px}
section{display:none}section.active{display:block}
.status-bar{display:flex;gap:10px;margin-bottom:16px;flex-wrap:wrap}
.status-item{background:var(--card);border-radius:10px;padding:10px 16px;display:flex;align-items:center;gap:8px;flex:1;min-width:120px}
.status-dot{width:8px;height:8px;border-radius:50%}
.status-label{font-size:11px;color:var(--text2);text-transform:uppercase;letter-spacing:.5px}
.status-value{font-size:16px;font-weight:700}
.range-bar{display:flex;gap:4px}
.range-btn{background:var(--card);border:1px solid transparent;color:var(--text2);padding:6px 16px;cursor:pointer;font-size:12px;border-radius:6px;transition:.15s}
.range-btn:hover{color:var(--text);border-color:var(--card2)}
.range-btn.active{color:var(--blue);background:rgba(59,130,246,.12);border-color:rgba(59,130,246,.3)}
.charts-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:20px}
.chart-card{background:var(--card);border-radius:12px;padding:16px;border:1px solid transparent;transition:.2s}
.chart-card:hover{border-color:var(--card2)}
.chart-title{font-size:12px;color:var(--text2);text-transform:uppercase;letter-spacing:.5px;margin-bottom:12px;display:flex;justify-content:space-between;align-items:center}
.chart-title .live-val{font-size:18px;font-weight:700;color:var(--text);text-transform:none;letter-spacing:0}
.chart-wrap{position:relative;height:180px}
.nf-charts{display:grid;grid-template-columns:2fr 1fr 2fr;gap:16px;margin-bottom:20px}
.nf-chart-card{background:var(--card);border-radius:12px;padding:16px}
.nf-chart-wrap{position:relative;height:200px}
.doughnut-wrap{position:relative;height:200px;display:flex;align-items:center;justify-content:center}
.stats{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-bottom:20px}
.stat-card{background:var(--card);border-radius:12px;padding:14px;border:1px solid transparent;transition:.2s}
.stat-card:hover{border-color:var(--card2)}
.stat-label{font-size:11px;color:var(--text2);text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px}
.stat-value{font-size:22px;font-weight:700}
.stat-sub{font-size:12px;color:var(--text2);margin-top:4px}
.stat-value.green{color:var(--green)}.stat-value.red{color:var(--red)}.stat-value.blue{color:var(--blue)}.stat-value.amber{color:var(--amber)}.stat-value.purple{color:var(--purple)}
.pbar{height:6px;background:var(--card2);border-radius:3px;margin-top:10px;overflow:hidden}
.pbar-fill{height:100%;border-radius:3px;transition:width .5s}
.table-wrap{background:var(--card);border-radius:12px;overflow-x:auto;border:1px solid transparent;-webkit-overflow-scrolling:touch}
table{width:100%;border-collapse:collapse}
th{text-align:left;padding:10px 12px;font-size:11px;color:var(--text2);text-transform:uppercase;letter-spacing:.5px;background:rgba(0,0,0,.2);border-bottom:1px solid var(--card2);white-space:nowrap}
td{padding:8px 12px;font-size:12px;border-bottom:1px solid rgba(71,85,105,.3)}
tr:last-child td{border-bottom:none}
tr:hover td{background:rgba(255,255,255,.02)}
.mono{font-family:'SF Mono',SFMono-Regular,Consolas,monospace;font-size:11px}
.btn{display:inline-flex;align-items:center;gap:6px;padding:8px 16px;border:none;border-radius:8px;cursor:pointer;font-size:13px;font-weight:500;transition:.15s}
.btn-blue{background:var(--blue);color:#fff}.btn-blue:hover{background:#2563eb}
.btn-red{background:rgba(239,68,68,.15);color:var(--red)}.btn-red:hover{background:rgba(239,68,68,.25)}
.btn-sm{padding:5px 10px;font-size:12px;border-radius:6px}
.btn-ghost{background:transparent;color:var(--text2);border:1px solid var(--border)}.btn-ghost:hover{color:var(--text);border-color:var(--text2)}
.toolbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;flex-wrap:wrap;gap:12px}
.toolbar h2{font-size:16px;font-weight:600}
.badge{display:inline-block;padding:2px 8px;border-radius:9999px;font-size:11px;font-weight:600}
.badge-green{background:rgba(34,197,94,.15);color:var(--green)}.badge-red{background:rgba(239,68,68,.15);color:var(--red)}.badge-blue{background:rgba(59,130,246,.15);color:var(--blue)}
.modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:200;align-items:center;justify-content:center;padding:24px}
.modal-overlay.show{display:flex}
.modal{background:var(--card);border-radius:16px;padding:24px;max-width:560px;width:100%;max-height:85vh;overflow-y:auto;border:1px solid var(--card2)}
.modal h3{font-size:18px;margin-bottom:16px}
.modal-close{float:right;background:none;border:none;color:var(--text2);cursor:pointer;font-size:20px;padding:4px 8px;border-radius:6px}
.modal-close:hover{color:var(--text);background:var(--card2)}
input[type="text"],input[type="search"]{width:100%;padding:10px 14px;background:var(--bg);border:1px solid var(--card2);border-radius:8px;color:var(--text);font-size:14px;outline:none;transition:.15s}
input:focus{border-color:var(--blue)}
label{font-size:13px;color:var(--text2);margin-bottom:6px;display:block}
.form-group{margin-bottom:16px}
.link-box{background:var(--bg);border:1px solid var(--card2);border-radius:8px;padding:12px;word-break:break-all;font-family:monospace;font-size:12px;position:relative;margin:12px 0}
.link-box .copy-btn{position:absolute;top:8px;right:8px}
.qr-wrap{display:flex;justify-content:center;margin:16px 0;background:#fff;border-radius:12px;padding:16px}
.qr-wrap svg{width:240px;height:240px}
.filter-row{display:flex;gap:12px;margin-bottom:16px;flex-wrap:wrap}.filter-row input{max-width:100%}
.client-card{background:var(--card);border-radius:12px;padding:14px;margin-bottom:10px;border:1px solid transparent;transition:.2s}
.client-card:hover{border-color:var(--card2)}
.client-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px}
.client-name{font-weight:600;font-size:15px}
.client-email{font-size:11px;color:var(--text2);font-family:monospace}
.client-sid{font-size:10px;color:var(--text2);font-family:monospace;margin-top:2px}
.client-sid .shared{color:#a78bfa;margin-left:6px;font-style:italic}
.client-stats{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:10px}
.client-stat-label{font-size:10px;color:var(--text2);text-transform:uppercase}
.client-stat-val{font-size:13px;font-weight:600}
.client-actions{display:flex;gap:8px}
@media(max-width:768px){.charts-grid,.nf-charts{grid-template-columns:1fr}.chart-wrap,.nf-chart-wrap{height:150px}.doughnut-wrap{height:180px}}
@media(max-width:640px){header{padding:6px 10px;gap:6px}main{padding:10px}.stats{grid-template-columns:1fr 1fr;gap:8px}.stat-card{padding:12px}.stat-value{font-size:20px}.stat-label{font-size:10px}nav button{padding:6px 8px;font-size:12px}td,th{padding:6px 8px;font-size:11px}.mono{font-size:10px}.toolbar h2{font-size:14px}.btn{padding:6px 12px;font-size:12px}.btn-sm{padding:4px 8px;font-size:11px}.modal{padding:16px;border-radius:12px;margin:8px}.modal-overlay{padding:8px}.qr-wrap svg{width:200px;height:200px}.link-box{font-size:10px;padding:10px}.status-bar{gap:6px}.status-item{padding:8px 10px;min-width:90px}.status-value{font-size:14px}.chart-wrap{height:130px}}
@media(max-width:380px){.status-bar{flex-direction:column}.chart-wrap{height:120px}}
</style></head><body>
<header><h1><span>&#9670;</span> VPN Dashboard</h1><nav><button class="active" data-tab="overview">Обзор</button><button data-tab="clients">Клиенты</button><button data-tab="netflow">Netflow</button></nav></header>
<main>
<section id="overview" class="active">
<div class="status-bar" id="status-bar"></div>
<div class="toolbar"><h2>Мониторинг</h2><div class="range-bar" id="range-bar"><button class="range-btn active" data-r="1h">1ч</button><button class="range-btn" data-r="6h">6ч</button><button class="range-btn" data-r="24h">24ч</button></div></div>
<div class="charts-grid">
<div class="chart-card"><div class="chart-title"><span>CPU</span><span class="live-val blue" id="live-cpu"></span></div><div class="chart-wrap"><canvas id="chart-cpu"></canvas></div></div>
<div class="chart-card"><div class="chart-title"><span>RAM</span><span class="live-val purple" id="live-mem"></span></div><div class="chart-wrap"><canvas id="chart-mem"></canvas></div></div>
<div class="chart-card"><div class="chart-title"><span>Сеть</span><span class="live-val" id="live-net"></span></div><div class="chart-wrap"><canvas id="chart-net"></canvas></div></div>
<div class="chart-card"><div class="chart-title"><span>Подключения</span><span class="live-val green" id="live-conns"></span></div><div class="chart-wrap"><canvas id="chart-conns"></canvas></div></div>
</div>
<div class="toolbar"><h2>Диск</h2><button class="btn btn-sm btn-ghost" onclick="restartXray()">Перезапустить Xray</button></div>
<div class="stats" id="disk-stats"></div>
<div class="toolbar"><h2>Трафик клиентов</h2></div>
<div class="chart-card" style="margin-bottom:20px"><div class="chart-wrap" style="height:auto;min-height:80px"><canvas id="chart-traffic"></canvas></div></div>
</section>
<section id="clients"><div class="toolbar"><h2>Клиенты VPN</h2><button class="btn btn-blue" onclick="showAddClient()">+ Добавить</button></div><div id="clients-list"></div></section>
<section id="netflow">
<div class="toolbar"><h2>Netflow / Access Log</h2><button class="btn btn-sm btn-ghost" onclick="loadNetflow()">Обновить</button></div>
<div class="nf-charts">
<div class="nf-chart-card"><div class="chart-title">Топ источников</div><div class="nf-chart-wrap"><canvas id="chart-nf-sources"></canvas></div></div>
<div class="nf-chart-card"><div class="chart-title">Протоколы</div><div class="doughnut-wrap"><canvas id="chart-nf-proto"></canvas></div></div>
<div class="nf-chart-card"><div class="chart-title">Топ направления</div><div class="nf-chart-wrap"><canvas id="chart-nf-dests"></canvas></div></div>
</div>
<div class="filter-row"><input type="search" id="nf-search" placeholder="Фильтр: IP, домен, email, tcp/udp, accepted, время — можно несколько слов" oninput="filterNetflow()" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></div>
<div class="table-wrap"><table><thead><tr><th>Время</th><th>Источник</th><th>Статус</th><th>Назначение</th><th>Маршрут</th><th>Клиент</th></tr></thead><tbody id="nf-table"></tbody></table></div>
</section>
</main>
<div class="modal-overlay" id="modal-add"><div class="modal"><button class="modal-close" onclick="closeModal('modal-add')">&times;</button><h3>Новый клиент</h3><div class="form-group"><label>Имя устройства</label><input type="text" id="new-name" maxlength="32" oninput="translitName(this)" placeholder="Phone, Laptop, ..."></div><button class="btn btn-blue" onclick="addClient()">Создать</button></div></div>
<div class="modal-overlay" id="modal-detail"><div class="modal"><button class="modal-close" onclick="closeModal('modal-detail')">&times;</button><h3 id="detail-title">Клиент</h3><div id="detail-qr" class="qr-wrap"></div><label>Ссылка для импорта (скопируй в v2rayNG):</label><div class="link-box" id="detail-link"><button class="btn btn-sm btn-ghost copy-btn" onclick="copyLink()">Копировать</button><span id="detail-link-text"></span></div><details style="margin-top:12px"><summary style="cursor:pointer;color:var(--text2);font-size:13px">Параметры вручную</summary><table style="margin-top:8px;font-size:12px" id="detail-params"></table></details></div></div>
<script src="/static/chart.min.js"></script>
<script>
/* NOTE: All user-supplied data is escaped via esc() before DOM insertion */
let netflowData=[],currentClients=[],currentRange='1h';
let chartCpu,chartMem,chartNet,chartConns,chartTraffic;
let chartNfSources,chartNfProto,chartNfDests;
let prevNetTx=0,prevNetRx=0,prevNetTs=0;
function fmtB(b){if(!b||b===0)return'0 B';const u=['B','KB','MB','GB','TB'],i=Math.floor(Math.log(b)/Math.log(1024));return(b/Math.pow(1024,i)).toFixed(1)+' '+u[i]}
function fmtU(s){const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);if(d>0)return d+'д '+h+'ч';if(h>0)return h+'ч '+m+'м';return m+'м'}
function fmtTime(ts){const d=new Date(ts*1000);return d.getHours().toString().padStart(2,'0')+':'+d.getMinutes().toString().padStart(2,'0')}
function esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML}
Chart.defaults.color='#94a3b8';Chart.defaults.borderColor='rgba(71,85,105,0.3)';Chart.defaults.font.family='system-ui,-apple-system,sans-serif';Chart.defaults.font.size=11;
function makeGrad(ctx,color){const g=ctx.createLinearGradient(0,0,0,ctx.canvas.clientHeight||180);g.addColorStop(0,color.replace(')',',0.25)').replace('rgb','rgba'));g.addColorStop(1,color.replace(')',',0.02)').replace('rgb','rgba'));return g}
const ttStyle={backgroundColor:'#1e293b',titleColor:'#f1f5f9',bodyColor:'#94a3b8',borderColor:'#475569',borderWidth:1,cornerRadius:8,padding:10};
function createLineChart(id,color,unit,isMulti){
    const ctx=document.getElementById(id).getContext('2d');
    const ds=isMulti?[
        {label:'TX',data:[],borderColor:'#a855f7',backgroundColor:makeGrad(ctx,'rgb(168,85,247)'),fill:true,tension:.4,pointRadius:0,borderWidth:2},
        {label:'RX',data:[],borderColor:'#3b82f6',backgroundColor:makeGrad(ctx,'rgb(59,130,246)'),fill:true,tension:.4,pointRadius:0,borderWidth:2}
    ]:[{label:'',data:[],borderColor:color,backgroundColor:makeGrad(ctx,color),fill:true,tension:.4,pointRadius:0,borderWidth:2}];
    return new Chart(ctx,{type:'line',data:{labels:[],datasets:ds},options:{
        responsive:true,maintainAspectRatio:false,animation:{duration:300},interaction:{intersect:false,mode:'index'},
        scales:{x:{display:true,grid:{display:false},ticks:{maxTicksLimit:6}},y:{beginAtZero:true,grid:{color:'rgba(71,85,105,0.15)'},ticks:{maxTicksLimit:5,callback:v=>unit==='bytes'?fmtB(v)+'/s':v+unit}}},
        plugins:{legend:{display:isMulti,labels:{boxWidth:10,padding:8}},tooltip:{...ttStyle,callbacks:{label:i=>i.dataset.label+': '+(unit==='bytes'?fmtB(i.raw)+'/s':i.raw+unit)}}}}});
}
function initCharts(){
    chartCpu=createLineChart('chart-cpu','rgb(59,130,246)','%',false);
    chartMem=createLineChart('chart-mem','rgb(168,85,247)','%',false);
    chartNet=createLineChart('chart-net','','bytes',true);
    chartConns=createLineChart('chart-conns','rgb(34,197,94)','',false);
}
function populateCharts(h){
    const l=h.map(m=>fmtTime(m.ts));
    chartCpu.data.labels=l;chartCpu.data.datasets[0].data=h.map(m=>m.cpu);chartCpu.update('none');
    chartMem.data.labels=l;chartMem.data.datasets[0].data=h.map(m=>m.mem);chartMem.update('none');
    chartNet.data.labels=l;chartNet.data.datasets[0].data=h.map(m=>m.tx);chartNet.data.datasets[1].data=h.map(m=>m.rx);chartNet.update('none');
    chartConns.data.labels=l;chartConns.data.datasets[0].data=h.map(m=>m.conns);chartConns.update('none');
}
async function loadHistory(){try{const r=await fetch('/api/history?range='+currentRange);populateCharts(await r.json())}catch(e){}}
async function loadSystem(){
    try{
        const r=await fetch('/api/system'),d=await r.json();
        const now=Date.now()/1000;let txR=0,rxR=0;
        if(prevNetTs){const dt=now-prevNetTs;txR=Math.max(0,(d.net_tx-prevNetTx)/dt);rxR=Math.max(0,(d.net_rx-prevNetRx)/dt)}
        prevNetTx=d.net_tx;prevNetRx=d.net_rx;prevNetTs=now;
        document.getElementById('status-bar').textContent='';
        const sb=document.getElementById('status-bar');
        sb.insertAdjacentHTML('beforeend',
            '<div class="status-item"><div class="status-dot" style="background:'+(d.xray?'var(--green)':'var(--red)')+'"></div><div><div class="status-label">Xray</div><div class="status-value">'+(d.xray?'Active':'Down')+'</div></div></div>'+
            '<div class="status-item"><div><div class="status-label">Uptime</div><div class="status-value">'+fmtU(d.uptime)+'</div></div></div>'+
            '<div class="status-item"><div><div class="status-label">Подключения</div><div class="status-value" style="color:var(--green)">'+d.connections+'</div></div></div>'+
            '<div class="status-item"><div><div class="status-label">CPU / RAM</div><div class="status-value"><span style="color:var(--blue)">'+d.cpu+'%</span> <span style="color:var(--text2)">/</span> <span style="color:var(--purple)">'+d.mem_pct+'%</span></div></div></div>');
        document.getElementById('live-cpu').textContent=d.cpu+'%';
        document.getElementById('live-mem').textContent=d.mem_pct+'%';
        document.getElementById('live-net').textContent='';
        document.getElementById('live-net').insertAdjacentHTML('beforeend','<span style="color:var(--purple)">'+fmtB(txR)+'/s</span> <span style="color:var(--text2)">/</span> <span style="color:var(--blue)">'+fmtB(rxR)+'/s</span>');
        document.getElementById('live-conns').textContent=d.connections;
        const dp=d.disk_pct,dc=dp>90?'var(--red)':dp>70?'var(--amber)':'var(--blue)';
        document.getElementById('disk-stats').textContent='';
        document.getElementById('disk-stats').insertAdjacentHTML('beforeend',
            '<div class="stat-card"><div class="stat-label">Использовано</div><div class="stat-value">'+fmtB(d.disk_used)+'</div><div class="stat-sub">из '+fmtB(d.disk_total)+'</div><div class="pbar"><div class="pbar-fill" style="width:'+dp+'%;background:'+dc+'"></div></div></div>'+
            '<div class="stat-card"><div class="stat-label">Сеть (всего)</div><div class="stat-value purple">'+fmtB(d.net_tx)+'</div><div class="stat-sub">TX: '+d.net_pkt_tx.toLocaleString()+' пакетов</div></div>');
    }catch(e){}
}
async function loadTrafficChart(){
    try{const r=await fetch('/api/clients');const cl=await r.json();if(!cl.length)return;
    if(chartTraffic)chartTraffic.destroy();
    chartTraffic=new Chart(document.getElementById('chart-traffic'),{type:'bar',
        data:{labels:cl.map(c=>c.name),datasets:[{label:'Upload',data:cl.map(c=>c.up),backgroundColor:'rgba(168,85,247,0.7)',borderRadius:4},{label:'Download',data:cl.map(c=>c.down),backgroundColor:'rgba(59,130,246,0.7)',borderRadius:4}]},
        options:{responsive:true,maintainAspectRatio:true,aspectRatio:3,indexAxis:'y',
            scales:{x:{grid:{color:'rgba(71,85,105,0.15)'},ticks:{callback:v=>fmtB(v)}},y:{grid:{display:false}}},
            plugins:{legend:{labels:{boxWidth:10,padding:8}},tooltip:{...ttStyle,callbacks:{label:i=>i.dataset.label+': '+fmtB(i.raw)}}}}});
    }catch(e){}
}
async function loadNetflowCharts(){
    try{const r=await fetch('/api/netflow/stats');const d=await r.json();
    if(chartNfSources)chartNfSources.destroy();
    chartNfSources=new Chart(document.getElementById('chart-nf-sources'),{type:'bar',
        data:{labels:d.top_sources.map(x=>x.ip),datasets:[{data:d.top_sources.map(x=>x.count),backgroundColor:'rgba(168,85,247,0.6)',borderRadius:4}]},
        options:{responsive:true,maintainAspectRatio:false,indexAxis:'y',scales:{x:{grid:{color:'rgba(71,85,105,0.15)'},ticks:{maxTicksLimit:5}},y:{grid:{display:false},ticks:{font:{family:'SFMono-Regular,Consolas,monospace',size:10}}}},plugins:{legend:{display:false},tooltip:ttStyle}}});
    if(chartNfProto)chartNfProto.destroy();
    const pl=Object.keys(d.protocols),pd=Object.values(d.protocols),pc=['rgba(59,130,246,0.8)','rgba(168,85,247,0.8)','rgba(34,197,94,0.8)','rgba(245,158,11,0.8)'];
    chartNfProto=new Chart(document.getElementById('chart-nf-proto'),{type:'doughnut',
        data:{labels:pl,datasets:[{data:pd,backgroundColor:pc.slice(0,pl.length),borderWidth:0}]},
        options:{responsive:true,maintainAspectRatio:false,cutout:'65%',plugins:{legend:{position:'bottom',labels:{boxWidth:10,padding:6}},tooltip:ttStyle}}});
    if(chartNfDests)chartNfDests.destroy();
    chartNfDests=new Chart(document.getElementById('chart-nf-dests'),{type:'bar',
        data:{labels:d.top_destinations.map(x=>x.host),datasets:[{data:d.top_destinations.map(x=>x.count),backgroundColor:'rgba(34,197,94,0.6)',borderRadius:4}]},
        options:{responsive:true,maintainAspectRatio:false,indexAxis:'y',scales:{x:{grid:{color:'rgba(71,85,105,0.15)'},ticks:{maxTicksLimit:5}},y:{grid:{display:false},ticks:{font:{family:'SFMono-Regular,Consolas,monospace',size:10}}}},plugins:{legend:{display:false},tooltip:ttStyle}}});
    }catch(e){}
}
async function loadNetflow(){loadNetflowCharts();try{const r=await fetch('/api/netflow');netflowData=await r.json();renderNF(netflowData)}catch(e){}}
function renderNF(data){const tb=document.getElementById('nf-table');if(!data.length){tb.textContent='';const tr=document.createElement('tr');const td=document.createElement('td');td.colSpan=6;td.style.cssText='text-align:center;color:var(--text2);padding:32px';td.textContent='Нет записей';tr.appendChild(td);tb.appendChild(tr);return}tb.textContent='';data.slice(0,200).forEach(function(e){const tr=document.createElement('tr');tr.insertAdjacentHTML('beforeend','<td class="mono" style="white-space:nowrap">'+esc(e.time)+'</td><td class="mono">'+esc(e.source)+'</td><td><span class="badge '+(e.status==='accepted'?'badge-green':'badge-red')+'">'+esc(e.status)+'</span></td><td class="mono">'+esc(e.dest)+'</td><td style="color:var(--text2);font-size:12px">'+esc(e.route||'')+'</td><td class="mono">'+esc(e.email)+'</td>');tb.appendChild(tr)})}
function filterNetflow(){const q=document.getElementById('nf-search').value.trim().toLowerCase();if(!q){renderNF(netflowData);return}const toks=q.split(/\s+/).filter(Boolean);const hay=e=>(e.time+' '+e.source+' '+e.status+' '+e.proto+' '+e.dest+' '+(e.route||'')+' '+(e.email||'')).toLowerCase();renderNF(netflowData.filter(e=>{const h=hay(e);return toks.every(t=>h.includes(t))}))}
async function loadClients(){try{const r=await fetch('/api/clients');currentClients=await r.json();const el=document.getElementById('clients-list');if(!currentClients.length){el.textContent='Нет клиентов';el.style.cssText='text-align:center;color:var(--text2);padding:32px';return}el.style.cssText='';el.textContent='';currentClients.forEach(function(c){el.insertAdjacentHTML('beforeend','<div class="client-card"><div class="client-header"><div><div class="client-name">'+esc(c.name)+'</div><div class="client-email">'+esc(c.email)+'</div><div class="client-sid">sid: '+esc(c.sid||'')+(c.pooled?'<span class="shared">общий</span>':'')+'</div></div><span class="badge badge-green" style="font-size:10px">'+esc(c.created)+'</span></div><div class="client-stats"><div><div class="client-stat-label">Upload</div><div class="client-stat-val" style="color:var(--purple)">'+fmtB(c.up)+'</div></div><div><div class="client-stat-label">Download</div><div class="client-stat-val" style="color:var(--blue)">'+fmtB(c.down)+'</div></div><div><div class="client-stat-label">Всего</div><div class="client-stat-val">'+fmtB(c.up+c.down)+'</div></div></div><div class="client-actions"><button class="btn btn-sm btn-ghost" style="flex:1" onclick="showDetail(\''+c.id+'\')">Конфиг / QR</button><button class="btn btn-sm btn-red" onclick="delClient(\''+c.id+'\',\''+esc(c.name)+'\')">Удалить</button></div></div>')})}catch(e){}}
const TR={а:'a',б:'b',в:'v',г:'g',д:'d',е:'e',ё:'yo',ж:'zh',з:'z',и:'i',й:'y',к:'k',л:'l',м:'m',н:'n',о:'o',п:'p',р:'r',с:'s',т:'t',у:'u',ф:'f',х:'h',ц:'ts',ч:'ch',ш:'sh',щ:'shch',ъ:'',ы:'y',ь:'',э:'e',ю:'yu',я:'ya'};
function translit(s){return s.split('').map(c=>{const l=c.toLowerCase(),t=TR[l];if(t===undefined)return c;return c===l?t:t.charAt(0).toUpperCase()+t.slice(1)}).join('')}
function translitName(el){const v=translit(el.value).replace(/[^A-Za-z0-9 _-]/g,'');if(v!==el.value){const p=el.selectionStart;el.value=v;try{el.setSelectionRange(p,p)}catch(e){}}}
function showAddClient(){document.getElementById('new-name').value='';document.getElementById('modal-add').classList.add('show');document.getElementById('new-name').focus()}
async function addClient(){const n=document.getElementById('new-name').value.trim();if(!n)return;try{const r=await fetch('/api/clients',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n})}),d=await r.json();if(d.error){alert(d.error);return}closeModal('modal-add');await loadClients();showDetailData(d.id,d.name,d.link)}catch(e){alert('Error: '+e)}}
async function delClient(id,n){if(!confirm('Удалить "'+n+'"?'))return;try{await fetch('/api/clients/'+id,{method:'DELETE'});loadClients()}catch(e){alert('Error: '+e)}}
function showDetail(id){const c=currentClients.find(x=>x.id===id);if(c)showDetailData(c.id,c.name,c.link)}
async function showDetailData(id,name,link){document.getElementById('detail-title').textContent=name;document.getElementById('detail-link-text').textContent=link;try{const r=await fetch('/api/clients/'+id+'/qr');document.getElementById('detail-qr').textContent='';document.getElementById('detail-qr').insertAdjacentHTML('beforeend',await r.text())}catch(e){document.getElementById('detail-qr').textContent='QR unavailable'}const url=new URL(link.replace('vless://','https://')),uid=link.split('://')[1].split('@')[0];const ps=[['Protocol','VLESS'],['Address',url.hostname],['Port',url.port],['UUID',uid],['Flow',url.searchParams.get('flow')],['Security',url.searchParams.get('security')],['SNI',url.searchParams.get('sni')],['Fingerprint',url.searchParams.get('fp')],['Public Key',url.searchParams.get('pbk')],['Short ID',url.searchParams.get('sid')],['Transport',url.searchParams.get('type')]];const pt=document.getElementById('detail-params');pt.textContent='';ps.forEach(function(p){pt.insertAdjacentHTML('beforeend','<tr><td style="padding:4px 12px 4px 0;color:var(--text2)">'+p[0]+'</td><td class="mono">'+p[1]+'</td></tr>')});document.getElementById('modal-detail').classList.add('show')}
function copyLink(){const t=document.getElementById('detail-link-text').textContent;navigator.clipboard.writeText(t).then(()=>{const b=document.querySelector('#detail-link .copy-btn');b.textContent='Скопировано!';setTimeout(()=>b.textContent='Копировать',1500)})}
function closeModal(id){document.getElementById(id).classList.remove('show')}
document.querySelectorAll('.modal-overlay').forEach(m=>{m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('show')})});
document.addEventListener('keydown',e=>{if(e.key==='Escape')document.querySelectorAll('.modal-overlay.show').forEach(m=>m.classList.remove('show'))});
document.getElementById('new-name').addEventListener('keydown',e=>{if(e.key==='Enter')addClient()});
document.querySelectorAll('nav button').forEach(b=>{b.addEventListener('click',()=>{document.querySelectorAll('nav button').forEach(x=>x.classList.remove('active'));document.querySelectorAll('section').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.getElementById(b.dataset.tab).classList.add('active');if(b.dataset.tab==='clients')loadClients();if(b.dataset.tab==='netflow')loadNetflow();if(b.dataset.tab==='overview'){loadHistory();loadTrafficChart()}})});
document.querySelectorAll('.range-btn').forEach(b=>{b.addEventListener('click',()=>{document.querySelectorAll('.range-btn').forEach(x=>x.classList.remove('active'));b.classList.add('active');currentRange=b.dataset.r;loadHistory()})});
async function restartXray(){if(!confirm('Перезапустить Xray?'))return;try{const r=await fetch('/api/xray/restart',{method:'POST'}),d=await r.json();alert(d.ok?'Xray перезапущен':'Ошибка');loadSystem()}catch(e){alert('Error: '+e)}}
initCharts();loadSystem();loadHistory();loadTrafficChart();setInterval(loadSystem,5000);setInterval(loadHistory,30000);
</script></body></html>
HTMLEOF
echo "[+] Dashboard HTML written"

# ── 10. Clients database ────────────────────────────────
NOW=$(date '+%Y-%m-%d %H:%M')
cat > /opt/vpn-dashboard/clients.json << CLIENTSEOF
{
  "${CLIENT_UUID}": {
    "name": "Default",
    "email": "default@vpn",
    "created": "${NOW}"
  }
}
CLIENTSEOF

# ── 11. Systemd service ─────────────────────────────────
cat > /etc/systemd/system/vpn-dashboard.service << 'SVCEOF'
[Unit]
Description=VPN Dashboard
After=network.target xray.service

[Service]
Type=simple
WorkingDirectory=/opt/vpn-dashboard
ExecStart=/usr/bin/python3 /opt/vpn-dashboard/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF

# ── 12. Log rotation ────────────────────────────────────
echo "[*] Configuring log rotation..."
cat > /etc/logrotate.d/xray << 'LOGEOF'
/var/log/xray/access.log
/var/log/xray/error.log
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0600 nobody nogroup
}
LOGEOF
echo "[+] Xray log rotation configured"

# ── 13. Fail2ban ────────────────────────────────────────
echo "[*] Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
banaction = nftables-multiport
banaction_allports = nftables-allports
bantime = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 188.242.249.138

[sshd]
enabled = true
port = 22
logpath = %(sshd_log)s
backend = systemd
F2BEOF

# Override default banaction to drop silently instead of reject+ICMP
cat > /etc/fail2ban/action.d/nftables.local << 'F2BACTEOF'
[Init]
blocktype = drop
F2BACTEOF

echo "[+] Fail2ban configured"

# ── 14. SSH hardening ───────────────────────────────────
echo "[*] Hardening SSH..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
# Idle session timeout: 60s × 20 = 1200s (20 min) before disconnect
if grep -qE '^#*ClientAliveInterval' /etc/ssh/sshd_config; then
  sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 60/' /etc/ssh/sshd_config
else
  echo 'ClientAliveInterval 60' >> /etc/ssh/sshd_config
fi
if grep -qE '^#*ClientAliveCountMax' /etc/ssh/sshd_config; then
  sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 20/' /etc/ssh/sshd_config
else
  echo 'ClientAliveCountMax 20' >> /etc/ssh/sshd_config
fi
sshd -t && systemctl reload ssh
echo "[+] SSH hardened (no root, no X11, max 3 tries, idle timeout 20 min)"

# ── 15. Firewall (whitelist) ───────────────────────────
echo "[*] Configuring firewall..."
# Flush existing rules
iptables -F INPUT
# Default policy: drop everything
iptables -P INPUT DROP
# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
# Allow established connections
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
# Allow SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
# Allow Xray (VLESS+REALITY)
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
# Allow DHCP
iptables -A INPUT -p udp --dport 68 -j ACCEPT
# MSS clamp on :443 — fixes "client connects but no traffic" when upstream
# link has MTU<1500 and PMTU discovery fails (some hosting providers / RU ISPs)
iptables -t mangle -A POSTROUTING -p tcp --sport 443 --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380
iptables -t mangle -A PREROUTING  -p tcp --dport 443 --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380
# IPv6: drop all inbound
ip6tables -P INPUT DROP
ip6tables -F INPUT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt-get install -y -qq iptables-persistent > /dev/null 2>&1
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
echo "[+] Whitelist firewall configured"

# ── 16. File permissions ────────────────────────────────
chown root:nogroup /usr/local/etc/xray/config.json
chmod 640 /usr/local/etc/xray/config.json
chmod 600 /opt/vpn-dashboard/clients.json

# ── 17. Start services ──────────────────────────────────
echo "[*] Starting services..."
systemctl daemon-reload
systemctl enable --now xray vpn-dashboard fail2ban
sleep 2

XRAY_OK=$(systemctl is-active xray)
DASH_OK=$(systemctl is-active vpn-dashboard)
F2B_OK=$(systemctl is-active fail2ban)
echo "[+] Xray: $XRAY_OK"
echo "[+] Dashboard: $DASH_OK"
echo "[+] Fail2ban: $F2B_OK"

# ── 18. Output ──────────────────────────────────────────
VLESS_LINK="vless://${CLIENT_UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google.com&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#VPN"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║         SETUP COMPLETE!              ║"
echo "  ╚══════════════════════════════════════╝"
echo ""
echo "  Server:     ${SERVER_IP}:443"
echo "  Dashboard:  http://${SERVER_IP}:8080 (only via VPN)"
echo ""
echo "  -- VLESS Link (copy to v2rayNG) --"
echo ""
echo "  ${VLESS_LINK}"
echo ""
echo "  -- QR Code (scan in v2rayNG) --"
echo ""
qrencode -t ansiutf8 "$VLESS_LINK"
echo ""
echo "  -- DNS Leak Protection --"
echo ""
echo "  Server: DoH (Cloudflare + Google) via Xray"
echo "  System: DNS-over-TLS via systemd-resolved"
echo "  Client: Set Remote DNS = https://1.1.1.1/dns-query"
echo "  Verify: https://dnsleaktest.com"
echo ""

cat > /opt/vpn-credentials.txt << CREDEOF
VPN Server Credentials — Generated: ${NOW}

Server IP:     ${SERVER_IP}
Port:          443
Protocol:      VLESS + REALITY
Public Key:    ${PUB_KEY}
Short ID:      ${SHORT_ID}
Client UUID:   ${CLIENT_UUID}

VLESS Link:
${VLESS_LINK}

Dashboard: http://${SERVER_IP}:8080 (via VPN only)

--- DNS Leak Protection (client setup) ---

Server DNS: DoH (Cloudflare + Google) — already configured.
To prevent DNS leaks on your device, configure your VPN client:

v2rayN (Windows):
  Settings > DNS > Remote DNS = https://1.1.1.1/dns-query
  Enable "Sniffing" in the server settings

v2rayNG (Android):
  Settings > Routing > DNS = https://1.1.1.1/dns-query
  Enable "Sniffing" + "FakeDNS"

Streisand / FoXray (iOS):
  Settings > DNS > Remote DNS = https://1.1.1.1/dns-query

Nekobox / sing-box:
  DNS > Remote = https://1.1.1.1/dns-query
  DNS > Strategy = prefer_ipv4
  Enable "Sniffing"

Verify: https://dnsleaktest.com (while connected to VPN)
CREDEOF
chmod 600 /opt/vpn-credentials.txt
echo "  Credentials saved to /opt/vpn-credentials.txt"
echo ""
