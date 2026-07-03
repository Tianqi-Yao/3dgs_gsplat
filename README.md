# Video → 3D Gaussian Splatting (gsplat) Pipeline

**English | [中文](README_zh.md)**

Turn phone/camera videos into 3DGS `.ply` files: single video, batch, multi-rig fusion, and a parameter grid search.

## Where to look (three layers)

The repo is organized so you can tell **what you need to touch** at a glance:

| I want to… | Look at | |
|---|---|---|
| **change parameters** (fps, steps, strategy…) | `configs/*.yaml` | ① daily |
| **change the workflow** (step order) | `pipeline/workflow.py` | ② each flow = a few step calls |
| **change what a step runs** (ffmpeg/colmap/gsplat cmd) | `pipeline/steps.py` | ③ |
| *(glue: subprocess, disk, SfM, metrics)* | `pipeline/_helpers/` | ❌ ignore |

```
configs/            single.yaml batch.yaml grid.yaml multiview.yaml   ← ① params
pipeline/
  workflow.py       ← ② the 4 flows (run_video/batch/multiview/grid)
  steps.py          ← ③ per-step commands
  _helpers/         ← ❌ helpers, don't need to read
docs/               per-flow guides
gsplat/             upstream gsplat (the actual 3DGS algorithm — external, untouched)
```

The real algorithm lives in `gsplat/` (external). What you tune is **params + workflow + per-step commands** — the three files above.

## Environment

conda env **`gsplat`** (Python 3.10, torch 2.8+cu128, RTX 5080 16GB), `gsplat`+`pycolmap`, system `COLMAP 4.1` + `ffmpeg`, `PyYAML`. The orchestrator (`pipeline/`) never imports torch — it only launches subprocesses.

```bash
conda activate gsplat
```

## Quick start (60s)

> Run all `python -m pipeline` commands from the **project root** (that's where `-m` finds the package).

```bash
mkdir -p data/myscene && mv my_video.mp4 data/myscene/     # a scene = one folder
python -m pipeline video --config configs/single.yaml      # edit scenes: in the yaml
# -> output/myscene/results/ply/point_cloud_6999.ply
```

Add `-n` / `--dry-run` to any command to print the commands without running.

## The four flows

| Flow | Command | Guide |
|---|---|---|
| single video | `python -m pipeline video --config configs/single.yaml` | [docs/single.md](docs/single.md) |
| batch | `python -m pipeline batch --config configs/batch.yaml` | [docs/batch.md](docs/batch.md) |
| multi-rig fusion | `python -m pipeline multiview --config configs/multiview.yaml` | [docs/multiview.md](docs/multiview.md) |
| grid search | `python -m pipeline grid --config configs/grid.yaml` | [docs/grid.md](docs/grid.md) |

## Metrics

```bash
python -m pipeline metrics output --csv m.csv     # PSNR/SSIM/LPIPS table across scenes
```

## Key facts

- **Disks**: `data/` & `output/` are on a 16TB FUSE disk; COLMAP fails there, so everything computes on local `scratch/` (ext4) and is moved to `output/` at the end. Scripts abort if `work_root` is FUSE.
- **LPIPS = alex** (fixed): `vgg` crashes eval on this machine and produces no metrics.
- **Resume**: a scene whose final ply exists is skipped.

## Acknowledgements

[gsplat](https://github.com/nerfstudio-project/gsplat) (Nerfstudio) + [COLMAP](https://colmap.github.io/).
