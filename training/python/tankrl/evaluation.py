"""Repeatable 1-vs-6 battles, with model identity and controller provenance recorded."""
from collections import Counter
from copy import deepcopy
import csv
import hashlib
import html
import json
import os
from pathlib import Path
import random
import time

import numpy as np

from .control import write_json_atomic
from .curriculum import STAGES, STAGE_IDS, lineup, make_config, tank_names
from .godot_env import GodotProcess, PROGRESS_FIELDS
from .objectives import objective_color
from .storage import archive_runtime, checkpoint_paths, sha256
from .individuals import AGENTS, load_individuals
from .pace import require_pace_support

MODES = {
    'mixed': '7개체 독립 정책 대전',
    'tiger_vs_scripted': '학습 티거 대 규칙 연합군',
    'allies_vs_scripted': '규칙 티거 대 독립 연합군',
    'scripted': '양쪽 모두 규칙 AI 기준선',
}
COLORS = {mode: objective_color('final_battle/objective:v3/tiger1_vs_allies6_' + mode) for mode in MODES}
FINAL_STAGE = 'final_battle'


def battle_config(available, mode, seed, uid, record=True, time_limit=180):
    stage = deepcopy(STAGES[STAGE_IDS.index(FINAL_STAGE)])
    stage['time_limit_s'] = time_limit
    stage['learning_objective'] = {'id': 'tiger1_vs_allies6_' + mode, 'label': MODES[mode], 'version': 3}
    tanks = lineup(stage, 'tiger1', random.Random(seed), set(available))
    bindings = {}
    for tank, name in zip(tanks, tank_names(tanks)):
        use_model = name in available and (
            mode == 'mixed' or mode == 'tiger_vs_scripted' and tank['team'] == 0
            or mode == 'allies_vs_scripted' and tank['team'] == 1)
        tank['ctrl'] = 'external' if use_model else 'scripted'
        bindings[name] = name if use_model else 'scripted'
    cfg = make_config(stage, 'tiger1', tanks, seed, seed, uid, record,
                      {'evaluation': True, 'mode': mode, 'controller_bindings': bindings,
                       'stage_idx': 9, 'current_stage': FINAL_STAGE})
    return cfg, bindings


def policy_hash(model):
    digest = hashlib.sha256()
    for name, value in sorted(model.policy.state_dict().items()):
        digest.update(name.encode())
        digest.update(value.detach().cpu().numpy().tobytes())
    return digest.hexdigest()


def load_frozen_models(source, out):
    if not source.exists():
        raise ValueError("모델이 있는 실행을 선택하세요.")
    models, states = load_individuals(source, out)
    metadata = {}
    for agent, model in models.items():
        model.policy.set_training_mode(False)
        path, _ = checkpoint_paths(out / 'agents' / agent)
        metadata[agent] = dict(controller='policy', tank=AGENTS[agent], source=states[agent].get('resumed_from', states[agent]['origin']),
            origin_sha256=states[agent].get('origin_sha256'), snapshot=str(path), sha256=sha256(path),
            num_timesteps=model.num_timesteps, independent_steps=states[agent].get('independent_steps', 0),
            stage=states[agent].get('stage'), policy_hash=policy_hash(model))
    return models, metadata


def aggregate(results):
    groups = {}
    for mode in dict.fromkeys(r['mode'] for r in results):
        rows = [r for r in results if r['mode'] == mode]
        outcomes = Counter(r['winner'] for r in rows)
        teams = {}
        for team, name in ((0, 'tiger'), (1, 'allies')):
            tanks = [t for r in rows for t in r['tanks'] if t['team'] == team]
            shots = sum(t['shots'] for t in tanks)
            hits = sum(t['hits'] for t in tanks)
            teams[name] = dict(shots=shots, hits=hits, accuracy=hits / shots if shots else None,
                               pens=sum(t['pens'] for t in tanks), kills=sum(t['kills'] for t in tanks))
        groups[mode] = dict(games=len(rows), tiger_wins=outcomes[0], allied_wins=outcomes[1], draws=outcomes[-1],
                            mean_duration=sum(r['duration_s'] for r in rows) / len(rows), **teams)
    return groups


def write_report(out, manifest, results):
    groups = aggregate(results)
    summary = dict(manifest=manifest, groups=groups, games=results)
    write_json_atomic(out / 'evaluation.json', summary)
    esc = html.escape
    parts = ['<h1>10단계 최종전 평가: 티거 1 대 연합군 6</h1>',
             '<p>셔먼 3대 + T-34 3대 · 360m 맵 · 200m 출발 · 전투 제한 ' + str(manifest['time_limit_s']) + '초</p>',
             '<p>정책 가중치는 고정하고 결정적 추론을 사용했다. 시간 초과는 무승부이며, 생존 수나 점수로 승리를 대신 판정하지 않는다.</p>',
             '<h2>사용 모델</h2><table><tr><th>차종</th><th>조종</th><th>누적 스텝</th><th>학습 단계</th><th>SHA-256</th></tr>']
    for tank, model in manifest['models'].items():
        parts.append(f'<tr><td>{tank}</td><td>{model["controller"]}</td><td>{model.get("num_timesteps", "—")}</td>'
                     f'<td>{esc(str(model.get("stage", model.get("reason", ""))))}</td><td><code>{model.get("sha256", "—")}</code></td></tr>')
    parts.append('</table><h2>시나리오별 결과</h2>')
    for mode, stats in groups.items():
        width = 100 / stats['games']
        parts.append(f'<h3 style="color:{COLORS[mode]}">{esc(MODES[mode])}</h3><div class=bar>'
                     f'<span style="width:{stats["tiger_wins"] * width}%;background:#2563eb"></span>'
                     f'<span style="width:{stats["allied_wins"] * width}%;background:#c26708"></span>'
                     f'<span style="width:{stats["draws"] * width}%;background:#64748b"></span></div>'
                     f'<p>{stats["games"]}판 · 티거 승 {stats["tiger_wins"]} / 연합군 승 {stats["allied_wins"]} / 무승부 {stats["draws"]}'
                     f' · 평균 {stats["mean_duration"]:.1f}초</p>')
        parts.append('<table><tr><th>팀</th><th>발사</th><th>명중</th><th>명중률</th><th>관통</th><th>격파</th></tr>')
        for team in ('tiger', 'allies'):
            values = stats[team]
            accuracy = f'{values["accuracy"]:.1%}' if values['accuracy'] is not None else '발사 없음'
            parts.append(f'<tr><td>{team}</td><td>{values["shots"]}</td><td>{values["hits"]}</td><td>{accuracy}</td><td>{values["pens"]}</td><td>{values["kills"]}</td></tr>')
        parts.append('</table>')
    parts.append('<p>승패 막대: 파랑=티거 승, 주황=연합군 승, 회색=무승부. 소수 시드 결과는 예비 진단이며 일반 승률을 보장하지 않는다.</p>'
                 '<h2>경기별 결과</h2><table><tr><th>방식</th><th>시드</th><th>승리 팀</th><th>종료</th><th>시간</th><th>티거 이동</th><th>기록</th></tr>')
    for game in results:
        links = []
        for key, label in (('episode_file', '행동 기록'), ('replay_dir', '경기 보고서')):
            if game.get(key):
                path = Path(game[key]) / 'report.html' if key == 'replay_dir' else Path(game[key])
                links.append(f'<a href="{esc(os.path.relpath(path, out).replace(chr(92), "/"))}">{label}</a>')
        parts.append(f'<tr><td style="color:{COLORS[game["mode"]]}">{esc(MODES[game["mode"]])}</td><td>{game["seed"]}</td>'
                     f'<td>{ {0: "티거", 1: "연합군", -1: "무승부"}.get(game["winner"], "미정")}</td><td>{esc(game["reason"])}</td>'
                     f'<td>{game["duration_s"]}</td><td>{game["tiger_path_m"]:.1f}m</td><td>{" · ".join(links)}</td></tr>')
    parts.append('</table><p>전체 설정·모델 식별·전차별 결과: <a href="evaluation.json">evaluation.json</a></p>')
    css = 'body{font-family:system-ui,"Malgun Gothic",sans-serif;max-width:1100px;margin:24px auto;padding:0 16px}table{border-collapse:collapse;width:100%;font-size:13px}td,th{border:1px solid #ddd;padding:6px;text-align:left}code{overflow-wrap:anywhere;font-size:11px}.bar{display:flex;height:20px;background:#eee;border-radius:4px;overflow:hidden}h2{margin-top:28px}'
    (out / 'evaluation_report.html').write_text('<!doctype html><meta charset=utf-8><title>최종전 평가</title><style>' + css + '</style>' + '\n'.join(parts), encoding='utf-8')


def run_evaluation(args, modes):
    import torch
    torch.set_num_threads(2)
    out = args.out.resolve()
    source = (args.runs_dir / args.source_run).resolve()
    if source.parent != args.runs_dir.resolve():
        raise ValueError('Invalid source run')
    if out == source or any((out / name).exists() for name in ('progress.csv', 'status.json', 'run.json', 'evaluation_manifest.json')):
        raise ValueError('평가 결과를 덮어쓰지 않습니다. 새 출력 폴더를 사용하세요.')
    out.mkdir(parents=True, exist_ok=True)
    models, metadata = load_frozen_models(source, out)
    manifest = dict(source_run=args.source_run, models=metadata, modes=modes, seed=args.seed,
                    episodes_per_mode=args.episodes, time_limit_s=args.time_limit,
                    lineup=['tiger1'] + ['sherman75'] * 3 + ['t34_76'] * 3, deterministic=True,
                    fresh_process_per_game=True, reward_version=3,
                    runtime=archive_runtime(Path(args.godot).resolve(), args.project))
    write_json_atomic(out / 'evaluation_manifest.json', manifest)
    results = []
    steps = 0
    started = time.time()

    def status(phase='evaluating', **extra):
        write_json_atomic(out / 'status.json', dict(pid=os.getpid(), mode='evaluation', phase=phase,
            updated=time.time(), started=started, tank='tiger1', num_timesteps=steps, episodes=len(results),
            n_envs=1, curriculum=dict(stage_idx=9, stage=FINAL_STAGE),
            evaluation=dict(completed=len(results), total=len(modes) * args.episodes,
                            source_run=args.source_run, report='evaluation_report.html'), **extra))

    status()
    process = None
    try:
        process = GodotProcess(args.godot, args.project, 0, str(out))
        if process.hello.get('compact_battle_version', 0) < 1 or process.hello.get('fast_combat_reward_version', 0) < 1:
            raise ValueError('소형 전장을 지원하는 최신 게임 빌드가 필요합니다.')
        manifest['engine'] = process.hello.get('engine')
        write_json_atomic(out / 'evaluation_manifest.json', manifest)
        with (out / 'progress.csv').open('w', newline='', encoding='utf-8') as output:
            writer = csv.DictWriter(output, fieldnames=PROGRESS_FIELDS)
            writer.writeheader()
            for mode in modes:
                for index in range(args.episodes):
                    if results:
                        # A fresh physics world removes reset/contact warm-start state from paired tests.
                        process.close()
                        process = GodotProcess(args.godot, args.project, 0, str(out))
                    seed = args.seed + index
                    uid = f'{out.name}_{mode}_{seed}'
                    record = args.record_every > 0 and len(results) % args.record_every == 0
                    cfg, bindings = battle_config(models, mode, seed, uid, record, args.time_limit)
                    names = tank_names([{'type': t['type']} for t in cfg['tanks']])
                    cfg['meta']['policies'] = {name: metadata[tank]['sha256'] for name, tank in bindings.items() if tank != 'scripted'}
                    require_pace_support(process.hello, cfg)
                    process.send({'type': 'reset', 'config': cfg})
                    header, obs = process.recv_obs()
                    external = [name for name in names if bindings[name] != 'scripted']
                    for decision in range(args.time_limit * 10 + 5):
                        actions = np.zeros((len(external), 11), dtype=np.float32)
                        for tank, model in models.items():
                            indices = [i for i, name in enumerate(external) if bindings[name] == tank]
                            if indices:
                                actions[indices] = model.predict(obs[indices], deterministic=True)[0]
                        if not np.isfinite(actions).all():
                            raise ValueError('Non-finite model action')
                        process.send({'type': 'step'}, np.clip(actions, -1, 1).astype('<f4').tobytes())
                        header, obs = process.recv_obs()
                        if not np.isfinite(obs).all():
                            raise ValueError('Non-finite observation')
                        steps += 1
                        if decision % 50 == 0:
                            status()
                        if header['done']:
                            break
                    else:
                        raise RuntimeError('Evaluation failed to terminate at its time limit')
                    result = header['episode']
                    # Path samples belong to the real episode; they are never fed into the policy.
                    episode = json.loads(Path(result['episode_file']).read_text(encoding='utf-8'))
                    path = np.asarray(episode.get('paths_1hz', []))
                    movement = float(np.linalg.norm(np.diff(path[:, 1:3], axis=0), axis=1).sum()) if len(path) > 1 else 0.
                    game = result | dict(mode=mode, seed=seed, tiger_path_m=movement, bindings=bindings)
                    results.append(game)
                    tiger = result['tanks'][0]
                    writer.writerow({k: v for k, v in dict(wall_time=time.time(),global_step=steps,env=0,uid=uid,
                        tank='tiger1',stage=FINAL_STAGE,stage_idx=9,current_stage=FINAL_STAGE,
                        success=int(result['winner'] == 0),reason=result['reason'],winner=result['winner'],
                        decisions=result['decisions'],duration_s=result['duration_s'],
                        spawn_distance_m=result['spawn_distance_m'],map_seed=seed,seed=seed,
                        hits=tiger['hits'],pens=tiger['pens'],kills=tiger['kills'],shots=tiger['shots'],
                        learner_policy=cfg['meta']['policies'].get('tiger1_0', 'scripted'),opponents=mode,
                        episode_file=result['episode_file'],replay_dir=result.get('replay_dir',''),final_hash=result['final_hash']).items() if k in PROGRESS_FIELDS} | {'return': tiger['return']})
                    output.flush()
                    write_report(out, manifest, results)
                    status()
                    print(json.dumps({k:game[k] for k in ('mode','seed','winner','reason','duration_s','tiger_path_m')}, ensure_ascii=False), flush=True)
        for tank, model in models.items():
            assert policy_hash(model) == metadata[tank]['policy_hash'], 'Policy changed during evaluation'
            assert model.num_timesteps == metadata[tank]['num_timesteps']
        manifest['weights_unchanged'] = True
        write_json_atomic(out / 'evaluation_manifest.json', manifest)
        write_report(out, manifest, results)
        status('stopped', completed=True)
    except Exception as error:
        status('stopped', error=str(error))
        raise
    finally:
        if process is not None:
            process.close()
    return out / 'evaluation_report.html'
