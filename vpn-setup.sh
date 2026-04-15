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
mkdir -p /opt/vpn-dashboard/templates /var/log/xray

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

# ── 7. Xray config ──────────────────────────────────────
echo "[*] Writing Xray config..."
cat > /usr/local/etc/xray/config.json << XRAYEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log"
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
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      }
    ]
  }
}
XRAYEOF
echo "[+] Xray config written"

# ── 8. Dashboard app.py ─────────────────────────────────
echo "[*] Writing dashboard..."
cat > /opt/vpn-dashboard/app.py << 'APPEOF'
#!/usr/bin/env python3
"""VPN Dashboard"""

import json, os, subprocess, uuid, time, re, threading
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
SERVER_IP = '__SERVER_IP__'
SERVER_PORT = 443
REALITY_SNI = 'www.google.com'
REALITY_FP = 'chrome'
REALITY_PBK = '__REALITY_PBK__'
REALITY_SID = '__REALITY_SID__'
XRAY_API = '127.0.0.1:10085'
NET_IFACE = '__NET_IFACE__'

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

def vless_link(client_uuid, name='VPN'):
    return (f"vless://{client_uuid}@{SERVER_IP}:{SERVER_PORT}"
            f"?encryption=none&flow=xtls-rprx-vision&security=reality"
            f"&sni={REALITY_SNI}&fp={REALITY_FP}&pbk={REALITY_PBK}"
            f"&sid={REALITY_SID}&type=tcp#{name}")

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
                    'link':vless_link(cid, meta.get('name','VPN'))})
            break
    return jsonify(clients)

@app.route('/api/clients', methods=['POST'])
@limiter.limit("10 per minute")
def api_add_client():
    data = request.get_json() or {}; name = data.get('name','').strip()
    if not name: return jsonify({'error':'Name required'}), 400
    cid = str(uuid.uuid4()); email = f"{re.sub(r'[^a-z0-9]', '-', name.lower())}@vpn"
    config = load_json(XRAY_CONFIG)
    for ib in config.get('inbounds',[]):
        if ib.get('protocol') == 'vless':
            ib['settings']['clients'].append({'id':cid,'flow':'xtls-rprx-vision','email':email}); break
    save_json(XRAY_CONFIG, config)
    db = load_json(CLIENTS_DB, {})
    db[cid] = {'name':name,'email':email,'created':datetime.now().strftime('%Y-%m-%d %H:%M')}
    save_json(CLIENTS_DB, db); restart_xray_bg()
    return jsonify({'id':cid,'name':name,'email':email,'link':vless_link(cid,name),'created':db[cid]['created']})

@app.route('/api/clients/<cid>', methods=['DELETE'])
@limiter.limit("10 per minute")
def api_del_client(cid):
    config = load_json(XRAY_CONFIG); found = False
    for ib in config.get('inbounds',[]):
        if ib.get('protocol') == 'vless':
            before = len(ib['settings']['clients'])
            ib['settings']['clients'] = [c for c in ib['settings']['clients'] if c['id'] != cid]
            found = before > len(ib['settings']['clients']); break
    if not found: return jsonify({'error':'Not found'}), 404
    save_json(XRAY_CONFIG, config)
    db = load_json(CLIENTS_DB, {}); db.pop(cid, None); save_json(CLIENTS_DB, db)
    restart_xray_bg(); return jsonify({'ok':True})

@app.route('/api/clients/<cid>/qr')
def api_qr(cid):
    db = load_json(CLIENTS_DB, {}); meta = db.get(cid,{})
    svg = qr_svg(vless_link(cid, meta.get('name','VPN')))
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
.client-stats{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:10px}
.client-stat-label{font-size:10px;color:var(--text2);text-transform:uppercase}
.client-stat-val{font-size:13px;font-weight:600}
.client-actions{display:flex;gap:8px}
@media(max-width:640px){header{padding:6px 10px;gap:6px}main{padding:10px}.stats{grid-template-columns:1fr 1fr;gap:8px}.stat-card{padding:12px}.stat-value{font-size:20px}.stat-label{font-size:10px}nav button{padding:6px 8px;font-size:12px}td,th{padding:6px 8px;font-size:11px}.mono{font-size:10px}.toolbar h2{font-size:14px}.btn{padding:6px 12px;font-size:12px}.btn-sm{padding:4px 8px;font-size:11px}.modal{padding:16px;border-radius:12px;margin:8px}.modal-overlay{padding:8px}.qr-wrap svg{width:200px;height:200px}.link-box{font-size:10px;padding:10px}}
@media(max-width:380px){.stats{grid-template-columns:1fr}.stat-value{font-size:18px}}
</style></head><body>
<header><h1><span>&#9670;</span> VPN Dashboard</h1><nav><button class="active" data-tab="overview">Обзор</button><button data-tab="clients">Клиенты</button><button data-tab="netflow">Netflow</button></nav></header>
<main>
<section id="overview" class="active"><div class="stats" id="sys-stats"></div><div class="toolbar"><h2>Сеть</h2><button class="btn btn-sm btn-ghost" onclick="restartXray()">Перезапустить Xray</button></div><div class="stats" id="net-stats"></div></section>
<section id="clients"><div class="toolbar"><h2>Клиенты VPN</h2><button class="btn btn-blue" onclick="showAddClient()">+ Добавить</button></div><div id="clients-list"></div></section>
<section id="netflow"><div class="toolbar"><h2>Netflow / Access Log</h2><button class="btn btn-sm btn-ghost" onclick="loadNetflow()">Обновить</button></div><div class="filter-row"><input type="search" id="nf-search" placeholder="Фильтр по IP, домену, email..." oninput="filterNetflow()"></div><div class="table-wrap"><table><thead><tr><th>Время</th><th>Источник</th><th>Статус</th><th>Назначение</th><th>Маршрут</th><th>Клиент</th></tr></thead><tbody id="nf-table"></tbody></table></div></section>
</main>
<div class="modal-overlay" id="modal-add"><div class="modal"><button class="modal-close" onclick="closeModal('modal-add')">&times;</button><h3>Новый клиент</h3><div class="form-group"><label>Имя устройства</label><input type="text" id="new-name" placeholder="Телефон, Ноутбук и т.д."></div><button class="btn btn-blue" onclick="addClient()">Создать</button></div></div>
<div class="modal-overlay" id="modal-detail"><div class="modal"><button class="modal-close" onclick="closeModal('modal-detail')">&times;</button><h3 id="detail-title">Клиент</h3><div id="detail-qr" class="qr-wrap"></div><label>Ссылка для импорта (скопируй в v2rayNG):</label><div class="link-box" id="detail-link"><button class="btn btn-sm btn-ghost copy-btn" onclick="copyLink()">Копировать</button><span id="detail-link-text"></span></div><details style="margin-top:12px"><summary style="cursor:pointer;color:var(--text2);font-size:13px">Параметры вручную</summary><table style="margin-top:8px;font-size:12px" id="detail-params"></table></details></div></div>
<script>
let netflowData=[],currentClients=[];
document.querySelectorAll('nav button').forEach(b=>{b.addEventListener('click',()=>{document.querySelectorAll('nav button').forEach(x=>x.classList.remove('active'));document.querySelectorAll('section').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.getElementById(b.dataset.tab).classList.add('active');if(b.dataset.tab==='clients')loadClients();if(b.dataset.tab==='netflow')loadNetflow()})});
function fmtB(b){if(!b||b===0)return'0 B';const u=['B','KB','MB','GB','TB'],i=Math.floor(Math.log(b)/Math.log(1024));return(b/Math.pow(1024,i)).toFixed(1)+' '+u[i]}
function fmtU(s){const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);if(d>0)return d+'д '+h+'ч '+m+'м';if(h>0)return h+'ч '+m+'м';return m+'м'}
function pC(p){return p>90?'var(--red)':p>70?'var(--amber)':'var(--blue)'}
function sC(l,v,c,s,p){let h='<div class="stat-card"><div class="stat-label">'+l+'</div><div class="stat-value '+(c||'')+'">'+v+'</div>';if(s)h+='<div class="stat-sub">'+s+'</div>';if(p!==undefined)h+='<div class="pbar"><div class="pbar-fill" style="width:'+p+'%;background:'+pC(p)+'"></div></div>';return h+'</div>'}
function esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML}
async function loadSystem(){try{const r=await fetch('/api/system'),d=await r.json();document.getElementById('sys-stats').innerHTML=sC('Xray',d.xray?'Active':'Down',d.xray?'green':'red',d.connections+' подключений')+sC('Uptime',fmtU(d.uptime),'blue')+sC('CPU',d.cpu+'%','',d.cores+' ядер',d.cpu)+sC('RAM',fmtB(d.mem_used),'',fmtB(d.mem_used)+' / '+fmtB(d.mem_total),d.mem_pct)+sC('Диск',d.disk_pct+'%','',fmtB(d.disk_used)+' / '+fmtB(d.disk_total),d.disk_pct);document.getElementById('net-stats').innerHTML=sC('Отправлено',fmtB(d.net_tx),'purple',d.net_pkt_tx.toLocaleString()+' пакетов')+sC('Получено',fmtB(d.net_rx),'blue',d.net_pkt_rx.toLocaleString()+' пакетов')}catch(e){}}
async function loadClients(){try{const r=await fetch('/api/clients');currentClients=await r.json();const el=document.getElementById('clients-list');if(!currentClients.length){el.textContent='Нет клиентов';el.style.cssText='text-align:center;color:var(--text2);padding:32px';return}el.style.cssText='';el.innerHTML=currentClients.map(c=>'<div class="client-card"><div class="client-header"><div><div class="client-name">'+esc(c.name)+'</div><div class="client-email">'+esc(c.email)+'</div></div><span class="badge badge-green" style="font-size:10px">'+esc(c.created)+'</span></div><div class="client-stats"><div><div class="client-stat-label">Upload</div><div class="client-stat-val" style="color:var(--purple)">'+fmtB(c.up)+'</div></div><div><div class="client-stat-label">Download</div><div class="client-stat-val" style="color:var(--blue)">'+fmtB(c.down)+'</div></div><div><div class="client-stat-label">Всего</div><div class="client-stat-val">'+fmtB(c.up+c.down)+'</div></div></div><div class="client-actions"><button class="btn btn-sm btn-ghost" style="flex:1" onclick="showDetail(\''+c.id+'\')">Конфиг / QR</button><button class="btn btn-sm btn-red" onclick="delClient(\''+c.id+'\',\''+esc(c.name)+'\')">Удалить</button></div></div>').join('')}catch(e){}}
function showAddClient(){document.getElementById('new-name').value='';document.getElementById('modal-add').classList.add('show');document.getElementById('new-name').focus()}
async function addClient(){const n=document.getElementById('new-name').value.trim();if(!n)return;try{const r=await fetch('/api/clients',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n})}),d=await r.json();if(d.error){alert(d.error);return}closeModal('modal-add');await loadClients();showDetailData(d.id,d.name,d.link)}catch(e){alert('Error: '+e)}}
async function delClient(id,n){if(!confirm('Удалить "'+n+'"?'))return;try{await fetch('/api/clients/'+id,{method:'DELETE'});loadClients()}catch(e){alert('Error: '+e)}}
function showDetail(id){const c=currentClients.find(x=>x.id===id);if(c)showDetailData(c.id,c.name,c.link)}
async function showDetailData(id,name,link){document.getElementById('detail-title').textContent=name;document.getElementById('detail-link-text').textContent=link;try{const r=await fetch('/api/clients/'+id+'/qr');document.getElementById('detail-qr').innerHTML=await r.text()}catch(e){document.getElementById('detail-qr').textContent='QR unavailable'}const url=new URL(link.replace('vless://','https://')),uid=link.split('://')[1].split('@')[0];const ps=[['Protocol','VLESS'],['Address',url.hostname],['Port',url.port],['UUID',uid],['Flow',url.searchParams.get('flow')],['Security',url.searchParams.get('security')],['SNI',url.searchParams.get('sni')],['Fingerprint',url.searchParams.get('fp')],['Public Key',url.searchParams.get('pbk')],['Short ID',url.searchParams.get('sid')],['Transport',url.searchParams.get('type')]];document.getElementById('detail-params').innerHTML=ps.map(function(p){return'<tr><td style="padding:4px 12px 4px 0;color:var(--text2)">'+p[0]+'</td><td class="mono">'+p[1]+'</td></tr>'}).join('');document.getElementById('modal-detail').classList.add('show')}
function copyLink(){const t=document.getElementById('detail-link-text').textContent;navigator.clipboard.writeText(t).then(()=>{const b=document.querySelector('#detail-link .copy-btn');b.textContent='Скопировано!';setTimeout(()=>b.textContent='Копировать',1500)})}
async function loadNetflow(){try{const r=await fetch('/api/netflow');netflowData=await r.json();renderNF(netflowData)}catch(e){}}
function renderNF(data){const tb=document.getElementById('nf-table');if(!data.length){tb.innerHTML='<tr><td colspan="6" style="text-align:center;color:var(--text2);padding:32px">Нет записей</td></tr>';return}tb.innerHTML=data.slice(0,200).map(e=>'<tr><td class="mono" style="white-space:nowrap">'+esc(e.time)+'</td><td class="mono">'+esc(e.source)+'</td><td><span class="badge '+(e.status==='accepted'?'badge-green':'badge-red')+'">'+esc(e.status)+'</span></td><td class="mono">'+esc(e.dest)+'</td><td style="color:var(--text2);font-size:12px">'+esc(e.route||'')+'</td><td class="mono">'+esc(e.email)+'</td></tr>').join('')}
function filterNetflow(){const q=document.getElementById('nf-search').value.toLowerCase();if(!q){renderNF(netflowData);return}renderNF(netflowData.filter(e=>e.source.toLowerCase().includes(q)||e.dest.toLowerCase().includes(q)||e.email.toLowerCase().includes(q)||(e.route||'').toLowerCase().includes(q)))}
function closeModal(id){document.getElementById(id).classList.remove('show')}
document.querySelectorAll('.modal-overlay').forEach(m=>{m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('show')})});
document.addEventListener('keydown',e=>{if(e.key==='Escape')document.querySelectorAll('.modal-overlay.show').forEach(m=>m.classList.remove('show'))});
document.getElementById('new-name').addEventListener('keydown',e=>{if(e.key==='Enter')addClient()});
async function restartXray(){if(!confirm('Перезапустить Xray?'))return;try{const r=await fetch('/api/xray/restart',{method:'POST'}),d=await r.json();alert(d.ok?'Xray перезапущен':'Ошибка');loadSystem()}catch(e){alert('Error: '+e)}}
loadSystem();setInterval(loadSystem,5000);
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
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = 22
logpath = %(sshd_log)s
backend = systemd
F2BEOF
echo "[+] Fail2ban configured"

# ── 14. SSH hardening ───────────────────────────────────
echo "[*] Hardening SSH..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
sshd -t && systemctl reload ssh
echo "[+] SSH hardened (no root, no X11, max 3 tries)"

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
chmod 600 /usr/local/etc/xray/config.json
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
CREDEOF
chmod 600 /opt/vpn-credentials.txt
echo "  Credentials saved to /opt/vpn-credentials.txt"
echo ""
