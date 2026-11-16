"""학습 중 제어·상태 파일(대시보드 ↔ train.py). 추가 패키지 없이 파일로만 주고받는다.

runs/<run>/control.jsonl   대시보드가 명령을 한 줄씩 덧붙인다. train.py 가 0.5초마다 새 줄만 읽어 실행.
   {"cmd": "pause"} / {"cmd": "resume"} / {"cmd": "stop"}            일시정지·재개·저장 후 종료
   {"cmd": "checkpoint"}                                             지금 체크포인트(step_*.zip) 저장
   {"cmd": "set_stage", "stage": "gunnery_static"}                   커리큘럼 단계 수동 변경(기록에 manual)
   {"cmd": "set", "record_every": 500, "review_prob": 0.1, "speed_cap": 0}   실행 중 바꿀 수 있는 값
runs/<run>/status.json     train.py 가 1초마다 덮어쓰는 현재 상태(단계, 스텝, 초당 스텝·에피소드, 일시정지 …)

speed_cap = 실시간 대비 최대 배속(0 = 무제한). 학습을 느리게 해서 PC 를 같이 쓰고 싶을 때.
"""
from __future__ import annotations

import collections
import json
import os
import time
from pathlib import Path

DECISION_S = 0.1   # 결정 1번 = 게임 0.1초(30Hz 물리 × 3틱)


def write_json_atomic(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    for _ in range(5):          # Windows: 대시보드가 읽는 중이면 잠깐 실패할 수 있다
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            time.sleep(0.02)


class TrainController:
    """train.py 콜백에서 매 스텝 tick() 을 부른다. 가볍게(0.5초마다만 파일 확인)."""

    def __init__(self, run_dir: Path, record_every: int = 200, review_prob: float = 0.1, speed_cap: float = 0.0):
        self.run_dir = Path(run_dir)
        self.control_path = self.run_dir / "control.jsonl"
        self.status_path = self.run_dir / "status.json"
        # 시작 전에 쌓인 명령은 무시(이전 실행의 stop 등)
        self._offset = self.control_path.stat().st_size if self.control_path.exists() else 0
        self.paused = False
        self.stop_requested = False
        self.record_every = record_every
        self.review_prob = review_prob
        self.speed_cap = float(speed_cap)
        self.phase = "starting"        # starting / collecting / updating / paused / saving / stopped
        self.info: dict = {}            # train.py 가 채우는 고정 정보(전차, 교대, 목표 스텝 …)
        self.last_save = {}
        self.last_steps = 0
        self._kept: dict = {}
        self.started = time.time()
        self._next_poll = 0.0
        self._next_status = 0.0
        self._rate = collections.deque(maxlen=60)   # (wall, steps, episodes)
        self._cap_t0 = None
        self.handlers = {}             # cmd -> fn(msg)  (train.py 가 등록: checkpoint, set_stage)
        self.env = None                # GodotVecEnv
        self.model = None
        self.curriculum = None
        self.log: collections.deque = collections.deque(maxlen=30)

    # ------------------------------------------------------------ 명령

    def poll(self, force: bool = False) -> None:
        now = time.time()
        if not force and now < self._next_poll:
            return
        self._next_poll = now + 0.5
        try:
            size = self.control_path.stat().st_size
        except FileNotFoundError:
            return
        if size < self._offset:
            self._offset = 0
        if size == self._offset:
            return
        with open(self.control_path, "rb") as f:
            f.seek(self._offset)
            data = f.read()
        end = data.rfind(b"\n") + 1     # 마지막 줄이 아직 덜 써졌으면 다음에
        self._offset += end
        for line in data[:end].decode("utf-8", "replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                self.apply(json.loads(line))
            except Exception as e:     # 잘못된 명령 하나로 학습이 죽지 않게
                self.note(f"명령 오류 {line!r}: {e}")

    def apply(self, msg: dict) -> None:
        cmd = msg.get("cmd", "")
        if cmd == "pause":
            self.paused = True
            self.note("일시정지")
        elif cmd == "resume":
            self.paused = False
            self.note("재개")
        elif cmd == "stop":
            self.stop_requested = True
            self.paused = False
            self.note("중지 요청(저장 후 종료)")
        elif cmd == "set":
            if "record_every" in msg:
                self.record_every = max(0, int(msg["record_every"]))
                if self.env is not None:
                    self.env.record_every = self.record_every
            if "review_prob" in msg:
                self.review_prob = min(1.0, max(0.0, float(msg["review_prob"])))
                if self.curriculum is not None:
                    self.curriculum.review_prob = self.review_prob
            if "speed_cap" in msg:
                self.speed_cap = max(0.0, float(msg["speed_cap"]))
                self._cap_t0 = None
            self.note("설정 변경 " + ", ".join(f"{k}={v}" for k, v in msg.items() if k not in ("cmd", "t")))
        elif cmd in self.handlers:
            self.handlers[cmd](msg)
        else:
            self.note(f"알 수 없는 명령 {cmd}")

    def note(self, text: str) -> None:
        self.log.append({"t": round(time.time(), 1), "text": text})
        print(f"[control] {text}", flush=True)

    # ------------------------------------------------------------ 콜백에서

    def tick(self, num_timesteps: int) -> bool:
        """매 스텝. False 를 돌려주면 학습을 멈춘다(저장은 train.py 가 finally 에서)."""
        self.poll()
        if self.paused:
            self.phase = "paused"
            self.write_status(num_timesteps, force=True)
            while self.paused and not self.stop_requested:
                time.sleep(0.25)
                self.poll(force=True)
                self.write_status(num_timesteps)
            self._cap_t0 = None
            self._rate.clear()
        if self.stop_requested:
            return False
        self.phase = "collecting"
        self._throttle(num_timesteps)
        self.write_status(num_timesteps)
        return True

    def _throttle(self, num_timesteps: int) -> None:
        if self.speed_cap <= 0:
            return
        now = time.time()
        if self._cap_t0 is None:
            self._cap_t0 = (now, num_timesteps)
            return
        t0, s0 = self._cap_t0
        # 결정 수 × 0.1초 = 게임 시간(모든 환경 합). 배속 = 게임 시간 / 실제 시간
        want = (num_timesteps - s0) * DECISION_S / self.speed_cap
        if want > now - t0:
            time.sleep(min(1.0, want - (now - t0)))

    def rates(self, num_timesteps: int, episodes: int) -> tuple[float, float]:
        now = time.time()
        self._rate.append((now, num_timesteps, episodes))
        while len(self._rate) > 2 and now - self._rate[0][0] > 15:
            self._rate.popleft()
        if len(self._rate) < 2:
            return 0.0, 0.0
        (t0, s0, e0), (t1, s1, e1) = self._rate[0], self._rate[-1]
        dt = max(t1 - t0, 1e-6)
        return (s1 - s0) / dt, (e1 - e0) / dt

    def write_status(self, num_timesteps: int | None, force: bool = False, phase: str | None = None) -> None:
        if num_timesteps is None:
            num_timesteps = self.last_steps
        self.last_steps = num_timesteps
        now = time.time()
        if phase:
            self.phase = phase
        if not force and now < self._next_status:
            return
        self._next_status = now + 1.0
        env, cur = self.env, self.curriculum
        episodes = env.episode_count if env is not None else 0
        sps, eps = self.rates(num_timesteps, episodes) if self.phase in ("collecting", "updating") else (0.0, 0.0)
        st = {
            "pid": os.getpid(), "updated": round(now, 2), "started": round(self.started, 1),
            "phase": self.phase, "paused": self.paused, "stop_requested": self.stop_requested,
            "num_timesteps": int(num_timesteps), "episodes": episodes,
            "steps_per_s": round(sps, 1), "episodes_per_s": round(eps, 3),
            "realtime_x": round(sps * DECISION_S, 1),
            "record_every": self.record_every, "review_prob": self.review_prob, "speed_cap": self.speed_cap,
            "last_save": self.last_save, "log": list(self.log), **self.info,
        }
        if env is not None:
            st["n_envs"] = env.num_envs
            st["learner_policy"] = env.learner_version
        if self.model is not None:
            from .runtime import gpu_memory
            st["gpu_memory"] = gpu_memory(str(getattr(self.model, "training_device", self.model.device)))
        if cur is not None:
            p = cur.stage.get("promote") or {}
            st["curriculum"] = {"stage_idx": cur.stage_idx, "stage": cur.stage["id"],
                                "episodes_in_stage": cur.episodes_in_stage,
                                "success_rate": round(cur.success_rate(cur.stage["id"], p.get("window", 100)), 4),
                                "window": p.get("window"), "threshold": p.get("threshold"),
                                "min_episodes": p.get("min_episodes"), "max_episodes": p.get("max_episodes")}
        # 중지된 뒤에도 마지막 단계·환경 수가 보이게
        for k in ("n_envs", "learner_policy", "curriculum"):
            if k in st:
                self._kept[k] = st[k]
            elif k in self._kept:
                st[k] = self._kept[k]
        write_json_atomic(self.status_path, st)
