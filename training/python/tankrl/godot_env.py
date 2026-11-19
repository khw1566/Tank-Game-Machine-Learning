"""헤드리스 Godot 여러 개를 Stable-Baselines3 VecEnv 하나로 묶는다.

- Godot 프로세스 1개 = VecEnv 슬롯 1개 = 학습 전차 1대. 같은 경기 안의 다른 외부 조종 전차
  (같은 종류 아군 = 현재 정책 복사, 다른 종류 = 저장된 상대 정책)는 여기서 추론해 함께 보낸다.
- 행동을 모두 보낸 뒤 결과를 받으므로 Godot 프로세스들이 병렬로 돈다.
- 에피소드가 끝나면 커리큘럼에 결과를 알리고 곧바로 다음 설정으로 reset(자동 리셋).
- 모든 에피소드는 Godot 이 재현 파일(설정·시드·행동)로 저장하고, 여기서는 progress.csv 한 줄을 남긴다.
"""
from __future__ import annotations

import csv
import json
import os
import random
import socket
import subprocess
import sys
import time
from pathlib import Path

import gymnasium as gym
import numpy as np
from stable_baselines3.common.vec_env.base_vec_env import VecEnv

from . import protocol
from .curriculum import STAGE_IDS, Curriculum, lineup, make_config, tank_names
from . import curriculum_v4

SCENARIO_FIELDS = ["global_step", "uid", "tank", "stage", "variant", "goal", "success", "reason", "return", "duration_s",
                   "objective_reached", "status", "exposed_s", "hull_exposed_s", "turret_only_s", "hits_taken",
                   "pens_taken", "hits", "pens", "kills", "shots", "path_m", "best_objective_m", "zone_s",
                   "shaping_scale", "spawn_distance_m", "seed", "learner_policy", "reward_components", "relocated"]
from .pace import require_pace_support

PROGRESS_FIELDS = ["wall_time", "global_step", "env", "uid", "tank", "stage", "stage_idx", "current_stage",
                   "success", "reason", "winner", "return", "decisions", "duration_s", "spawn_distance_m",
                   "map_seed", "seed", "hits", "pens", "kills", "shots", "learner_policy", "opponents",
                   "episode_file", "replay_dir", "final_hash"]


def episode_counter(run_dir: Path, run_name: str, learner: str) -> int:
    """Include unfinished episodes saved on shutdown, so resume never reuses their filenames."""
    prefix = f'{run_name}_{learner}_'
    highest = 0
    paths = (run_dir / 'episodes').glob('env*/*.json')
    for path in paths:
        if path.stem.startswith(prefix):
            value = path.stem[len(prefix):].split('_', 1)[0]
            if value.isdigit():
                highest = max(highest, int(value))
    progress = run_dir / 'progress.csv'
    if progress.exists():
        with progress.open(newline='', encoding='utf-8-sig') as source:
            for row in csv.DictReader(source):
                uid = row.get('uid', '')
                if uid.startswith(prefix):
                    value = uid[len(prefix):].split('_', 1)[0]
                    if value.isdigit():
                        highest = max(highest, int(value))
    return highest


def godot_command(godot: str, project: str | None, port: int, env_id: int, log_dir: str,
                  extra: list[str] | None = None) -> list[str]:
    """godot = Godot 편집기 실행 파일(+ project 경로) 또는 내보낸 TankGame.exe(project 없이)."""
    cmd = [godot, "--headless", "--fixed-fps", "30"]
    if project:
        cmd += ["--path", project]
    cmd += ["--", "--train", f"--port={port}", f"--env-id={env_id}", f"--log-dir={log_dir}"]
    return cmd + (extra or [])


class GodotProcess:
    def __init__(self, godot: str, project: str | None, env_id: int, log_dir: str, timeout: float = 120.0,
                 quiet: bool = True, extra: list[str] | None = None):
        self.env_id = env_id
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        srv.settimeout(timeout)
        port = srv.getsockname()[1]
        self.cmd = godot_command(godot, project, port, env_id, log_dir, extra)
        out = subprocess.DEVNULL if quiet else None
        self.proc = subprocess.Popen(self.cmd, stdout=out, stderr=out)
        try:
            self.sock, _ = srv.accept()
        except socket.timeout as e:
            self.proc.kill()
            raise RuntimeError(f"Godot env {env_id} did not connect: {' '.join(self.cmd)}") from e
        finally:
            srv.close()
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.settimeout(None)
        self.hello, _ = protocol.recv(self.sock)
        self.obs_size = int(self.hello["obs_size"])
        self.act_size = int(self.hello["act_size"])

    def send(self, header: dict, payload: bytes = b"") -> None:
        protocol.send(self.sock, header, payload)

    def recv_obs(self):
        h, p = protocol.recv(self.sock)
        if h.get("type") != "obs":
            raise RuntimeError(f"env {self.env_id}: unexpected message {h}")
        n = len(h["agents"])
        return h, protocol.f32(p, n, self.obs_size)

    def close(self) -> None:
        try:
            self.send({"type": "close"})
        except OSError:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.sock.close()


class GodotVecEnv(VecEnv):
    def __init__(self, n_envs: int, godot: str, project: str | None, run_dir: str | Path,
                 learner: str, curriculum: Curriculum, opponents=None, seed: int = 0,
                 record_every: int = 200, map_repeat: int = 20, quiet: bool = True,
                 reward_overrides: dict | None = None, run_name: str = ""):
        self.run_dir = Path(run_dir).resolve()
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.learner = learner
        self.curriculum = curriculum
        self.opponents = opponents
        self.record_every = record_every
        self.map_repeat = map_repeat
        self.reward_overrides = reward_overrides
        self.run_name = run_name or self.run_dir.name
        self.rng = random.Random(seed)
        self.policy_fn = None          # 같은 종류 아군(copy) 추론: fn(obs[n, D]) -> actions[n, A]
        self.learner_version = ""
        self.global_step = 0
        self.episode_count = episode_counter(self.run_dir, self.run_name, learner)
        self.stage_ids = getattr(curriculum, "stage_ids", STAGE_IDS)
        obs_mode = getattr(curriculum, "obs", "")
        extra = [f"--obs={obs_mode}"] if obs_mode in ("situation", "situation_v3", "battle") else []
        self.procs = [GodotProcess(godot, project, i, str(self.run_dir), quiet=quiet, extra=extra) for i in range(n_envs)]
        p0 = self.procs[0]
        if extra and int(p0.hello.get("situation_obs_version", 0)) < 1:
            for p in self.procs:
                p.close()
            raise RuntimeError("커리큘럼 v4 는 상황 관측을 지원하는 최신 게임 실행 파일이 필요합니다. 게임을 다시 빌드하세요.")
        self.obs_labels = p0.hello.get("obs_labels", [])
        self.action_labels = p0.hello.get("action_labels", [])
        obs_space = gym.spaces.Box(-np.inf, np.inf, shape=(p0.obs_size,), dtype=np.float32)
        act_space = gym.spaces.Box(-1.0, 1.0, shape=(p0.act_size,), dtype=np.float32)
        super().__init__(n_envs, obs_space, act_space)
        self._maps = [None] * n_envs           # (stage_id, map_seed, 남은 횟수)
        self._ctx = [None] * n_envs            # 에피소드별 {roles, names, cfg, ...}
        self._last = [None] * n_envs           # 마지막 전체 관측 [n_ext, D]
        self._actions = None
        self._ret = np.zeros(n_envs)
        self._progress_path = self.run_dir / "progress.csv"
        new = not self._progress_path.exists()
        self._progress_f = open(self._progress_path, "a", newline="", encoding="utf-8")
        self._progress = csv.DictWriter(self._progress_f, fieldnames=PROGRESS_FIELDS)
        if new:
            self._progress.writeheader()
        self._curr_log = open(self.run_dir / "curriculum_log.jsonl", "a", encoding="utf-8")

    # ------------------------------------------------------------ 설정

    def _map_seed(self, i: int, stage: dict) -> int:
        cur = self._maps[i]
        if cur is None or cur[0] != stage["id"] or cur[2] <= 0:
            cur = [stage["id"], self.rng.choice(stage["map"]["seeds"]), self.map_repeat]
        cur[2] -= 1
        self._maps[i] = cur
        return cur[1]

    def _new_config_v4(self, i: int) -> dict:
        seed = self.rng.randrange(1, 2**31 - 1)
        stage, lu, extra = self.curriculum.build_episode(self.learner, self.rng, seed)
        names = tank_names(lu)
        self.episode_count += 1
        variant = extra["scenario"]["variant"]
        actual = extra["learner"]
        uid = f"{self.run_name}_{self.learner}_{self.episode_count:07d}_{stage['id']}_{variant}_{actual}"
        record = self.record_every > 0 and self.episode_count % self.record_every == 0
        meta = {"run": self.run_name, "learner_tank": actual, "model": self.learner, "policies": {names[0]: self.learner_version},
                "roles": {n: d["role"] for d, n in zip(lu, names)}, "global_step": self.global_step,
                "stage_idx": self.stage_ids.index(stage["id"]), "current_stage": self.curriculum.stage["id"],
                "curriculum_version": self.curriculum.version, "variant": variant,
                "shaping_scale": extra["reward"]["shaping_scale"]}
        cfg = curriculum_v4.make_config(stage, extra, actual, lu, seed, uid, record, meta, self.reward_overrides)
        cfg["curriculum_version"] = self.curriculum.version
        cfg["learner_team"] = lu[0]["team"]
        if int(cfg.get("reward", {}).get("attack_shaping_version", 0)) > int(self.procs[i].hello.get("attack_shaping_version", 0)):
            raise RuntimeError("조준·지근탄·아군 사격 보상 v1을 지원하는 최신 게임 실행 파일이 필요합니다")
        if extra.get("map_seed") is not None:
            # 고정 맵(최종 1대6): 맵 시드를 고정해 Godot 이 매 판 지형을 다시 만들지 않게 한다
            cfg["map"]["seed"] = int(extra["map_seed"])
        if int(extra.get("final_battle_version", 0)) > int(self.procs[i].hello.get("final_battle_version", 0)):
            raise RuntimeError("최종 1대6 맵·엄폐 보상을 지원하는 새 게임 실행 파일(build/TankGame_final.exe)이 필요합니다")
        if int(extra.get("v6_version", 0)) > int(self.procs[i].hello.get("v6_version", 0)):
            raise RuntimeError("V6(비례 보상·적 슬롯 6·balance v3)를 지원하는 새 게임 실행 파일이 필요합니다")
        if extra.get("balance_version"):
            cfg["balance_version"] = extra["balance_version"]
        ext = [k for k, item in enumerate(lu) if item["ctrl"] == "external"]
        opp = {}
        if extra.get("selfplay"):
            if int(self.procs[i].hello.get("battle_balance_version", 0)) < int(extra.get("balance_version", 1)):
                raise RuntimeError("새 포·장갑과 점진 보상을 지원하는 balance v2 게임 실행 파일이 필요합니다")
            if (int(self.procs[i].hello.get("battle_selfplay_version", 0)) < 1
                    or int(self.procs[i].hello.get("targeting_obs_version", 0)) < 1):
                raise RuntimeError("전투 자기 대전을 지원하는 최신 게임 소스로 실행하거나 다시 빌드하세요")
            for k in ext:
                if lu[k]["role"] == "opponent":
                    key = self.learner if self.learner == "shared" else lu[k]["type"]
                    opp[k] = self.opponents.pick_frozen(key, self.rng)
                    meta["policies"][names[k]] = opp[k]
        require_pace_support(self.procs[i].hello, cfg)
        if int(self.procs[i].hello.get("scenario_version", 0)) < 1:
            raise RuntimeError("커리큘럼 v4 상황 배치를 지원하지 않는 게임입니다. 게임을 다시 빌드하세요.")
        if (int(self.procs[i].hello.get("situation_obs_version", 0)) < 2
                or int(self.procs[i].hello.get("driving_reward_version", 0)) < 2):
            raise RuntimeError("주행 보상·장애물 관측 v2가 필요합니다. 최신 게임 실행 파일로 다시 빌드하세요.")
        if (int(self.procs[i].hello.get("threat_obs_version", 0)) < 1
                or int(self.procs[i].hello.get("projectile_version", 0)) < 1):
            raise RuntimeError("사격 감지·비행 포탄 관측이 필요합니다. 최신 게임 실행 파일로 다시 빌드하세요.")
        self._ctx[i] = {"cfg": cfg, "stage": stage, "roles": [lu[k]["role"] for k in ext],
                        "ext_names": [names[k] for k in ext], "opp_versions": [opp.get(k, "") for k in ext],
                        "learner_k": 0, "variant": variant, "tank": actual}
        return cfg

    def _new_config(self, i: int) -> dict:
        if hasattr(self.curriculum, "build_episode"):
            return self._new_config_v4(i)
        stage = self.curriculum.pick_stage()
        have = set(self.opponents.available()) if self.opponents else set()
        lu = lineup(stage, self.learner, self.rng, have)
        if stage['lineup'] in ('team_scripted', 'team_policy', 'final_policy'):
            raise RuntimeError('공유 정책 팀 학습은 중단되었습니다. 대시보드의 7개체 독립 학습 또는 train_individuals.py를 사용하세요.')
        names = tank_names(lu)
        self.episode_count += 1
        uid = f"{self.run_name}_{self.learner}_{self.episode_count:07d}_{stage['id']}"
        policies, opp = {}, {}
        for d, n in zip(lu, names):
            if d["role"] in ("learner", "copy"):
                policies[n] = self.learner_version
            elif d["role"] == "opponent":
                opp[n] = self.opponents.pick(d["type"], self.rng)
                policies[n] = self.opponents.describe(opp[n])
        seed = self.rng.randrange(1, 2**31 - 1)
        record = self.record_every > 0 and self.episode_count % self.record_every == 0
        meta = {"run": self.run_name, "learner_tank": self.learner, "policies": policies,
                "roles": {n: d["role"] for d, n in zip(lu, names)}, "global_step": self.global_step,
                "stage_idx": STAGE_IDS.index(stage["id"]), "current_stage": self.curriculum.stage["id"]}
        cfg = make_config(stage, self.learner, lu, seed, self._map_seed(i, stage), uid, record, meta,
                          self.reward_overrides)
        if int(self.procs[i].hello.get("spawn_safety_version", 0)) < 1:
            raise RuntimeError("안전 스폰·장애물 파괴를 지원하는 최신 게임 실행 파일로 다시 빌드하세요.")
        require_pace_support(self.procs[i].hello, cfg)
        if "terrain_course" in cfg and int(self.procs[i].hello.get("terrain_course_version", 0)) < cfg["terrain_course"]["version"]:
            raise RuntimeError("현재 지형주행 코스를 지원하지 않는 게임입니다. 최신 소스로 게임을 다시 빌드하세요.")
        ext = [k for k, d in enumerate(lu) if d["ctrl"] == "external"]
        roles = [lu[k]["role"] for k in ext]
        self._ctx[i] = {"cfg": cfg, "stage": stage, "roles": roles, "ext_names": [names[k] for k in ext],
                        "opp_versions": [opp.get(names[k], "") for k in ext],
                        "learner_k": roles.index("learner")}
        return cfg

    # ------------------------------------------------------------ VecEnv

    def reset(self):
        for i, p in enumerate(self.procs):
            p.send({"type": "reset", "config": self._new_config(i)})
        obs = np.zeros((self.num_envs, self.observation_space.shape[0]), dtype=np.float32)
        for i, p in enumerate(self.procs):
            _, o = p.recv_obs()
            self._last[i] = o
            obs[i] = o[self._ctx[i]["learner_k"]]
        self._ret[:] = 0
        return obs

    def step_async(self, actions):
        self._actions = np.asarray(actions, dtype=np.float32)

    def _all_actions(self, i: int, learner_action: np.ndarray) -> np.ndarray:
        ctx = self._ctx[i]
        o = self._last[i]
        acts = np.zeros((len(ctx["roles"]), self.action_space.shape[0]), dtype=np.float32)
        copies = [k for k, r in enumerate(ctx["roles"]) if r == "copy"]
        if copies and self.policy_fn is not None:
            acts[copies] = self.policy_fn(o[copies])
        for k, r in enumerate(ctx["roles"]):
            if r == "learner":
                acts[k] = learner_action
            elif r == "opponent":
                acts[k] = self.opponents.act(ctx["opp_versions"][k], o[k])
        return np.clip(acts, -1.0, 1.0)

    def _batched_actions(self) -> list[np.ndarray]:
        """모든 환경의 행동을 한 번에 만든다. 같은 상대 정책(버전)을 쓰는 전차들은 환경을 가로질러
        한 번의 forward 로 묶는다(1대6 × 환경 N개에서 개체별 predict 호출이 수집 시간의 절반 이상을 차지했다)."""
        dim = self.action_space.shape[0]
        out = []
        groups: dict[str, list[tuple[int, int]]] = {}
        copies: list[tuple[int, int]] = []
        for i in range(self.num_envs):
            ctx = self._ctx[i]
            acts = np.zeros((len(ctx["roles"]), dim), dtype=np.float32)
            for k, r in enumerate(ctx["roles"]):
                if r == "learner":
                    acts[k] = self._actions[i]
                elif r == "opponent":
                    groups.setdefault(ctx["opp_versions"][k], []).append((i, k))
                elif r == "copy":
                    copies.append((i, k))
            out.append(acts)
        if copies and self.policy_fn is not None:
            res = self.policy_fn(np.stack([self._last[i][k] for i, k in copies]))
            for (i, k), a in zip(copies, res):
                out[i][k] = a
        for version, members in groups.items():
            res = self.opponents.act_batch(version, np.stack([self._last[i][k] for i, k in members]))
            for (i, k), a in zip(members, res):
                out[i][k] = a
        return [np.clip(a, -1.0, 1.0) for a in out]

    def step_wait(self):
        n = self.num_envs
        for p, acts in zip(self.procs, self._batched_actions()):
            p.send({"type": "step"}, acts.astype("<f4").tobytes())
        obs = np.zeros((n, self.observation_space.shape[0]), dtype=np.float32)
        rews = np.zeros(n, dtype=np.float32)
        dones = np.zeros(n, dtype=bool)
        infos = [{} for _ in range(n)]
        finished = []
        for i, p in enumerate(self.procs):
            h, o = p.recv_obs()
            k = self._ctx[i]["learner_k"]
            self._last[i] = o
            obs[i] = o[k]
            rews[i] = h["agents"][k]["reward"]
            self._ret[i] += rews[i]
            if h["done"]:
                dones[i] = True
                ep = h.get("episode", {})
                infos[i] = {"terminal_observation": o[k].copy(), "episode": {"r": float(self._ret[i]),
                            "l": int(ep.get("decisions", 0)), "t": time.time()},
                            "stage": self._ctx[i]["stage"]["id"], "success": bool(ep.get("success", False)),
                            # 남은 시간이 관측에 있으므로 제한 시간은 과제의 일부다. 모든 종료를 진짜 종료로 다룬다.
                            "TimeLimit.truncated": False}
                self._log_episode(i, ep)
                finished.append(i)
        self.global_step += n
        if getattr(self.curriculum, "training_complete", False):
            # The callback stops collection now; never schedule another mastered trial.
            return obs, rews, dones, infos
        # 자동 리셋(병렬): 끝난 프로세스에 새 설정을 보내고 첫 관측을 받는다
        for i in finished:
            self.procs[i].send({"type": "reset", "config": self._new_config(i)})
        for i in finished:
            _, o = self.procs[i].recv_obs()
            self._last[i] = o
            obs[i] = o[self._ctx[i]["learner_k"]]
            self._ret[i] = 0
        return obs, rews, dones, infos

    def _log_episode(self, i: int, ep: dict) -> None:
        ctx = self._ctx[i]
        cfg = ctx["cfg"]
        stage_id = ctx["stage"]["id"]
        me = ctx["ext_names"][ctx["learner_k"]]
        tinfo = next((t for t in ep.get("tanks", []) if t["name"] == me), {})
        row = {"wall_time": round(time.time(), 2), "global_step": self.global_step, "env": i, "uid": cfg["uid"],
               "tank": ctx.get("tank", self.learner), "stage": stage_id,
               "stage_idx": self.stage_ids.index(stage_id) + getattr(self.curriculum, "dashboard_offset", 0),
               "current_stage": self.curriculum.stage["id"], "success": int(bool(ep.get("success"))),
               "reason": ep.get("reason", ""), "winner": ep.get("winner", -1),
               "return": round(float(self._ret[i]), 4), "decisions": ep.get("decisions", 0),
               "duration_s": ep.get("duration_s", 0), "spawn_distance_m": ep.get("spawn_distance_m", 0),
               "map_seed": cfg["map"]["seed"], "seed": cfg["seed"], "hits": tinfo.get("hits", 0),
               "pens": tinfo.get("pens", 0), "kills": tinfo.get("kills", 0), "shots": tinfo.get("shots", 0),
               "learner_policy": self.learner_version,
               "opponents": ";".join(self.opponents.describe(v) for v in ctx["opp_versions"] if v),
               "episode_file": ep.get("episode_file", ""), "replay_dir": ep.get("replay_dir", ""),
               "final_hash": ep.get("final_hash", "")}
        self._progress.writerow(row)
        self._progress_f.flush()
        terrain = ep.get("terrain", {})
        if terrain:
            path = self.run_dir / "terrain_progress.csv"
            fields = ["global_step", "uid", "course", "success", "reason", "initial_route_m",
                      "best_remaining_m", "path_m", "checkpoints", "checkpoints_total", "reward_components"]
            new_file = not path.exists()
            with path.open("a", newline="", encoding="utf-8") as output:
                writer = csv.DictWriter(output, fieldnames=fields)
                if new_file:
                    writer.writeheader()
                data = {key: terrain.get(key, "") for key in fields}
                data.update(global_step=self.global_step, uid=cfg["uid"], success=int(bool(ep.get("success"))),
                            reason=ep.get("reason", ""),
                            reward_components=json.dumps(terrain.get("reward_components", {})))
                writer.writerow(data)
        scenario = ep.get("scenario", {})
        if scenario:
            path = self.run_dir / "scenario_progress.csv"
            new_file = not path.exists()
            with path.open("a", newline="", encoding="utf-8") as output:
                writer = csv.DictWriter(output, fieldnames=SCENARIO_FIELDS)
                if new_file:
                    writer.writeheader()
                data = {key: scenario.get(key, "") for key in SCENARIO_FIELDS}
                data.update(global_step=self.global_step, uid=cfg["uid"], stage=stage_id, tank=ctx.get("tank", self.learner),
                            success=int(bool(ep.get("success"))), reason=ep.get("reason", ""),
                            duration_s=ep.get("duration_s", 0), spawn_distance_m=ep.get("spawn_distance_m", 0),
                            seed=cfg["seed"], learner_policy=self.learner_version,
                            hits=tinfo.get("hits", 0), pens=tinfo.get("pens", 0), kills=tinfo.get("kills", 0),
                            shots=tinfo.get("shots", 0),
                            reward_components=json.dumps(scenario.get("reward_components", {}), ensure_ascii=False),
                            relocated=json.dumps(scenario.get("relocated", [])))
                data["return"] = round(float(self._ret[i]), 4)
                writer.writerow(data)
            if hasattr(self.curriculum, "report_battle"):
                promo = self.curriculum.report_battle(stage_id, bool(ep.get("success")), self.global_step,
                                                      ctx["variant"], ctx["tank"], tinfo, ep)
            else:
                promo = self.curriculum.report(stage_id, bool(ep.get("success")), self.global_step,
                                               variant=scenario.get("variant", ""), learner=ctx.get("tank", ""))
        else:
            promo = self.curriculum.report(stage_id, bool(ep.get("success")), self.global_step,
                                           terrain.get("course", ""))
        if promo:
            self.log_stage_change(promo)

    def log_stage_change(self, promo: dict) -> None:
        """커리큘럼 단계 변경(자동 승급 또는 대시보드 수동 변경)을 curriculum_log.jsonl 에 남긴다."""
        if promo:
            promo["wall_time"] = round(time.time(), 2)
            promo["learner_policy"] = self.learner_version
            self._curr_log.write(json.dumps(promo, ensure_ascii=False) + "\n")
            self._curr_log.flush()
            print(f"[curriculum] {promo['tank']}: {promo['from']} → {promo['to']} "
                  f"(성공률 {promo['success_rate']:.2f}, {promo['episodes']} 에피소드, {promo['reason']})", flush=True)

    def close(self):
        for p in self.procs:
            p.close()
        self._progress_f.close()
        self._curr_log.close()

    # VecEnv 의 나머지 인터페이스(이 환경에서는 거의 쓰지 않음)
    def get_attr(self, attr_name, indices=None):
        return [getattr(self, attr_name)] * len(self._idx(indices))

    def set_attr(self, attr_name, value, indices=None):
        setattr(self, attr_name, value)

    def env_method(self, method_name, *args, indices=None, **kwargs):
        return [getattr(self, method_name)(*args, **kwargs) for _ in self._idx(indices)]

    def env_is_wrapped(self, wrapper_class, indices=None):
        return [False] * len(self._idx(indices))

    def seed(self, seed=None):
        if seed is not None:
            self.rng.seed(seed)
        return [seed] * self.num_envs

    def _idx(self, indices):
        if indices is None:
            return range(self.num_envs)
        return [indices] if isinstance(indices, int) else indices
