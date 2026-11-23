# V6 model checkpoints

This snapshot contains the latest completed checkpoint for each tank in V6-1 and V6-2.
Each checkpoint retains its model ZIP, curriculum, metadata, and generation pointer.
V6-1 also includes the three saved best models under each tank's good directory.

| Run | Tank | Steps |
| --- | --- | ---: |
| V6-1 | tiger1 | 13,977,994 |
| V6-1 | sherman75 | 10,246,474 |
| V6-1 | t34_76 | 7,826,364 |
| V6-2 | tiger1 | 19,485,799 |
| V6-2 | sherman75 | 19,265,064 |
| V6-2 | t34_76 | 16,509,378 |

From the repository root, download and verify the snapshot with Git LFS and Python.

```powershell
git lfs pull --include='training/snapshots/20261123_v6_checkpoints/**'
python training/snapshots/verify_snapshot.py training/snapshots/20261123_v6_checkpoints
```

## Training history

Each run includes episode, scenario and PPO metrics, along with the objective
and map labels used by the graphs. Open the generated HTML reports directly.

- [V6-1 training report](runs/V6-1/training_report.html)
- [V6-2 training report](runs/V6-2/training_report.html)

To inspect the interactive dashboard from the repository root, run:

```powershell
python training/python/dashboard.py --runs-dir (Resolve-Path 'training/snapshots/20261123_v6_checkpoints/runs').Path --port 8793
```

The snapshot contains graph history and saved models. Episode recordings and
replays remain in the original runs.
