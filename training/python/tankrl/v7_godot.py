"""Gym interface to the V7 native Godot scene. Gameplay runs inside the game executable."""
from __future__ import annotations

import json
import hashlib
from pathlib import Path
import socket
import subprocess
import time

import gymnasium as gym
import numpy as np

from .runtime import v7_game_path


PROTOCOL = "tankgame-v7-godot-v3"
DEMO_FORMAT = "tankgame-v7-godot-demo-v3"
PHYSICS_HZ = 30
REPEAT = 3
ALLIES = ("sherman75", "t34_76")
TEAM_STAGES = ("v7_1v2", "v7_1v3", "v7_1v6")
SCHEMA_PATH = Path(__file__).resolve().parents[2] / "v7_native_schema.json"
SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
CATALOG_BYTES = SCHEMA_PATH.with_name("v7_training_layouts.json").read_bytes()
CATALOG = json.loads(CATALOG_BYTES)
CATALOG_SHA256 = hashlib.sha256(CATALOG_BYTES).hexdigest()
OBS_LABELS = SCHEMA["obs_labels"]
ACTION_LABELS = SCHEMA["action_labels"]


def expected_layout(tank, stage, seed):
    source_stage = "v6_1v1" if stage in ("v7_target", "v7_side") else stage.replace("v7_", "v6_")
    layouts = CATALOG["layouts"][source_stage][tank]
    row = layouts[seed % len(layouts)]
    return {key: row[key] for key in ("map_id", "source_stage", "source_seed", "layout_id")}


class NativeGodotEnv(gym.Env):
    """One engine instance per environment. Reset reuses it across episodes and stages."""

    def __init__(self, tank, stage_id, godot=None, project=None):
        super().__init__()
        self.tank = tank
        self.stage_id = stage_id
        self.godot = str(godot or v7_game_path())
        self.project = project
        self.observation_space = gym.spaces.Box(-1, 1, (len(OBS_LABELS),), np.float32)
        self.action_space = gym.spaces.Box(-1, 1, (len(ACTION_LABELS),), np.float32)
        self.process = self.connection = self.reader = None
        self.hello = {}
        self.finished = True

    def connect(self):
        if self.connection is not None:
            return
        try:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen(1)
                listener.settimeout(0.25)
                port = listener.getsockname()[1]
                cmd = [self.godot, "--headless", "--fixed-fps", str(PHYSICS_HZ)]
                if self.project:
                    cmd.extend(("--path", str(self.project)))
                cmd.extend(("--", "--v7-native", f"--port={port}"))
                self.process = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                deadline = time.monotonic() + 20
                while True:
                    try:
                        self.connection, _ = listener.accept()
                        break
                    except TimeoutError:
                        if self.process.poll() is not None:
                            raise RuntimeError(f"Godot exited before V7 startup ({self.process.returncode}): {self.godot}")
                        if time.monotonic() >= deadline:
                            raise RuntimeError(f"Godot V7 연결 시간 초과. 실행 파일 빌드를 확인하세요: {self.godot}")
            self.connection.settimeout(30)
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.reader = self.connection.makefile("rb")
            self.hello = self._receive("hello")
            if (self.hello.get("protocol") != PROTOCOL or self.hello.get("physics_hz") != PHYSICS_HZ
                    or self.hello.get("repeat") != REPEAT or self.hello.get("obs_labels") != OBS_LABELS
                    or self.hello.get("action_labels") != ACTION_LABELS
                    or self.hello.get("layout_catalog_sha256") != CATALOG_SHA256):
                raise ValueError("Godot 실행 파일의 V7 맵·배치 또는 조작 규격이 현재 학습기와 다릅니다")
        except BaseException:
            self.close()
            raise

    def _send(self, message):
        self.connection.sendall(json.dumps(message, separators=(",", ":"), allow_nan=False).encode() + b"\n")

    def _receive(self, kind):
        line = self.reader.readline(1 << 20)
        if not line.endswith(b"\n"):
            raise ConnectionError(f"Godot 연결이 정상적인 {kind} 메시지를 보내지 않았습니다")
        data = json.loads(line)
        if data.get("type") != kind:
            raise RuntimeError(f"Godot {kind} 요청 실패: {data}")
        return data

    def _observation(self, reply):
        observation = np.asarray(reply["obs"], dtype=np.float32)
        if not self.observation_space.contains(observation):
            raise ValueError("Godot 관측값 크기 또는 범위가 V7 입력 규격과 다릅니다")
        return observation

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        self.connect()
        native_seed = int(seed) if seed is not None else int(self.np_random.integers(0, 2**32))
        self._send({"type": "reset", "tank": self.tank, "stage": self.stage_id, "seed": native_seed})
        reply = self._receive("observation")
        if reply["info"].get("layout") != expected_layout(self.tank, self.stage_id, native_seed):
            raise ValueError("Godot이 다른 맵·전차 배치를 불러왔습니다")
        self.finished = False
        return self._observation(reply), reply["info"]

    def step(self, action):
        if self.finished:
            raise gym.error.ResetNeeded("reset()을 호출한 뒤 조작하세요")
        action = np.asarray(action, dtype=np.float32)
        if not self.action_space.contains(action):
            raise ValueError("Godot에 보낼 조작값이 행동 규격과 다릅니다")
        self._send({"type": "step", "action": action.tolist()})
        reply = self._receive("transition")
        terminated, truncated = reply["terminated"], reply["truncated"]
        self.finished = terminated or truncated
        return self._observation(reply), float(reply["reward"]), terminated, truncated, reply["info"]

    def close(self):
        if self.connection is not None:
            try:
                self._send({"type": "close"})
            except OSError:
                pass
            if self.reader is not None:
                self.reader.close()
            self.connection.close()
            self.reader = self.connection = None
        if self.process is not None:
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            self.process = None
        self.finished = True
