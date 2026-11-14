#!/usr/bin/env python3
"""Portable Hermes Desktop build/deploy service (LAN only).

GET  /api/desktop-update/manifest?tag=X   -> manifest.json (latest if no tag)
GET  /api/desktop-update/artifact?tag=X   -> app.asar
POST /api/desktop-update/build?tag=X      -> start build+deploy pipeline
GET  /api/desktop-update/status           -> pipeline state + log tail

Config via environment (see systemd/hermes-desktop-update.service and
config.env.example): ART, BUILD_SH, DEPLOY_SH, PORT.
"""
import json
import os
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
ART = Path(os.environ.get('ART', Path.home() / 'hermes-desktop-artifacts'))
BUILD_SH = os.environ.get('BUILD_SH', str(HERE / 'build-hermes-desktop-asar.sh'))
DEPLOY_SH = os.environ.get('DEPLOY_SH', str(HERE / 'deploy-hermes-desktop-asar.sh'))
PORT = int(os.environ.get('PORT', '4011'))

_lock = threading.Lock()
_state = {'state': 'idle', 'tag': None, 'log': [], 'deployed': False, 'error': None}


def semver_key(tag: str):
    m = re.match(r'v?(\d+)\.(\d+)\.(\d+)$', tag)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else (0, 0, 0)


def latest_manifest():
    best = None
    for d in sorted(ART.iterdir()):
        mf = d / 'manifest.json'
        if d.is_dir() and (d / 'app.asar').is_file() and mf.is_file():
            if best is None or semver_key(d.name) > semver_key(best):
                best = d.name
    return json.loads((ART / best / 'manifest.json').read_text()) if best else None


def append_log(text: str):
    tail = [ln for ln in text.strip().splitlines() if ln.strip()][-5:]
    if tail:
        _state['log'] = (_state['log'] + tail)[-50:]


def run_pipeline(tag: str | None):
    try:
        _state.update(state='building', tag=tag, deployed=False, error=None, log=[])
        args = [BUILD_SH] + ([tag] if tag else [])
        p = subprocess.run(args, capture_output=True, text=True, timeout=1800)
        append_log(p.stdout)
        if p.returncode != 0:
            _state.update(state='error', error=(p.stderr or p.stdout)[-500:])
            return
        # resolve the tag the build produced
        mf = latest_manifest()
        built_tag = mf['tag'] if mf else tag
        _state.update(state='deploying', tag=built_tag)
        d = subprocess.run([DEPLOY_SH, built_tag], capture_output=True, text=True, timeout=600)
        append_log(d.stdout)
        if d.returncode != 0:
            _state.update(state='error', error=(d.stderr or d.stdout)[-500:])
            return
        _state.update(state='done', deployed=True)
    except Exception as exc:  # noqa: BLE001
        _state.update(state='error', error=str(exc)[-500:])


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype='application/json'):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        if isinstance(body, bytes):
            self.wfile.write(body)
        elif isinstance(body, str):
            self.wfile.write(body.encode())
        else:
            self.wfile.write(json.dumps(body).encode())

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == '/api/desktop-update/manifest':
            tag = (q.get('tag') or [None])[0]
            try:
                mf = json.loads((ART / tag / 'manifest.json').read_text()) if tag else latest_manifest()
                if not mf:
                    self._send(404, {'error': 'no artifacts'})
                else:
                    self._send(200, mf)
            except (FileNotFoundError, OSError):
                self._send(404, {'error': 'not found'})
        elif u.path == '/api/desktop-update/artifact':
            tag = (q.get('tag') or [None])[0]
            try:
                mf = json.loads((ART / tag / 'manifest.json').read_text()) if tag else latest_manifest()
                data = (ART / (mf['tag'] if mf else '') / 'app.asar').read_bytes()
                self._send(200, data, ctype='application/octet-stream')
            except (FileNotFoundError, OSError, TypeError, KeyError):
                self._send(404, {'error': 'not found'})
        elif u.path == '/api/desktop-update/status':
            with _lock:
                self._send(200, _state)
        else:
            self._send(404, {'error': 'not found'})

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path != '/api/desktop-update/build':
            self._send(404, {'error': 'not found'})
            return
        with _lock:
            if _state['state'] in ('building', 'deploying'):
                self._send(409, _state)
                return
            tag = (q.get('tag') or [None])[0]
            threading.Thread(target=run_pipeline, args=(tag,), daemon=True).start()
            self._send(202, {'started': True, 'tag': tag})

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
