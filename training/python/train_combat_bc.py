"""사람의 실제 전투 시범으로 V6 전차별 모델을 행동 복제한다.

    # 실행 "V6run 1" 의 셔먼 모델에 셔먼 시범을 적용(새 체크포인트 세대로 저장, 이전 세대는 그대로 남음)
    py -3.14 training/python/train_combat_bc.py --run "V6run 1" --tank sherman75

    # 먼저 효과만 보기(저장 안 함)
    py -3.14 training/python/train_combat_bc.py --run "V6run 1" --tank sherman75 --dry-run

    # 실행이 아직 없을 때: 시작 모델 파일에 적용해 다른 파일로 저장 → train.py --init-model 로 시작
    py -3.14 training/python/train_combat_bc.py --model "<시작 모델>.zip" --tank sherman75 --output sherman_bc.zip

학습 중인 실행에는 적용하지 않는다(실행 잠금). 적용 후 대시보드에서 그 실행을 "이어서" 학습하면
행동 복제된 정책에서 PPO 가 이어진다. 누적 스텝·커리큘럼·PPO optimizer 상태는 그대로다.
결과 보고: <실행>/<차종>/behavior_clone/<시각>.json 과 curriculum.json 의 behavior_clone 기록.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from tankrl.combat_demo import ALLIES, clone, demos_root, list_demos, read_demo  # noqa: E402
from tankrl.control import write_json_atomic  # noqa: E402
from tankrl.storage import RunLock, atomic_copy, checkpoint_paths, default_runs_dir, save_checkpoint  # noqa: E402


def load_model(path: Path):
    from stable_baselines3 import PPO
    try:
        from tankrl.v6_control_policy import V6ControlPolicy
    except ImportError:          # V6 명령 확률 정책이 없는 체크아웃: 저장된 정책 그대로
        return PPO.load(str(path), device="cpu")
    return PPO.load(str(path), device="cpu", custom_objects={"policy_class": V6ControlPolicy})


def summary(report: dict) -> str:
    def row(tag, d):
        if not d:
            return f"  {tag}: -"
        return (f"  {tag}: NLL {d['nll']:.3f} · 발사 일치 {d['fire_match']:.0%} · 제동 일치 {d['brake_match']:.0%} · "
                f"시점 일치 {d['view_match']:.0%} · 궤도 오차 {d['track_mae']:.3f} · 포 오차 {d['gun_mae']:.3f}")
    return "\n".join([f"시범 {report['episodes']}판 · 학습 {report['train_samples']}개 · 검증 {report['held_out_samples']}개 · "
                      f"{report['epochs_run']}회", "적용 전", row("학습", report["before"]["train"]),
                      row("검증", report["before"]["held_out"]), "적용 후", row("학습", report["after"]["train"]),
                      row("검증", report["after"]["held_out"])])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tank", required=True, choices=list(ALLIES) + ["tiger1"])
    ap.add_argument("--run", default="", help="V6 실행 이름(이 실행의 차종 모델에 적용)")
    ap.add_argument("--runs-dir", default=str(default_runs_dir()))
    ap.add_argument("--model", default="", help="실행 대신 모델 파일에 적용(--output 필요)")
    ap.add_argument("--output", default="")
    ap.add_argument("--demos", default=str(demos_root()), help="시범 폴더(<폴더>/<차종>/*.npz)")
    ap.add_argument("--stage", default="", help="이 단계 시범만 사용(예: v6_1v2)")
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true", help="결과만 보고 저장하지 않는다")
    args = ap.parse_args(argv)

    paths = list_demos(args.tank, Path(args.demos))
    if args.stage:
        paths = [p for p in paths if read_demo(p)[2].get("stage") == args.stage]
    if not paths:
        raise SystemExit(f"시범이 없습니다: {Path(args.demos) / args.tank} — play_combat_demo.py 로 먼저 수집하세요")
    labels = read_demo(paths[0])[2]["obs_labels"]

    if args.run:
        run_dir = (Path(args.runs_dir) / args.run).resolve()
        tdir = run_dir / args.tank
        with RunLock(run_dir):
            checkpoint, cpath = checkpoint_paths(tdir)
            if checkpoint is None:
                raise SystemExit(f"{tdir} 에 모델이 없습니다. 한 번 학습을 시작해 첫 체크포인트를 만든 뒤 적용하세요.")
            model = load_model(checkpoint)
            if model.observation_space.shape[0] != len(labels):
                raise SystemExit(f"모델 입력 {model.observation_space.shape[0]}개 ≠ 시범 관측 {len(labels)}개. 같은 게임 버전으로 수집하세요.")
            report = clone(model, paths, labels, epochs=args.epochs, lr=args.lr, seed=args.seed)
            report.update(tank=args.tank, source_checkpoint=str(checkpoint), num_timesteps=int(model.num_timesteps),
                          applied=not args.dry_run, created=dt.datetime.now().astimezone().isoformat(timespec="seconds"))
            print(summary(report))
            if args.dry_run:
                return report
            stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
            (tdir / "behavior_clone").mkdir(parents=True, exist_ok=True)
            write_json_atomic(tdir / "behavior_clone" / f"{stamp}.json", report)
            curriculum = json.loads(cpath.read_text(encoding="utf-8")) if cpath.exists() else {}
            curriculum.setdefault("behavior_clone", []).append(
                {k: report[k] for k in ("created", "episodes", "train_samples", "held_out_samples", "epochs_run",
                                        "num_timesteps", "source_checkpoint")} | {"report": f"behavior_clone/{stamp}.json",
                                                                                   "after": report["after"]})
            if not (tdir / "checkpoint.json").exists():
                # 세대 기록 이전의 latest.zip 은 덮어쓰기 전에 보관한다
                atomic_copy(checkpoint, tdir / "behavior_clone" / f"{stamp}_before.zip")
            saved = save_checkpoint(model, tdir, curriculum)
            print(f"[bc] 저장: {saved} (적용 전 모델: {checkpoint})")
            return report
    if not args.model or not args.output:
        raise SystemExit("--run 또는 --model 과 --output 을 지정하세요")
    model = load_model(Path(args.model))
    report = clone(model, paths, labels, epochs=args.epochs, lr=args.lr, seed=args.seed)
    print(summary(report))
    if not args.dry_run:
        out = Path(args.output).resolve()
        model.save(str(out))
        out.parent.mkdir(parents=True, exist_ok=True)
        write_json_atomic(out.with_suffix(".bc.json"), report)
        print(f"[bc] 저장: {out}")
    return report


if __name__ == "__main__":
    main()
