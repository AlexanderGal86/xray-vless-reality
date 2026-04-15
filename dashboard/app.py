#!/usr/bin/env python3
"""VPN Dashboard — Xray VLESS+REALITY management"""

import json
import os
import subprocess
import uuid
import time
import re
import threading
from collections import deque
from datetime import datetime

from flask import Flask, render_template, jsonify, request, Response
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import psutil

app = Flask(__name__)

limiter = Limiter(
    get_remote_address,
    app=app,
    default_limits=["120 per minute"],
    storage_uri="memory://",
)


@app.after_request
def security_headers(response):
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-XSS-Protection'] = '1; mode=block'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Content-Security-Policy'] = (
        "default-src 'self'; "
        "script-src 'self' 'unsafe-inline'; "
        "style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data:; "
        "connect-src 'self'; "
        "frame-ancestors 'none'"
    )
    return response

XRAY_CONFIG = '/usr/local/etc/xray/config.json'
CLIENTS_DB = '/opt/vpn-dashboard/clients.json'
ACCESS_LOG = '/var/log/xray/access.log'
METRICS_FILE = '/opt/vpn-dashboard/metrics_history.json'

SERVER_IP = '151.242.88.11'
SERVER_PORT = 443
REALITY_SNI = 'www.google.com'
REALITY_FP = 'chrome'
REALITY_PBK = 'V7bqii4d6xy8SvY3DUuozndXU74douLlYI3YGvloXzE'
REALITY_SID = 'b70c4f452946aa6a'
XRAY_API = '127.0.0.1:10085'
NET_IFACE = 'ens1'

# ── Metrics History ─────────────────────────────────────

metrics_history = deque(maxlen=2880)  # 24h @ 30s intervals
_prev_net = {'tx': 0, 'rx': 0, 'ts': 0}


def metrics_collector():
    global _prev_net
    if os.path.exists(METRICS_FILE):
        try:
            with open(METRICS_FILE) as f:
                for item in json.load(f):
                    metrics_history.append(item)
        except Exception:
            pass
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
                    if c.laddr and c.laddr.port == 443 and c.status == 'ESTABLISHED':
                        conns += 1
            except Exception:
                pass
            metrics_history.append({
                'ts': int(now),
                'cpu': cpu,
                'mem': mem.percent,
                'tx': int(tx_rate),
                'rx': int(rx_rate),
                'conns': conns,
            })
            save_counter += 1
            if save_counter >= 10:
                save_counter = 0
                try:
                    with open(METRICS_FILE, 'w') as f:
                        json.dump(list(metrics_history), f)
                except Exception:
                    pass
        except Exception:
            pass
        time.sleep(30)


# ── Helpers ──────────────────────────────────────────────

def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default if default is not None else {}


def save_json(path, data):
    with open(path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def restart_xray():
    subprocess.run(['systemctl', 'restart', 'xray'], capture_output=True, timeout=10)
    time.sleep(0.5)


def restart_xray_bg():
    def _restart():
        time.sleep(1.5)
        subprocess.run(['systemctl', 'restart', 'xray'], capture_output=True, timeout=10)
    threading.Thread(target=_restart, daemon=True).start()


def vless_link(client_uuid, name='VPN'):
    return (
        f"vless://{client_uuid}@{SERVER_IP}:{SERVER_PORT}"
        f"?encryption=none&flow=xtls-rprx-vision"
        f"&security=reality&sni={REALITY_SNI}"
        f"&fp={REALITY_FP}&pbk={REALITY_PBK}"
        f"&sid={REALITY_SID}&type=tcp"
        f"#{name}"
    )


def qr_svg(data):
    try:
        r = subprocess.run(
            ['qrencode', '-t', 'SVG', '-o', '-', '-l', 'M'],
            input=data, capture_output=True, text=True, timeout=5
        )
        return r.stdout
    except Exception:
        return None


def xray_stats(pattern=''):
    try:
        r = subprocess.run(
            ['xray', 'api', 'statsquery', f'--server={XRAY_API}', f'-pattern={pattern}'],
            capture_output=True, text=True, timeout=5
        )
        out = r.stdout.strip()
        if not out:
            return {}
        data = json.loads(out)
        return {
            item['name']: int(item.get('value', 0))
            for item in data.get('stat', [])
        }
    except Exception:
        return {}


def client_traffic():
    raw = xray_stats('user')
    traffic = {}
    for name, value in raw.items():
        parts = name.split('>>>')
        if len(parts) >= 4:
            email = parts[1]
            direction = parts[3]
            if email not in traffic:
                traffic[email] = {'uplink': 0, 'downlink': 0}
            traffic[email][direction] = value
    return traffic


def parse_access_log(limit=500):
    if not os.path.exists(ACCESS_LOG):
        return []
    try:
        r = subprocess.run(
            ['tail', '-n', str(limit), ACCESS_LOG],
            capture_output=True, text=True, timeout=5
        )
        entries = []
        for line in reversed(r.stdout.strip().split('\n')):
            if not line.strip():
                continue
            m = re.match(
                r'(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2})\S*\s+'
                r'from\s+(?:\w+:)?([\d.]+:\d+)\s+'
                r'(\w+)\s+'
                r'(\w+):([\w\d.:\[\]/-]+)\s*'
                r'(?:\[([^\]]*)\])?\s*'
                r'(?:email:\s*(\S+))?',
                line
            )
            if m:
                entries.append({
                    'time': m.group(1),
                    'source': m.group(2),
                    'status': m.group(3),
                    'proto': m.group(4),
                    'dest': m.group(5),
                    'route': m.group(6) or '',
                    'email': m.group(7) or '-',
                })
        return entries
    except Exception:
        return []


# ── API Routes ───────────────────────────────────────────

@app.route('/')
def index():
    return render_template('index.html')


@app.route('/api/system')
def api_system():
    cpu = psutil.cpu_percent(interval=0.5)
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    uptime = int(time.time() - psutil.boot_time())
    net = psutil.net_io_counters(pernic=True)
    ens = net.get(NET_IFACE, psutil.net_io_counters())

    xray_active = subprocess.run(
        ['systemctl', 'is-active', 'xray'],
        capture_output=True, text=True
    ).stdout.strip() == 'active'

    conns = 0
    try:
        for c in psutil.net_connections('tcp'):
            if c.laddr and c.laddr.port == 443 and c.status == 'ESTABLISHED':
                conns += 1
    except Exception:
        pass

    return jsonify({
        'cpu': cpu,
        'cores': psutil.cpu_count(),
        'mem_total': mem.total,
        'mem_used': mem.used,
        'mem_pct': mem.percent,
        'disk_total': disk.total,
        'disk_used': disk.used,
        'disk_pct': disk.percent,
        'uptime': uptime,
        'net_tx': ens.bytes_sent,
        'net_rx': ens.bytes_recv,
        'net_pkt_tx': ens.packets_sent,
        'net_pkt_rx': ens.packets_recv,
        'xray': xray_active,
        'connections': conns,
    })


@app.route('/api/history')
def api_history():
    r = request.args.get('range', '1h')
    cutoff = time.time() - {'1h': 3600, '6h': 21600, '24h': 86400}.get(r, 3600)
    return jsonify([m for m in metrics_history if m['ts'] >= cutoff])


@app.route('/api/netflow/stats')
def api_netflow_stats():
    entries = parse_access_log(500)
    hourly = {}
    for e in entries:
        hour = e['time'][:13]
        hourly[hour] = hourly.get(hour, 0) + 1
    protos = {}
    for e in entries:
        protos[e['proto']] = protos.get(e['proto'], 0) + 1
    dests = {}
    for e in entries:
        host = e['dest'].rsplit(':', 1)[0]
        dests[host] = dests.get(host, 0) + 1
    top_dests = sorted(dests.items(), key=lambda x: -x[1])[:10]
    clients = {}
    for e in entries:
        clients[e['email']] = clients.get(e['email'], 0) + 1
    return jsonify({
        'hourly': [{'hour': k, 'count': v} for k, v in sorted(hourly.items())],
        'protocols': protos,
        'top_destinations': [{'host': h, 'count': c} for h, c in top_dests],
        'per_client': [{'email': k, 'count': v} for k, v in sorted(clients.items(), key=lambda x: -x[1])],
    })


@app.route('/api/clients')
def api_clients():
    config = load_json(XRAY_CONFIG)
    db = load_json(CLIENTS_DB, {})
    traffic = client_traffic()

    clients = []
    for ib in config.get('inbounds', []):
        if ib.get('protocol') == 'vless':
            for c in ib.get('settings', {}).get('clients', []):
                cid = c['id']
                email = c.get('email', '')
                meta = db.get(cid, {})
                t = traffic.get(email, {'uplink': 0, 'downlink': 0})
                clients.append({
                    'id': cid,
                    'email': email,
                    'name': meta.get('name', email.split('@')[0] if email else cid[:8]),
                    'created': meta.get('created', '-'),
                    'up': t['uplink'],
                    'down': t['downlink'],
                    'link': vless_link(cid, meta.get('name', 'VPN')),
                })
            break

    return jsonify(clients)


@app.route('/api/clients', methods=['POST'])
@limiter.limit("10 per minute")
def api_add_client():
    data = request.get_json() or {}
    name = data.get('name', '').strip()
    if not name:
        return jsonify({'error': 'Name required'}), 400

    cid = str(uuid.uuid4())
    email = f"{re.sub(r'[^a-z0-9]', '-', name.lower())}@vpn"

    config = load_json(XRAY_CONFIG)
    for ib in config.get('inbounds', []):
        if ib.get('protocol') == 'vless':
            ib['settings']['clients'].append({
                'id': cid,
                'flow': 'xtls-rprx-vision',
                'email': email,
            })
            break

    save_json(XRAY_CONFIG, config)

    db = load_json(CLIENTS_DB, {})
    db[cid] = {
        'name': name,
        'email': email,
        'created': datetime.now().strftime('%Y-%m-%d %H:%M'),
    }
    save_json(CLIENTS_DB, db)
    restart_xray_bg()

    return jsonify({
        'id': cid,
        'name': name,
        'email': email,
        'link': vless_link(cid, name),
        'created': db[cid]['created'],
    })


@app.route('/api/clients/<cid>', methods=['DELETE'])
@limiter.limit("10 per minute")
def api_del_client(cid):
    config = load_json(XRAY_CONFIG)
    found = False
    for ib in config.get('inbounds', []):
        if ib.get('protocol') == 'vless':
            before = len(ib['settings']['clients'])
            ib['settings']['clients'] = [
                c for c in ib['settings']['clients'] if c['id'] != cid
            ]
            found = before > len(ib['settings']['clients'])
            break

    if not found:
        return jsonify({'error': 'Not found'}), 404

    save_json(XRAY_CONFIG, config)
    db = load_json(CLIENTS_DB, {})
    db.pop(cid, None)
    save_json(CLIENTS_DB, db)
    restart_xray_bg()

    return jsonify({'ok': True})


@app.route('/api/clients/<cid>/qr')
def api_qr(cid):
    db = load_json(CLIENTS_DB, {})
    meta = db.get(cid, {})
    link = vless_link(cid, meta.get('name', 'VPN'))
    svg = qr_svg(link)
    if svg:
        return Response(svg, mimetype='image/svg+xml')
    return jsonify({'error': 'QR failed'}), 500


@app.route('/api/netflow')
def api_netflow():
    return jsonify(parse_access_log(500))


@app.route('/api/xray/restart', methods=['POST'])
@limiter.limit("3 per minute")
def api_restart_xray():
    restart_xray()
    active = subprocess.run(
        ['systemctl', 'is-active', 'xray'],
        capture_output=True, text=True
    ).stdout.strip() == 'active'
    return jsonify({'ok': active})


if __name__ == '__main__':
    if not os.path.exists(CLIENTS_DB):
        save_json(CLIENTS_DB, {})
    threading.Thread(target=metrics_collector, daemon=True).start()
    app.run(host='0.0.0.0', port=8080, debug=False)
