"""V7 arcade board. Coordinates, badges, pulses and race clocks are game units."""
from __future__ import annotations

from dataclasses import dataclass
import math

import gymnasium as gym
import numpy as np


DEMO_FORMAT = "tankgame-v7-arcade-demo-v1"
ALLIES = ("sherman75", "t34_76")
TEAM_STAGES = ("v7_1v2", "v7_1v3", "v7_1v6")
# Rival count, rings needed and deadline in turns.
ROUNDS = {
    "v7_target": (0, 3, 64),
    "v7_side": (0, 3, 96),
    "v7_1v1": (1, 3, 96),
    "v7_1v2": (2, 4, 112),
    "v7_1v3": (3, 5, 128),
    "v7_1v6": (6, 6, 144),
}
ACTION_LABELS = ["move_x", "move_y", "cursor_x", "cursor_y", "tag", "shield"]
OBS_LABELS = [
    "avatar_x", "avatar_y", "cursor_x", "cursor_y", "ring_x", "ring_y", "gate_x", "gate_y",
    "gate_required", "gate_open", "score_fraction", "time_left", "rival_count",
    "shield_enabled", "pulse_due_in", "shield_held", "shield_budget_left",
    "allied_team", "ally_count", "team_score_fraction",
] + [f"tile_{n}_{field}" for n in range(1, 7)
     for field in ("ally", "visible", "x", "y", "side_face", "side_seen", "race_progress")]


@dataclass
class BoardTile:
    x: float
    y: float
    face_phase: int
    turns_per_point: int
    race_phase: int
    ally: bool

    def side_face(self, turn: int) -> bool:
        return (turn + self.face_phase) % 10 >= 5

    def race_points(self, turn: int) -> int:
        return (turn + self.race_phase) // self.turns_per_point

    def board_position(self, turn: int):
        if not self.ally:
            return self.x, self.y
        # Teammates carry a relay chip across their short lane. Each delivers one point.
        progress = min(1.0, (turn + self.race_phase) / self.turns_per_point)
        return self.x + (0.5 if self.x < 0 else -0.5) * progress, self.y


class ArcadeEnv(gym.Env):
    metadata = {"render_modes": ["rgb_array"], "render_fps": 10}
    MOVE_RATE = 0.17
    CURSOR_RATE = 0.30
    GATE_RADIUS = 0.20
    RING_RADIUS = 0.20
    VIEW_RADIUS = 0.62
    SHIELD_BUDGET = 0.90
    PULSE_INTERVAL = 11

    def __init__(self, tank: str, stage_id: str, render_mode: str | None = None, *, allied_team=False):
        super().__init__()
        if stage_id not in ROUNDS:
            raise ValueError(f"Unknown arcade stage {stage_id!r}")
        if render_mode not in (None, "rgb_array"):
            raise ValueError(f"Unknown render mode {render_mode!r}")
        if allied_team and tank not in ALLIES:
            raise ValueError("The allied team avatar must be sherman75 or t34_76.")
        self.tank = tank
        self.stage_id = stage_id
        self._play_allied = bool(allied_team)
        self.render_mode = render_mode
        self.action_space = gym.spaces.Box(-1, 1, shape=(len(ACTION_LABELS),), dtype=np.float32)
        self.observation_space = gym.spaces.Box(-1, 1, shape=(len(OBS_LABELS),), dtype=np.float32)
        self.finished = True

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        seats, self.goal, self.limit = ROUNDS[self.stage_id]
        self.allied_team = self._play_allied and seats > 1
        self.ally_count = seats - 1 if self.allied_team else 0
        self.rival_count = 1 if self.allied_team else seats
        self.gated = self.stage_id != "v7_target"
        self.shield_enabled = self.gated and self.tank == "tiger1"
        self.avatar = self.np_random.uniform(-0.15, 0.15, size=2)
        self.cursor = np.zeros(2)
        self.turn = self.score = self.gates = 0
        self.block_count = self.reflect_count = 0
        self.shield_paid = 0.0
        self.shield_held = False
        self.pulse_turn = int(self.np_random.integers(5, self.PULSE_INTERVAL + 1))
        self.seen: set[int] = set()
        # In the side tutorial the single tile displays its badge without entering the race.
        self.tiles = [
            BoardTile(float(self.np_random.uniform(-0.82, 0.82)),
                      float(self.np_random.uniform(-0.72, 0.72)),
                      int(self.np_random.integers(5)), int(self.np_random.integers(15, 22)),
                      int(self.np_random.integers(5)), self.allied_team and i > 0)
            for i in range(max(seats, int(self.gated)))
        ]
        self.gate_side = int(self.np_random.choice((-1, 1)))
        self.ring_side = int(self.np_random.choice((-1, 1)))
        self.finished = False
        self._next_round()
        return self._observation(), self._info({}, [])

    def _next_round(self):
        self.ring = np.array([self.ring_side * self.np_random.uniform(0.32, 0.83),
                              self.np_random.uniform(-0.76, 0.76)])
        self.gate = (np.array([self.gate_side * self.np_random.uniform(0.65, 0.85),
                               self.np_random.uniform(-0.68, 0.68)]) if self.gated else np.zeros(2))
        self.gate_side *= -1
        self.ring_side *= -1
        self.gate_open = not self.gated
        self.gate_best = self.gate_initial = math.dist(self.avatar, self.gate)
        self.cursor_best = self.cursor_initial = math.dist(self.cursor, self.ring)

    def _visible(self, tile):
        return tile.ally or math.dist(self.avatar, (tile.x, tile.y)) <= self.VIEW_RADIUS

    def _lead(self):
        return max((tile.race_points(self.turn) for tile in self.tiles[:self.rival_count]), default=0)

    def _team_points(self):
        return self.score + sum(min(1, tile.race_points(self.turn)) for tile in self.tiles if tile.ally)

    def _observation(self):
        values = [
            *self.avatar, *self.cursor, *self.ring, *self.gate, self.gated, self.gate_open,
            self.score / self.goal, 1 - self.turn / self.limit, self.rival_count / 6,
            self.shield_enabled,
            (self.pulse_turn - self.turn) / self.PULSE_INTERVAL if self.shield_enabled else 0,
            self.shield_held, 1 - self.shield_paid / self.SHIELD_BUDGET if self.shield_enabled else 0,
            self.allied_team, self.ally_count / 5, self._team_points() / (self.goal + self.ally_count),
        ]
        for i, tile in enumerate(self.tiles):
            visible = self._visible(tile)
            x, y = tile.board_position(self.turn)
            progress = min(1.0, tile.race_points(self.turn) / self.goal) if i < self.rival_count else 0
            if tile.ally:
                progress = min(1.0, (self.turn + tile.race_phase) / tile.turns_per_point)
            values.extend([tile.ally, visible, x if visible else 0, y if visible else 0,
                           visible and not tile.ally and tile.side_face(self.turn), i in self.seen, progress])
        values.extend([0.0] * (len(OBS_LABELS) - len(values)))
        return np.asarray(values, dtype=np.float32)

    def _info(self, parts, new_seen):
        return {"stage": self.stage_id, "reward_components": parts, "score": self.score,
                "goal": self.goal, "rival_score": self._lead(), "side_checkpoints": self.gates,
                "team_score": self._team_points(), "team_goal": self.goal + self.ally_count,
                "allied_team": self.allied_team, "allies": self.ally_count, "rivals": self.rival_count,
                "side_seen_count": len(self.seen), "side_seen_new_ids": new_seen,
                "shield_blocks": self.block_count, "shield_reflects": self.reflect_count,
                "elapsed_steps": self.turn}

    def _shield(self, pressed, parts):
        if not self.shield_enabled:
            return
        if self.turn == self.pulse_turn:
            if pressed:
                # An already held button catches the pulse. A new press on its beat reflects it.
                if self.shield_held:
                    self.block_count += 1
                    component, points = "shield_block", 0.15
                else:
                    self.reflect_count += 1
                    component, points = "shield_reflect", 0.35
                paid = min(points, max(0.0, self.SHIELD_BUDGET - self.shield_paid))
                parts[component] = paid
                self.shield_paid += paid
            self.pulse_turn += self.PULSE_INTERVAL
        self.shield_held = pressed

    def step(self, action):
        if self.finished:
            raise gym.error.ResetNeeded("Call reset() before starting another arcade round.")
        action = np.asarray(action, dtype=np.float32)
        if action.shape != self.action_space.shape or not np.isfinite(action).all():
            raise ValueError("Arcade action requires six finite controls.")
        action = np.clip(action, -1, 1)
        self.avatar = np.clip(self.avatar + self.MOVE_RATE * action[:2], -1, 1)
        self.cursor = np.clip(self.cursor + self.CURSOR_RATE * action[2:4], -1, 1)
        self.turn += 1

        new_seen = [i for i, tile in enumerate(self.tiles) if not tile.ally and i not in self.seen
                    and self._visible(tile) and tile.side_face(self.turn)]
        self.seen.update(new_seen)
        parts = {"time": -0.015, "side_seen": 0.5 * len(new_seen)}
        self._shield(action[5] > 0.5, parts)

        if not self.gate_open:
            distance = math.dist(self.avatar, self.gate)
            if distance < self.gate_best:
                parts["side_progress"] = 0.7 * (self.gate_best - distance) / self.gate_initial
                self.gate_best = distance
            if distance <= self.GATE_RADIUS:
                self.gate_open = True
                self.gates += 1
                parts["side_checkpoint"] = 4.0
        distance = math.dist(self.cursor, self.ring)
        if distance < self.cursor_best:
            parts["cursor_progress"] = 0.35 * (self.cursor_best - distance) / self.cursor_initial
            self.cursor_best = distance
        if self.score < self.goal and self.gate_open and action[4] > 0.5 and distance <= self.RING_RADIUS:
            self.score += 1
            parts["ring_tag"] = 1.0

        won = self._team_points() >= self.goal + self.ally_count
        rival_won = self._lead() >= self.goal
        terminated = won or rival_won
        truncated = not terminated and self.turn >= self.limit
        self.finished = terminated or truncated
        info = self._info(parts, new_seen)
        if self.finished:
            success = won and not rival_won
            parts["success" if success else "loss"] = 4.0 if success else -2.0
            info["is_success"] = success
            info["reason"] = ("race_tie" if won and rival_won else "rings_complete" if won else
                              "rival_finished" if rival_won else "time_limit")
        elif "ring_tag" in parts and self.score < self.goal:
            self._next_round()
        return self._observation(), float(sum(parts.values())), terminated, truncated, info

    def render(self):
        """Draw the arcade board and its observation radius on a 128-pixel canvas."""
        if self.render_mode != "rgb_array":
            return None
        board = np.full((128, 128, 3), (24, 31, 44), dtype=np.uint8)
        board[::16, :] = (32, 43, 58)
        board[:, ::16] = (32, 43, 58)
        yy, xx = np.ogrid[:128, :128]

        def pixel(point):
            return tuple(round((coordinate + 1) * 61) + 3 for coordinate in point)

        def outline(point, radius, color, dotted=False):
            x, y = pixel(point)
            distance_sq = (xx - x) ** 2 + (yy - y) ** 2
            band = (distance_sq <= (radius + 0.5)**2) & (distance_sq >= (radius - 0.5)**2)
            if dotted:
                band &= (xx + yy) % 4 < 2
            board[band] = color

        def stamp(point, rows, palette):
            x, y = pixel(point)
            left, top = x - len(rows[0]) // 2, y - len(rows) // 2
            for dy, row in enumerate(rows):
                for dx, mark in enumerate(row):
                    if mark != " " and 0 <= left + dx < 128 and 0 <= top + dy < 128:
                        board[top + dy, left + dx] = palette[mark]

        # Tall twin treads indicate the player's top-down token. The rival switches
        # between a front badge with two lamps and a broadside with striped wheels.
        player = ("   L   ", "D  L  D", "LBLBBBL", "DBLLLBD", "DBBLBBD", "LBBBBBL", "DD   DD")
        front = ("   L   ", "  BBB  ", "DBBLBBD", "DLLBLLD", "DBBBBBD", "DD   DD")
        side = ("  LLL    ", " BBBB LL ", "DBBBBBBBD", "DBLBLBLBD", " DDDDDDD ")
        friend = ("   L   ", " DLBLD ", "DBBBBBD", "DBLBLBD", " DDDDD ")

        if self.tiles:
            outline(self.avatar, self.VIEW_RADIUS * 61, (51, 84, 92), dotted=True)
        if self.gated:
            gate_color = (96, 208, 136) if self.gate_open else (167, 136, 248)
            outline(self.gate, self.GATE_RADIUS * 61, gate_color, dotted=True)
            stamp(self.gate, ("G   G", " G G ", "  G  ", " G G ", "G   G"), {"G": gate_color})
        for tile in self.tiles:
            if not self._visible(tile):
                continue
            pos = tile.board_position(self.turn)
            if tile.ally:
                stamp(pos, friend, {"B": (125, 211, 93), "L": (214, 248, 165), "D": (54, 99, 47)})
            elif tile.side_face(self.turn):
                stamp(pos, side, {"B": (248, 181, 38), "L": (255, 226, 128), "D": (134, 82, 36)})
            else:
                stamp(pos, front, {"B": (111, 163, 223), "L": (206, 229, 252), "D": (54, 82, 119)})
        stamp(self.avatar, player, {"B": (90, 213, 190), "L": (182, 255, 233), "D": (40, 118, 117)})
        outline(self.ring, 5, (247, 134, 104))
        stamp(self.cursor, ("   W   ", "   W   ", "       ", "WW W WW", "       ", "   W   ", "   W   "),
              {"W": (255, 255, 255)})
        return board
