"""Read training records without modifying models, runs, or the running trainer."""
import collections
import csv
import datetime as dt
import json
import os
from pathlib import Path
import statistics
import sys
import zipfile

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE / 'training/python'))
from tankrl.objectives import ObjectiveIndex

ROOT = Path(os.environ['LOCALAPPDATA']) / 'TankGameML/training/runs'
OUT = Path(__file__).resolve().parent

def read_csv(path):
    if not path.exists():
        return []
    with path.open(encoding='utf-8-sig', newline='') as f:
        return list(csv.DictReader(f))

def avg(rows, field):
    values = [float(r[field]) for r in rows if r.get(field) not in ('', None)]
    return round(statistics.mean(values), 4) if values else None

def summary(rows):
    if not rows:
        return {}
    return dict(n=len(rows), successes=sum(int(r['success']) for r in rows),
                success_rate=avg(rows, 'success'), mean_return=avg(rows, 'return'),
                mean_duration_s=avg(rows, 'duration_s'), mean_shots=avg(rows, 'shots'),
                first_step=int(rows[0]['global_step']), last_step=int(rows[-1]['global_step']),
                reasons=dict(collections.Counter(r['reason'] for r in rows)))

audit = {'captured_kst': dt.datetime.now(dt.timezone(dt.timedelta(hours=9))).isoformat(), 'runs': {}}
for name in ['su1117_02', '20261117_063521', 'terrain_v2_20261117']:
    directory = ROOT / name
    rows = read_csv(directory / 'progress.csv')
    terrain = {r['uid']: r for r in read_csv(directory / 'terrain_progress.csv')}
    index = ObjectiveIndex()
    groups = collections.defaultdict(list)
    for r in rows:
        annotated = index.annotate(r, directory, terrain.get(r['uid']))
        if r['uid'] in terrain:
            annotated['terrain'] = terrain[r['uid']]
        groups[(r['tank'], annotated['objective'])].append(annotated)
    manifest = json.loads((directory / 'run.json').read_text(encoding='utf-8'))
    status = json.loads((directory / 'status.json').read_text(encoding='utf-8'))
    detail = dict(status={k:status.get(k) for k in ['tank','phase','num_timesteps','updated','steps_per_s','runtime']},
                  stage_counts=dict(collections.Counter(r['stage'] for r in rows)),
                  sessions=[], models={}, objectives=[], ppo=[])
    for s in manifest['sessions']:
        runtime=s.get('runtime') or {}
        detail['sessions'].append(dict(started=s['started'],tank=s['args']['tank'],
            terrain_version=manifest.get('terrain_course_version'),
            start_timesteps=runtime.get('start_timesteps'), resumed_from=runtime.get('resumed_from'),
            n_envs=s['args'].get('n_envs'), speed_cap=s['args'].get('speed_cap')))
    for tank in ['tiger1','sherman75','t34_76']:
        td=directory/tank
        cp=td/'checkpoint.json'
        if cp.exists():
            pointer=json.loads(cp.read_text(encoding='utf-8'))
            model=td/pointer['generation']/'model.zip'
        else:
            model=td/'latest.zip'
        if not model.exists():
            continue
        with zipfile.ZipFile(model) as z:
            model_data=json.loads(z.read('data'))
        curriculum_path = model.parent/'curriculum.json' if cp.exists() else td/'curriculum.json'
        curriculum=json.loads(curriculum_path.read_text(encoding='utf-8')) if curriculum_path.exists() else {}
        detail['models'][tank]=dict(path=str(model), parameters={k:model_data.get(k) for k in
            ['num_timesteps','gamma','gae_lambda','n_steps','batch_size','n_epochs','learning_rate','ent_coef','use_sde','sde_sample_freq']},
            stage=curriculum.get('stage'), history=curriculum.get('history'),
            terrain=curriculum.get('terrain'), previous_assessments=curriculum.get('previous_assessments'))
    for (tank, objective), values in groups.items():
        # CSV order records actual completed episode order, including resumed sessions.
        item=dict(tank=tank, objective=objective, overall=summary(values),
                  first100=summary(values[:100]), last100=summary(values[-100:]),
                  last40=summary(values[-40:]), blocks=[])
        for i in range(0,len(values),100):
            item['blocks'].append(summary(values[i:i+100]))
        for label, subset in [('overall',values),('last100',values[-100:])]:
            routes=[r for r in subset if 'terrain' in r]
            if routes:
                item[label]['mean_progress_fraction']=round(statistics.mean(
                    1-float(r['terrain']['best_remaining_m'])/max(1,float(r['terrain']['initial_route_m'])) for r in routes),4)
                successful=[r for r in routes if r['success']=='1']
                if successful:
                    item[label]['successful_path_ratio']=round(statistics.mean(
                        float(r['terrain']['path_m'])/max(1,float(r['terrain']['initial_route_m'])) for r in successful),4)
        detail['objectives'].append(item)
    for path in (directory/'sb3').rglob('progress.csv'):
        log=read_csv(path)
        if not log:
            continue
        fields=['time/total_timesteps','time/fps','train/approx_kl','train/clip_fraction',
                'train/explained_variance','train/entropy_loss','train/std','train/value_loss','train/policy_gradient_loss']
        detail['ppo'].append(dict(path=str(path),rows=len(log),last=[{k:r.get(k) for k in fields} for r in log[-3:]]))
    audit['runs'][name]=detail

output=OUT/'training_efficiency_audit_20261117.json'
output.write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf-8')
print('CAPTURED',audit['captured_kst'])
for name,run in audit['runs'].items():
    print('\nRUN',name,run['status']['phase'],run['status']['tank'],run['status']['num_timesteps'])
    print('STAGES',run['stage_counts'])
    print('MODELS',[(t,m['parameters']['num_timesteps']) for t,m in run['models'].items()])
    for item in run['objectives']:
        a,b,c=item['overall'],item['first100'],item['last100']
        print(item['tank'],item['objective'],'N',a['n'],'steps',a['first_step'],a['last_step'],
              'all/first100/last100/last40',a['success_rate'],b['success_rate'],c['success_rate'],item['last40']['success_rate'],
              'return',b['mean_return'],c['mean_return'],'duration',b['mean_duration_s'],c['mean_duration_s'],
              'fail',c['reasons'],'progress',c.get('mean_progress_fraction'),'path',c.get('successful_path_ratio'))
    for item in run['ppo']:
        print('PPO',str(Path(item['path']).relative_to(ROOT/name)),item['rows'],item['last'][-1])
print('\nSAVED',output)
