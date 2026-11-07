#!/usr/bin/env python3
"""Exercise the shipped AppImage and its real WebView login flow under Xvfb."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


PAGE_READY = threading.Event()
NATIVE_READY = threading.Event()
PAGE = b"""<!doctype html><html><head><title>AppImageWebViewReady</title></head>
<body><h1>AppImage WebView passed</h1><p>Local page rendered by WebKitGTK.</p>
<script>window.addEventListener('load', () => fetch('/ready', {method: 'POST'}));</script>
</body></html>"""
SOURCE = """class AppImageSmoke extends ComicSource {
    name = 'Smoke Test';
    key = 'appimage_smoke';
    version = '1.0.0';
    minAppVersion = '1.0.0';
    comic = {};
    search = {};
    account = {
        logout() {},
        loginWithWebview: {
            url: 'http://127.0.0.1:5173/webview',
            checkStatus(url, title) {
                if (title.includes('AppImageWebViewReady')) {
                    Network.get('http://127.0.0.1:5173/native-ready');
                }
                return false;
            }
        }
    };
}
"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/native-ready':
            NATIVE_READY.set()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(PAGE)

    def do_POST(self):
        if self.path == '/ready' and 'AppleWebKit' in self.headers.get('User-Agent', ''):
            PAGE_READY.set()
        self.send_response(204)
        self.end_headers()


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def main():
    appimage = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', 5173), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='venerax-smoke-') as tmp:
        root = Path(tmp)
        # Reading this profile also checks that bundled GIO preserves the app ID.
        data = root / 'data/io.github.kyosee.venera'
        (data / 'comic_source').mkdir(parents=True)
        (data / 'comic_source/appimage_smoke.js').write_text(SOURCE)
        (data / 'appdata.json').write_text(json.dumps({
            'settings': {
                'language': 'en-US', 'initialPage': '0',
                'requireDisclaimerConsent': False, 'disclaimerConsented': True,
                'checkUpdateOnStart': False, 'proxy': 'direct',
                'comicSourceListUrl': '', 'comicSourceLibraries': [],
                'homeSections': [{'id': 'comicSource', 'visible': True}],
            },
            'searchHistory': [],
        }))
        runtime = root / 'runtime'
        runtime.mkdir(mode=0o700)
        env = dict(os.environ, XDG_DATA_HOME=str(root / 'data'),
                   XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
                   XDG_RUNTIME_DIR=str(runtime), APPIMAGE_EXTRACT_AND_RUN='1',
                   GDK_BACKEND='x11', GDK_SCALE='1', LIBGL_ALWAYS_SOFTWARE='1')
        wm = subprocess.Popen(['openbox'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        process = None
        try:
            with (output / 'app.log').open('w') as log:
                process = subprocess.Popen([str(appimage)], env=env, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                deadline = time.monotonic() + 90
                window = ''
                while time.monotonic() < deadline:
                    result = subprocess.run(
                        ['xdotool', 'search', '--onlyvisible', '--name', '^VeneraX$'],
                        text=True, capture_output=True,
                    )
                    if result.returncode == 0:
                        window = result.stdout.splitlines()[0]
                        break
                    if process.poll() is not None:
                        raise RuntimeError(f'AppImage exited with {process.returncode}')
                    time.sleep(1)
                if not window:
                    raise RuntimeError('AppImage did not show its main window')
                run('xdotool', 'windowsize', '--sync', window, '1000', '800')
                run('xdotool', 'windowmove', '--sync', window, '30', '30')
                time.sleep(5)
                # Coordinates are relative to the fixed 1000x800 English window.
                clicks = (
                    ('Comic Source', 300, 136), ('Smoke Test', 300, 416),
                    ('Log in', 300, 494), ('Login with webview', 536, 562),
                )
                for number, (label, x, y) in enumerate(clicks, 1):
                    if process.poll() is not None:
                        raise RuntimeError(f'AppImage exited with {process.returncode}')
                    run('scrot', '--overwrite', str(output / f'{number:02d}-before-click.png'))
                    run('xdotool', 'mousemove', '--window', window, str(x), str(y), 'click', '1')
                    print(f'Clicked {label}', flush=True)
                    time.sleep(2)
                if not PAGE_READY.wait(60) or not NATIVE_READY.wait(30):
                    raise RuntimeError('WebView page JavaScript or native title callback did not complete')
                run('scrot', '--overwrite', str(output / '05-webview.png'))
                processes = run('ps', '-eo', 'pid,args')
                (output / 'processes.txt').write_text(processes + '\n')
                if 'WebKitWebProcess' not in processes or 'WebKitNetworkProcess' not in processes:
                    raise RuntimeError('Missing live WebKit child processes')
                if process.poll() is not None:
                    raise RuntimeError('AppImage exited after WebView load')
                (output / 'result.json').write_text(json.dumps({
                    'appimage': appimage.name, 'gui': True, 'webview_javascript': True,
                    'native_title_callback': True,
                }, indent=2) + '\n')
                print('PASS: AppImage GUI, WebView JavaScript and native title callback', flush=True)
        finally:
            subprocess.run(['scrot', '--overwrite', str(output / 'final.png')], check=False)
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            wm.terminate()
            wm.wait(timeout=15)
            server.shutdown()
            shutil.copytree(root / 'data', output / 'profile', dirs_exist_ok=True)
            print((output / 'app.log').read_text(errors='replace'), flush=True)
            for path in data.rglob('*.log'):
                print(f'{path.name}:\n{path.read_text(errors="replace")}', flush=True)


if __name__ == '__main__':
    main()
