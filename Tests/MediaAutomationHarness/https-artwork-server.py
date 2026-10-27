#!/usr/bin/env python3
"""Owned, ephemeral TLS fixture. No global trust or personal application state."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import ssl
import subprocess
import time


def certificate(directory):
    def openssl(*arguments):
        subprocess.run(['/usr/bin/openssl', *arguments], cwd=directory, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key',
            '-out', 'ca.pem', '-days', '1', '-subj', '/CN=Owned Artwork Test CA',
            '-addext', 'basicConstraints=critical,CA:TRUE')
    openssl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'server.key',
            '-out', 'server.csr', '-subj', '/CN=localhost')
    (directory / 'server.ext').write_text(
        'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:localhost\n'
        'extendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n')
    openssl('x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key',
            '-CAcreateserial', '-out', 'server.pem', '-days', '1', '-extfile', 'server.ext')
    openssl('x509', '-in', 'ca.pem', '-outform', 'der', '-out', 'ca.der')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    arguments = parser.parse_args()
    directory = arguments.directory
    directory.mkdir(parents=True, exist_ok=True)
    certificate(directory)
    png = (Path(__file__).parent / 'Fixtures/owned-artwork.png').read_bytes()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def do_GET(self):
            with (directory / 'requests.log').open('a') as output:
                output.write(f'{self.path} cookie={self.headers.get("Cookie", "")}\n')
            status, body = 200, png
            if self.path == '/slow':
                time.sleep(2)
            if self.path.startswith('/redirect'):
                target = {'/redirect': '/image', '/redirect-http': 'http://localhost/image',
                          '/redirect-credentials': 'https://user:secret@artwork.example.com/image'}[self.path]
                self.send_response(302)
                self.send_header('Location', target)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            if self.path == '/error':
                status, body = 503, b'Owned failure'
            if self.path == '/invalid':
                body = b'Not an image'
            self.send_response(status)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Set-Cookie', 'owned=must-not-persist; Secure')
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass  # Expected peer cancellation; recorded request remains observable.

        def log_message(self, format, *arguments):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(directory / 'server.pem', directory / 'server.key')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    (directory / 'server.json').write_text(json.dumps({'url': f'https://localhost:{server.server_port}',
                                                       'ca': str(directory / 'ca.der')}))
    server.serve_forever()


if __name__ == '__main__':
    main()
