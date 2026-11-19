"""학습 중 제어·상태 파일(대시보드 ↔ train.py). 추가 패키지 없이 파일로만 주고받는다.

runs/<run>/control.jsonl   대시보드가 명령을 한 줄씩 덧붙인다(id·t 포함). 감시 스레드가 0.25초마다 새 줄을 읽어
                           바로 "받음"을 status.json 의 acks 에 남기고, 일시정지·재개·중지·설정 변경은 즉시 적용한다.
                           체크포인트·단계 변경은 학습 스레드가 다음 스텝에 적용(PPO 갱신 중이면 갱신이 끝난 뒤)한다.
   {"cmd": "pause"} / {"cmd": "resume"} / {"cmd": "stop"}            일시정지·재개·저장 후 종료
   {"cmd": "checkpoint"}                                             지금 체크포인트(step_*.zip) 저장
   {"cmd": "set_stage", "stage": "gunnery_static"}                   커리큘럼 단계 수동 변경(기록에 manual)
   {"cmd": "set", "record_every": 500, "review_prob": 0.1, "speed_cap": 0}   실행 중 바꿀 수 있는 값
runs/<run>/status.json     1초마다 덮어쓰는 현재 상태(단계, 스텝, 초당 스텝·에피소드, 일시정지, 명령 처리 결과 acks …).
                           PPO 갱신·게임 실행처럼 학습 스레드가 오래 멈추는 동안에도 감시 스레드가 계속 갱신한다.

speed_cap = 실시간 대비 최대 배속(0 = 무제한). 학습을 느리게 해서 PC 를 같이 쓰고 싶을 때.
"""
from __future__ import annotations

import collections
import json
import os
import threading
import time
import tempfile
from pathlib import Path

DECISION_S = 0.1   # 결정 1번 = 게임 0.1초(30Hz 물리 × 3틱)
LAUNCH_ENV = "TANKRL_LAUNCH_T"   # 대시보드가 학습을 띄운 시각. 이후에 보낸 명령은 준비 중에 보냈어도 실행한다
IMMEDIATE = ("pause", "resume", "stop", "set")   # 감시 스레드에서 바로 적용(값만 바꾸는 명령)


def write_json_atomic(path: Path, data: dict) -> None:
    fd, name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    tmp = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(data, output, ensure_ascii=False)
        # Windows: 대시보드가 같은 파일을 읽는 순간에는 교체가 거부된다. 최대 약 3초 동안 다시 시도한다.
        for attempt in range(60):
            try:
                os.replace(tmp, path)
                return
            except PermissionError:
                if attempt == 59:
                    raise
                time.sleep(.05)
    finally:
        tmp.unlink(missing_ok=True)


class TrainController:
    """train.py 콜백에서 매 스텝 tick() 을 부른다. 가볍게(0.5초마다만 파일 확인)."""

    def __init__(self, run_dir: Path, record_every: int = 200, review_prob: float = 0.1, speed_cap: float = 0.0,
                 watch: bool = True):
        self.run_dir = Path(run_dir)
        self.control_path = self.run_dir / "control.jsonl"
        self.status_path = self.run_dir / "status.json"
        self.started = time.time()
        # 이전 실행에 보낸 명령(예전 stop 등)은 무시하고, 대시보드가 이 프로세스를 띄운 뒤 보낸 명령은 준비 중이었어도 실행한다
        try:
            self.launch_t = float(os.environ.get(LAUNCH_ENV, ""))
        except ValueError:
            self.launch_t = None
        self._offset = 0 if self.launch_t else (self.control_path.stat().st_size if self.control_path.exists() else 0)
        if self.launch_t is None:
            self.launch_t = self.started
        self.paused = False
        self.stop_requested = False
        self.record_every = record_every
        self.review_prob = review_prob
        self.speed_cap = float(speed_cap)
        self.phase = "starting"        # starting / collecting / updating / paused / saving / stopped
        self.phase_since = self.started
        self.step_text = "학습 프로그램 준비"   # 시작 중 지금 하는 일(대시보드 진행 표시)
        self.info: dict = {}            # train.py 가 채우는 고정 정보(전차, 교대, 목표 스텝 …)
        self.last_save = {}
        self.last_steps = 0
        self._kept: dict = {}
        self._last_full: dict = {}
        self._next_poll = 0.0
        self._next_status = 0.0
        self._last_write = 0.0
        self._rate = collections.deque(maxlen=60)   # (wall, steps, episodes)
        self._cap_t0 = None
        self.handlers = {}             # cmd -> fn(msg)  (train.py 가 등록: checkpoint, set_stage)
        self.env = None                # GodotVecEnv
        self.model = None
        self.curriculum = None
        self.log: collections.deque = collections.deque(maxlen=30)
        self.acks: collections.deque = collections.deque(maxlen=20)   # 명령 처리 결과(대시보드 피드백)
        self._queue: collections.deque = collections.deque()          # 학습 스레드에서 실행할 명령
        self._io = threading.RLock()
        self._dirty = False
        self._stop_watch = threading.Event()
        self._watcher = None
        if watch:
            self._watcher = threading.Thread(target=self._watch, name="control-watch", daemon=True)
            self._watcher.start()

    # ------------------------------------------------------------ 명령

    def _watch(self) -> None:
        """학습 스레드가 PPO 갱신·게임 실행·저장으로 오래 멈춰도 명령을 받고 상태를 갱신한다."""
        while not self._stop_watch.wait(0.25):
            try:
                self.read_commands()
                if self._dirty or time.time() - self._last_write > 1.0:
                    self.write_status(None, force=True, light=True)
            except Exception as e:      # 표시용 스레드: 학습을 죽이지 않는다
                print(f"[control] 감시 스레드 오류: {e}", flush=True)

    def close(self) -> None:
        self._stop_watch.set()

    def read_commands(self) -> None:
        with self._io:
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
                msg = json.loads(line)
            except ValueError as e:
                self.note(f"명령 오류 {line!r}: {e}")
                continue
            if float(msg.get("t") or 0) < self.launch_t - 1.0:
                continue                # 이 프로세스가 뜨기 전 명령
            if msg.get("cmd") in IMMEDIATE or msg.get("cmd") not in self.handlers and msg.get("cmd") not in ("checkpoint", "set_stage"):
                self.apply(msg)
            else:
                wait = {"updating": "PPO 갱신이 끝나면", "saving": "저장이 끝나면", "starting": "학습이 시작되면",
                        "paused": "곧"}.get(self.phase, "다음 스텝에")
                self.ack(msg, "received", f"받음 — {wait} 적용")
                self._queue.append(msg)

    def poll(self, force: bool = False) -> None:
        """학습 스레드: 대기 중인 명령(체크포인트·단계 변경)을 실행한다."""
        if self._watcher is None:
            now = time.time()
            if force or now >= self._next_poll:
                self._next_poll = now + 0.5
                self.read_commands()
        while self._queue:
            self.apply(self._queue.popleft())

    def ack(self, msg: dict, state: str, text: str) -> None:
        if not msg.get("id"):
            return
        with self._io:
            for a in self.acks:
                if a["id"] == msg["id"]:
                    a.update(state=state, text=text, t=round(time.time(), 2))
                    break
            else:
                self.acks.append({"id": msg["id"], "cmd": msg.get("cmd", ""), "state": state, "text": text,
                                  "t": round(time.time(), 2)})
            self._dirty = True

    def apply(self, msg: dict) -> None:
        cmd = msg.get("cmd", "")
        try:
            text = self._apply(cmd, msg)
        except Exception as e:     # 잘못된 명령 하나로 학습이 죽지 않게
            self.note(f"명령 오류 {cmd}: {e}")
            self.ack(msg, "error", f"실패: {e}")
            return
        self.ack(msg, "error" if text.startswith("알 수 없는") else "applied", text)

    def _apply(self, cmd: str, msg: dict) -> str:
        if cmd == "pause":
            self.paused = True
            text = "일시정지" + (" (PPO 갱신이 끝나면 멈춤)" if self.phase == "updating" else "")
        elif cmd == "resume":
            self.paused = False
            text = "재개"
        elif cmd == "stop":
            self.stop_requested = True
            self.paused = False
            text = "중지 요청(저장 후 종료)"
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
            text = "설정 변경 " + ", ".join(f"{k}={v}" for k, v in msg.items() if k not in ("cmd", "t", "id"))
        elif cmd in self.handlers:
            self.handlers[cmd](msg)
            text = {"checkpoint": "체크포인트 저장 완료", "set_stage": f"단계 변경 → {msg.get('stage', '')}"}.get(cmd, cmd + " 완료")
        else:
            text = f"알 수 없는 명령 {cmd}"
        self.note(text)
        return text

    def note(self, text: str) -> None:
        self.log.append({"t": round(time.time(), 1), "text": text})
        print(f"[control] {text}", flush=True)

    def step(self, text: str) -> None:
        """시작·전환 중 지금 하는 일을 대시보드에 바로 보인다."""
        self.step_text = text
        self.write_status(None, force=True)

    # ------------------------------------------------------------ 콜백에서

    def tick(self, num_timesteps: int) -> bool:
        """매 스텝. False 를 돌려주면 학습을 멈춘다(저장은 train.py 가 finally 에서)."""
        self.poll()
        if self.paused:
            self.write_status(num_timesteps, force=True, phase="paused")
            while self.paused and not self.stop_requested:
                time.sleep(0.25)
                self.poll(force=True)
                self.write_status(num_timesteps)
            self._cap_t0 = None
            self._rate.clear()
        if self.stop_requested:
            return False
        if self.phase != "collecting":
            self.write_status(num_timesteps, force=True, phase="collecting")
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

    def write_status(self, num_timesteps: int | None, force: bool = False, phase: str | None = None,
                     light: bool = False) -> None:
        """light = 감시 스레드의 갱신: 학습 스레드가 바꾸는 객체(env·커리큘럼)는 읽지 않고 마지막 값을 다시 쓴다."""
        if phase and phase != self.phase:
            self.phase = phase
            self.phase_since = time.time()
            if phase == "collecting":
                self.step_text = ""
        if num_timesteps is not None:
            self.last_steps = num_timesteps
        now = time.time()
        if not force and now < self._next_status:
            return
        with self._io:
            if light:
                st = dict(self._last_full) if self._last_full else {"num_timesteps": int(self.last_steps), **self.info, **self._kept}
                if self.phase not in ("collecting", "updating"):
                    st.update(steps_per_s=0.0, episodes_per_s=0.0, realtime_x=0.0)
            else:
                st = self._full_status(now)
                self._last_full = st
            st.update(self._live_fields(now))
            self._next_status = now + 1.0
            self._last_write = now
            self._dirty = False
            try:
                write_json_atomic(self.status_path, st)
            except PermissionError:
                # 상태 표시용 파일일 뿐이다. 읽는 쪽이 오래 잡고 있어도 학습을 멈추지 않고 다음 갱신 때 다시 쓴다.
                print("[status] status.json 이 사용 중이라 이번 갱신을 건너뜁니다", flush=True)

    def _live_fields(self, now: float) -> dict:
        """감시 스레드도 매번 새로 쓰는 값."""
        return {"pid": os.getpid(), "updated": round(now, 2), "started": round(self.started, 1),
                "phase": self.phase, "phase_since": round(self.phase_since, 1), "step": self.step_text,
                "paused": self.paused, "stop_requested": self.stop_requested,
                "record_every": self.record_every, "review_prob": self.review_prob, "speed_cap": self.speed_cap,
                "last_save": self.last_save, "log": list(self.log), "acks": list(self.acks),
                "pending_commands": len(self._queue)}

    def _full_status(self, now: float) -> dict:
        num_timesteps = self.last_steps
        env, cur = self.env, self.curriculum
        episodes = env.episode_count if env is not None else 0
        sps, eps = self.rates(num_timesteps, episodes) if self.phase in ("collecting", "updating") else (0.0, 0.0)
        st = {
            "num_timesteps": int(num_timesteps), "episodes": episodes,
            "steps_per_s": round(sps, 1), "episodes_per_s": round(eps, 3),
            "realtime_x": round(sps * DECISION_S, 1), **self.info,
        }
        if env is not None:
            st["n_envs"] = env.num_envs
            st["learner_policy"] = env.learner_version
        if self.model is not None:
            from .runtime import gpu_memory
            st["gpu_memory"] = gpu_memory(str(getattr(self.model, "training_device", self.model.device)))
        if cur is not None:
            p = cur.stage.get("promote") or {}
            st["curriculum"] = {"stage_idx": cur.stage_idx + getattr(cur, "dashboard_offset", 0), "stage": cur.stage["id"],
                                "variant_success": cur.variant_rates(cur.stage["id"], p.get("window", 100)) if hasattr(cur, "variant_rates") else None,
                                "episodes_in_stage": cur.episodes_in_stage,
                                "success_rate": round(cur.success_rate(cur.stage["id"], p.get("window", 100)), 4),
                                "window": p.get("window"), "threshold": p.get("threshold"),
                                "min_episodes": p.get("min_episodes"), "max_episodes": p.get("max_episodes")}
            if hasattr(cur, "combat_metrics"):
                st["curriculum"]["battle"] = {"min_steps": cur.stage["min_steps"],
                                               "steps_in_stage": max(0, int(num_timesteps) - cur.stage_start_step),
                                               "metrics": cur.combat_metrics()}
            if hasattr(cur, "pending_pairs"):
                st["curriculum"]["pending_pairs"] = [cur.key(v, t) for v, t in cur.pending_pairs(cur.stage)]
                st["curriculum"]["mastered_pairs"] = sorted(cur.mastered[cur.stage["id"]])
                st["curriculum"]["assessment_version"] = cur.assessment_version
            if cur.stage["id"] == "drive_terrain":
                from .terrain import COURSES, WINDOW
                index = next((i for i, c in enumerate(COURSES) if c["id"] == cur.terrain_fixed), cur.terrain_idx)
                course = COURSES[index]
                results = cur.terrain_results[course["id"]]
                st["curriculum"]["terrain"] = {
                    "course": course["id"], "label": course["label"], "index": index, "fixed": bool(cur.terrain_fixed),
                    "count": len(COURSES), "episodes": len(results), "window": WINDOW,
                    "success_rate": round(sum(results) / len(results), 4) if results else 0.0,
                    "threshold": course["threshold"],
                    "courses": [{"id": c["id"], "label": c["label"],
                                 "episodes": len(cur.terrain_results[c["id"]]),
                                 "success_rate": (sum(cur.terrain_results[c["id"]]) / len(cur.terrain_results[c["id"]])
                                                  if cur.terrain_results[c["id"]] else 0.0)} for c in COURSES]}
        # 중지된 뒤에도 마지막 단계·환경 수가 보이게
        for k in ("n_envs", "learner_policy", "curriculum"):
            if k in st:
                self._kept[k] = st[k]
            elif k in self._kept:
                st[k] = self._kept[k]
        return st
