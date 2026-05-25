#!/usr/bin/env python3
"""
server.py — camrecord web server
Serves viewer.html + recordings + live streams + disk stats.
Usage: python3 server.py /home/lawl/camara/config.json
"""
import sys, os, json, subprocess, threading, mimetypes, shutil
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, unquote

CONFIG_PATH  = sys.argv[1] if len(sys.argv) > 1 else '/home/lawl/camara/config.json'
CAMARA_DIR   = os.path.dirname(os.path.abspath(CONFIG_PATH))  # /home/lawl/camara
PORT         = 8080

with open(CONFIG_PATH) as f:
    config = json.load(f)

RECORDINGS   = config['output_base']   # /bigboi/camara
CAMERAS      = {c['name'].lower(): c for c in config['cameras']}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        code = str(args[1]) if len(args) > 1 else ''
        if code not in ('200', '206', '304'):
            super().log_message(fmt, *args)

    def do_GET(self):
        p    = urlparse(self.path)
        path = unquote(p.path)

        # ── viewer.html ──────────────────────────────────────────────────────
        if path in ('/', '/viewer.html'):
            self.serve_file(os.path.join(CAMARA_DIR, 'viewer.html'))
            return

        # ── disk stats (computed on demand) ─────────────────────────────────
        if path == '/api/disk':
            try:
                total, used, free = shutil.disk_usage(RECORDINGS)
                pct = round(used / total * 100, 1)
                self.json_resp({
                    'used_pct': pct,
                    'total':    fmt_bytes(total),
                    'used':     fmt_bytes(used),
                    'free':     fmt_bytes(free),
                })
            except Exception as e:
                self.json_resp({'error': str(e)})
            return

        # ── camera list ──────────────────────────────────────────────────────
        if path == '/api/cameras':
            self.json_resp({'cameras': list(CAMERAS.keys())})
            return

        # ── live stream ──────────────────────────────────────────────────────
        if path.startswith('/stream/'):
            cam_name = path[8:].strip('/')
            if cam_name not in CAMERAS:
                self.send_error(404)
                return
            self.stream_camera(cam_name)
            return

        # ── recordings (everything else) ─────────────────────────────────────
        # map URL path directly into RECORDINGS dir
        full = os.path.normpath(os.path.join(RECORDINGS, path.lstrip('/')))

        # security: must stay inside RECORDINGS
        if not full.startswith(os.path.realpath(RECORDINGS)):
            self.send_error(403)
            return

        if os.path.isdir(full):
            self.serve_dir(full, path if path.endswith('/') else path + '/')
            return

        if os.path.isfile(full):
            self.serve_file(full)
            return

        self.send_error(404)

    def serve_file(self, full_path):
        if not os.path.isfile(full_path):
            self.send_error(404)
            return
        mime, _ = mimetypes.guess_type(full_path)
        mime = mime or 'application/octet-stream'
        size = os.path.getsize(full_path)
        try:
            with open(full_path, 'rb') as f:
                self.send_response(200)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', size)
                self.send_header('Accept-Ranges', 'bytes')
                self.end_headers()
                shutil.copyfileobj(f, self.wfile)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except PermissionError:
            self.send_error(403)

    def serve_dir(self, full_path, url_path):
        try:
            entries = sorted(os.listdir(full_path))
        except PermissionError:
            self.send_error(403)
            return
        lines = [
            '<!DOCTYPE HTML><html><head><meta charset="utf-8">',
            f'<title>Directory listing for {url_path}</title></head>',
            f'<body><h1>Directory listing for {url_path}</h1><hr><ul>'
        ]
        if url_path != '/':
            lines.append('<li><a href="../">../</a></li>')
        for e in entries:
            full_e   = os.path.join(full_path, e)
            is_dir   = os.path.isdir(full_e)
            display  = e + '/' if is_dir else e
            href     = e + '/' if is_dir else e
            lines.append(f'<li><a href="{href}">{display}</a></li>')
        lines += ['</ul><hr></body></html>']
        body = '\n'.join(lines).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def stream_camera(self, cam_name):
        url = CAMERAS[cam_name]['url']
        cmd = [
            'ffmpeg', '-loglevel', 'error',
            '-rtsp_transport', 'tcp',
            '-i', url,
            '-c:v', 'copy', '-an',
            '-f', 'mp4',
            '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
            '-frag_duration', '500000',
            '-reset_timestamps', '1',
            'pipe:1'
        ]
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        print(f'[live/{cam_name}] pid={proc.pid}')
        try:
            while True:
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            proc.kill()
            proc.wait()
            print(f'[live/{cam_name}] stopped')

    def json_resp(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)


def fmt_bytes(n):
    for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
        if n < 1024:
            return f'{n:.1f} {unit}'
        n /= 1024
    return f'{n:.1f} PB'


class ThreadedServer(HTTPServer):
    def process_request(self, request, client_address):
        t = threading.Thread(target=self.finish_request, args=(request, client_address))
        t.daemon = True
        t.start()


print(f'camrecord server → http://0.0.0.0:{PORT}')
print(f'recordings → {RECORDINGS}')
print(f'cameras    → {", ".join(CAMERAS.keys())}')
ThreadedServer(('0.0.0.0', PORT), Handler).serve_forever()
