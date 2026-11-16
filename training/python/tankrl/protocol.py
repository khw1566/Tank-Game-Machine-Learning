"""Godot training_env.gd 와 같은 메시지 틀: [u32 JSON 길이][JSON][u32 바이너리 길이][바이너리] (리틀엔디언)."""
import json
import socket
import struct

import numpy as np


def send(sock: socket.socket, header: dict, payload: bytes = b"") -> None:
    j = json.dumps(header, ensure_ascii=False).encode("utf-8")
    sock.sendall(struct.pack("<I", len(j)) + j + struct.pack("<I", len(payload)) + payload)


def _exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("godot closed the connection")
        buf.extend(chunk)
    return bytes(buf)


def recv(sock: socket.socket):
    (n,) = struct.unpack("<I", _exact(sock, 4))
    header = json.loads(_exact(sock, n).decode("utf-8"))
    (m,) = struct.unpack("<I", _exact(sock, 4))
    payload = _exact(sock, m) if m else b""
    return header, payload


def f32(payload: bytes, rows: int, cols: int) -> np.ndarray:
    a = np.frombuffer(payload, dtype="<f4")
    return a.reshape(rows, cols) if rows else a.reshape(0, cols)
