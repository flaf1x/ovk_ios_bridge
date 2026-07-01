#!/usr/bin/env python3
import base64
import hashlib
import http.server
import os
import subprocess
import sys
import urllib.parse

HOST = "0.0.0.0"
PORT = 8765
CACHE = os.path.expanduser("~/.cache/openvk-video-proxy")


def decode_url(value):
    value += "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value).decode("utf-8")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        try:
            encoded = self.path.split("?", 1)[0].removeprefix("/video/")
            source = decode_url(encoded)
            parsed = urllib.parse.urlparse(source)
            if parsed.scheme != "https" or parsed.hostname != "cdn.openvk.org":
                self.send_error(403)
                return

            os.makedirs(CACHE, exist_ok=True)
            target = os.path.join(CACHE, hashlib.sha256(source.encode()).hexdigest() + ".mp4")
            if not os.path.exists(target):
                temporary = target + ".tmp.mp4"
                subprocess.run([
                    "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", source,
                    "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy",
                    "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
                    temporary,
                ], check=True)
                os.replace(temporary, target)

            size = os.path.getsize(target)
            start, end = 0, size - 1
            range_header = self.headers.get("Range")
            if range_header and range_header.startswith("bytes="):
                bounds = range_header[6:].split("-", 1)
                start = int(bounds[0] or 0)
                if bounds[1]:
                    end = min(int(bounds[1]), end)
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            else:
                self.send_response(200)
            length = end - start + 1
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            self.end_headers()
            with open(target, "rb") as media:
                media.seek(start)
                remaining = length
                while remaining:
                    chunk = media.read(min(256 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            print(error, file=sys.stderr, flush=True)
            self.send_error(502)

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


http.server.ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
