"""Loopback launcher for the native Godot window. Godot owns input and demo files."""
import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from tankrl.runtime import v7_game_path
from tankrl.storage import data_root

SERVICE = "tankgame-v7-controls-launcher"
PLAY_PORT = 8780
ALLIES = ("sherman75", "t34_76")
STAGES = ("v7_1v2", "v7_1v3", "v7_1v6")
HTML = Path(__file__).with_name("tankrl") / "v7_play.html"


class PlayServer(ThreadingHTTPServer):
    allow_reuse_address = False
    allow_reuse_port = False

    def server_bind(self):
        if os.name == "nt":
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

    def __init__(self, port, demos_dir, godot=None, project=None):
        self.demos_dir = Path(demos_dir).resolve()
        self.godot = Path(godot or v7_game_path()).resolve()
        self.project = Path(project).resolve() if project else None
        self.game = None
        self.lock = threading.Lock()
        super().__init__(("127.0.0.1", port), PlayHandler)

    def state(self):
        running = self.game is not None and self.game.poll() is None
        return {"service": SERVICE, "running": running, "pid": self.game.pid if running else None,
                "counts": {t: sum(1 for _ in (self.demos_dir / t).glob("*.json")) for t in ALLIES}}

    def launch(self, body):
        tank, stage = body.get("tank"), body.get("stage")
        if (tank is not None or stage is not None) and (tank not in ALLIES or stage not in STAGES):
            raise ValueError("연합군 차종과 경기 인원을 선택하세요.")
        with self.lock:
            if self.game is not None and self.game.poll() is None:
                return self.state()
            if not self.godot.is_file():
                raise FileNotFoundError(f"Godot 게임 실행 파일을 찾을 수 없습니다. {self.godot}")
            cmd = [str(self.godot)]
            if self.project:
                cmd.extend(["--path", str(self.project)])
            cmd.extend(["--", "--v7-native", f"--demos-dir={self.demos_dir}"])
            if tank is not None:
                cmd.extend([f"--tank={tank}", f"--stage={stage}", f"--seed={secrets.randbits(31)}"])
            self.game = subprocess.Popen(cmd, cwd=self.project or self.godot.parent,
                                         stdin=subprocess.DEVNULL,
                                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            return self.state()


class PlayHandler(BaseHTTPRequestHandler):
    def reply(self, status, data, content_type="application/json; charset=utf-8"):
        body = data if isinstance(data, bytes) else json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        for name, value in (("Content-Type", content_type), ("Content-Length", str(len(body))),
                            ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")):
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/":
            self.reply(200, HTML.read_bytes(), "text/html; charset=utf-8")
        elif path == "/api/corpus":
            self.reply(200, self.server.state())
        else:
            self.reply(404, {"error": "없는 경로입니다."})

    def do_POST(self):
        host = self.headers.get("Host", "").lower()
        port = self.server.server_port
        if (host not in (f"localhost:{port}", f"127.0.0.1:{port}")
                or self.headers.get("Origin", f"http://{host}") != f"http://{host}"):
            return self.reply(403, {"error": "이 PC에서만 게임 창을 열 수 있습니다."})
        if self.headers.get_content_type() != "application/json":
            return self.reply(415, {"error": "JSON 요청을 사용하세요."})
        if self.path != "/api/launch":
            return self.reply(404, {"error": "Godot 플레이 실행 화면을 새로고침하세요."})
        try:
            size = int(self.headers.get("Content-Length", 0))
            if not 0 < size <= 2048:
                raise ValueError("요청 크기가 올바르지 않습니다.")
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict):
                raise ValueError("JSON 객체가 필요합니다.")
            self.reply(200, self.server.launch(body))
        except (TypeError, ValueError) as error:
            self.reply(400, {"error": str(error)})
        except OSError as error:
            self.reply(500, {"error": str(error)})

    def log_message(self, fmt, *args):
        if self.path != "/api/corpus":
            super().log_message(fmt, *args)


def main():
    parser = argparse.ArgumentParser(description="Godot V7 플레이 창 실행")
    parser.add_argument("--port", type=int, default=PLAY_PORT)
    parser.add_argument("--godot", type=Path, default=v7_game_path())
    parser.add_argument("--project", type=Path)
    parser.add_argument("--demos-dir", type=Path, default=data_root() / "v7_godot_control_demos")
    args = parser.parse_args()
    with PlayServer(args.port, args.demos_dir, args.godot, args.project) as server:
        print(f"http://127.0.0.1:{server.server_port}/", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
