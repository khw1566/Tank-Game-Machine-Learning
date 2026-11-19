"""Read-only objective labels shared by the dashboard and exported reports."""
import colorsys
import hashlib
import json
import re
from pathlib import Path

from .terrain import COURSES

COURSE_LABELS = {c['id']: c['label'] for c in COURSES}
PALETTE = ['#2563eb', '#dc2626', '#15803d', '#c26708', '#9333ea', '#008b8b',
           '#c02679', '#687b14', '#795548', '#4f46e5', '#00875a', '#c2410c', '#64748b']
COURSE_COLORS = dict(zip(['approach', 'turn_gentle', 'turn_wide', 'parking', 'slope',
                         'low_step', 'one_tree', 'detour', 'gate_wide', 'gates', 'grove', 'rough', 'mixed'], PALETTE))


def episode_config(path):
    # Episode actions and observations can be large; decode only the config object.
    decoder = json.JSONDecoder()
    with path.open(encoding='utf-8') as source:
        text = ''
        while chunk := source.read(65536):
            text += chunk
            match = re.search(r'"config"\s*:\s*', text)
            if match:
                try:
                    return decoder.raw_decode(text, match.end())[0]
                except ValueError:
                    pass
    return {}


# 커리큘럼 v4: 부(部)마다 색 계열, 단계마다 색조를 조금씩, 변형마다 밝기를 다르게 한다
# (같은 부의 곡선은 한눈에 같은 계열로 보이고, 같은 단계의 변형은 같은 색조의 진하기로 구분된다).
V4_PART_HUE = {"m": 212, "g": 28, "tc": 135, "tt": 285}
V4_TANK_STAGES = ("s1_", "s2_", "t4_", "t5_", "t6_")   # 전차별 단계(4.1 = s*, 4.0 = t4~t6)


def v4_color(ident):
    stage, _, variant = ident.partition(':')
    part = 'tt' if stage.startswith(V4_TANK_STAGES) else ('tc' if stage.startswith('t') else stage[:1])
    hue = V4_PART_HUE.get(part)
    if hue is None:
        return None
    try:
        index = int(stage[1])
    except (IndexError, ValueError):
        index = 0
    hue = (hue + (index - 3) * 9) % 360
    from .curriculum_v4 import STAGES
    variants = next((st["variants"] for st in STAGES if st["id"] == stage), [])
    if variant in variants and len(variants) > 1:
        light = 0.38 + 0.30 * variants.index(variant) / (len(variants) - 1)
    else:
        light = 0.48
    return '#%02x%02x%02x' % tuple(round(c * 255) for c in colorsys.hls_to_rgb(hue / 360, light, .72))


def objective_color(key):
    # The primary stage is part of the identity too: basic driving and terrain
    # driving remain distinguishable even when both practise approach/stop.
    course = key.removeprefix('drive_terrain/terrain:v3/') if key.startswith('drive_terrain/terrain:v3/') else ''
    if course in COURSE_COLORS:
        return COURSE_COLORS[course]
    if '/objective:v4/' in key:
        color = v4_color(key.split('/objective:v4/', 1)[1])
        if color:
            return color
    digest = hashlib.sha256(key.encode()).digest()
    hue = int.from_bytes(digest[:4], 'big') / 2**32
    return '#%02x%02x%02x' % tuple(round(c * 255) for c in colorsys.hls_to_rgb(hue, .43, .7))


class ObjectiveIndex:
    def __init__(self):
        self.cache = {}
        self.catalog = {}

    def annotate(self, row, directory, terrain=None):
        directory = Path(directory)
        token = (str(directory), row.get('uid'), row.get('final_hash'))
        if token not in self.cache:
            cfg = {}
            local = directory / 'episodes' / ('env' + str(row.get('env', 0))) / (str(row.get('uid', '')) + '.json')
            paths = [local]
            if row.get('episode_file'):
                paths.append(Path(row['episode_file']))
            for path in paths:
                try:
                    cfg = episode_config(path)
                    break
                except (OSError, ValueError):
                    pass
            self.cache[token] = cfg
        cfg = self.cache[token]
        stage = row.get('stage', 'unknown')
        explicit = cfg.get('learning_objective') or cfg.get('meta', {}).get('learning_objective') or {}
        if isinstance(explicit, str):
            explicit = {'id': explicit}
        course = cfg.get('terrain_course', {})
        course_id = course.get('id') or (terrain or {}).get('course')
        if explicit.get('id') or row.get('objective_id'):
            ident = str(explicit.get('id') or row['objective_id'])
            version = str(explicit.get('version', row.get('objective_version') or 1))
            key = f'{stage}/objective:v{version}/{ident}'
            label = str(explicit.get('label') or row.get('objective_label') or ident) + f' [v{version}]'
        elif course_id:
            version = str(course.get('version', 'unknown'))
            key = f'{stage}/terrain:v{version}/{course_id}'
            label = COURSE_LABELS.get(course_id, course_id) + (' [버전 미상]' if version == 'unknown' else f' [v{version}]')
        else:
            key, label = f'{stage}/unspecified', '세부 목표 미기록'
        info = dict(id=key, stage=stage, label=label, color=objective_color(key))
        self.catalog[key] = info
        return row | {'objective': key, 'variant': cfg.get('scenario', {}).get('variant') or row.get('variant') or course_id or ''}
