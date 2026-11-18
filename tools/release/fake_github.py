"""A local fake GitHub for the launcher's update checks (never used by players).

    python tools/release/fake_github.py WORLD_DIR PORT

The launcher is pointed at it with TN_UPLINK_TEST_SERVER=http://127.0.0.1:PORT (only a loopback address is taken):
https://raw.githubusercontent.com/X -> /raw/X, https://codeload.github.com/X -> /codeload/X, https://api.github.com/X ->
/api/X, https://github.com/X -> /gh/X (and python.org / pypi). WORLD_DIR/files/<that path> is served as it is (a file
named <path>.json or the path itself). WORLD_DIR/faults.json, read at each request, breaks chosen requests:
    [{"match": "codeload/", "mode": "truncate"}, ...]   modes: 404 403 429 500 slow (waits 60 s) truncate (half the
    body, then closes) drop (closes without answering) corrupt (a byte changed)
Every request is written to WORLD_DIR/requests.log.
"""
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WORLD, PORT = sys.argv[1], int(sys.argv[2])
lock = threading.Lock()


def fault(path):
    try:
        rules = json.load(open(os.path.join(WORLD, 'faults.json'), encoding='utf-8'))
    except (OSError, ValueError):
        return None
    for r in rules:
        if r.get('match', '') in path:
            return r.get('mode')
    return None


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def note(self, code, extra=''):
        with lock:
            with open(os.path.join(WORLD, 'requests.log'), 'a', encoding='utf-8') as f:
                f.write('%s %s %s %s %s\n' % (time.strftime('%H:%M:%S'), self.command, self.path, code, extra))

    def do_GET(self):
        path = self.path.split('?')[0].lstrip('/')
        mode = fault(path)
        if mode == 'drop':
            self.note('drop')
            self.close_connection = True
            self.connection.close()
            return
        if mode == 'slow':
            self.note('slow')
            time.sleep(60)
        if mode in ('404', '403', '429', '500'):
            self.note(mode)
            body = b'{"message": "fake %s"}' % mode.encode()
            self.send_response(int(mode))
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        f = os.path.normpath(os.path.join(WORLD, 'files', path))
        if not f.startswith(os.path.normpath(os.path.join(WORLD, 'files'))) or not os.path.isfile(f):
            self.note(404)
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        data = open(f, 'rb').read()
        if mode == 'corrupt' and data:
            i = len(data) // 2
            data = data[:i] + bytes([data[i] ^ 0x55]) + data[i + 1:]
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Content-Type', 'application/json' if f.endswith('.json') else 'application/octet-stream')
        self.end_headers()
        if mode == 'truncate':
            self.wfile.write(data[:len(data) // 2])
            self.wfile.flush()
            self.note(200, 'truncated %d of %d' % (len(data) // 2, len(data)))
            self.close_connection = True
            self.connection.shutdown(2)
            return
        self.wfile.write(data)
        self.note(200, '%d bytes%s' % (len(data), ' corrupt' if mode == 'corrupt' else ''))


if __name__ == '__main__':
    srv = ThreadingHTTPServer(('127.0.0.1', PORT), H)
    srv.daemon_threads = True
    print('fake GitHub on 127.0.0.1:%d, world %s' % (PORT, WORLD), flush=True)
    srv.serve_forever()
