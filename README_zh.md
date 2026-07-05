# 视频 → 3D Gaussian Splatting (gsplat) Pipeline

**[English](README.md) | 中文**

把手机/相机视频跑成 3DGS `.ply`：单视频、批量、多机位合成、参数网格搜索。

## 看代码只需三处（三层可见性）

目录按「你要动什么」组织，一眼分清：

| 我想… | 看这里 | |
|---|---|---|
| **调参数**（fps、步数、strategy…） | `configs/*.yaml` | ① 日常 |
| **调工作流**（步骤顺序） | `pipeline/workflow.py` | ② 每个流程=几行步骤调用 |
| **改某步命令**（ffmpeg/colmap/gsplat） | `pipeline/steps.py` | ③ |
| *（辅助：subprocess、磁盘、SfM、指标）* | `pipeline/_helpers/` | ❌ 不用看 |

```
configs/            single.yaml batch.yaml grid.yaml multiview.yaml   ← ① 参数
pipeline/
  workflow.py       ← ② 四个流程(run_video/batch/multiview/grid)
  steps.py          ← ③ 每步命令
  _helpers/         ← ❌ 辅助, 不用读
docs/               各流程详解
gsplat/             上游 gsplat(真正的 3DGS 算法 — 外部依赖, 不动)
```

真正的算法在 `gsplat/`（外部）。你要调的是**参数 + 工作流 + 每步命令**——就上面三个文件。

## 环境

conda 环境 **`gsplat`**（Python 3.10、torch 2.8+cu128、RTX 5080 16GB），`gsplat`+`pycolmap`，系统 `COLMAP 4.1` + `ffmpeg`，`PyYAML`。编排层（`pipeline/`）不 import torch，只起子进程。

```bash
conda activate gsplat
```

## 60 秒上手

> 所有 `python -m pipeline` 命令在**项目根目录**下运行（`-m` 要在这里才找得到包）。

```bash
mkdir -p data/myscene && mv 我的视频.mp4 data/myscene/     # 一个场景 = 一个文件夹
python -m pipeline video --config configs/single.yaml      # 场景名在 yaml 的 scenes: 里改
# -> output/myscene/results/ply/point_cloud_6999.ply
```

任何命令加 `-n` / `--dry-run` 只打印命令、不执行。

## 四个流程

| 流程 | 命令 | 文档 |
|---|---|---|
| 单视频 | `python -m pipeline video --config configs/single.yaml` | [docs/single.md](docs/single.md) |
| 批量 | `python -m pipeline batch --config configs/batch.yaml` | [docs/batch.md](docs/batch.md) |
| 多机位合成 | `python -m pipeline multiview --config configs/multiview.yaml` | [docs/multiview.md](docs/multiview.md) |
| 网格搜索 | `python -m pipeline grid --config configs/grid.yaml` | [docs/grid.md](docs/grid.md) |

> **效果差(尤其户外)?** 先跑 `python -m pipeline grid -c configs/grid.yaml --colmap-only` 看 COLMAP
> **注册率** —— 常常是重建失败了(没几张图注册进去)、不是训练问题。见 [docs/grid.md](docs/grid.md)。

## 指标

```bash
python -m pipeline metrics output --csv m.csv     # 各场景 PSNR/SSIM/LPIPS 汇总表
```

## 关键事实

- **磁盘**：`data/`、`output/` 在 16TB FUSE 盘上，COLMAP 在其上会失败，所以全程在本地 `scratch/`（ext4）计算，跑完搬到 `output/`。`work_root` 是 FUSE 会直接报错。
- **LPIPS 固定 alex**：本机 `vgg` 会让评估崩溃、拿不到任何指标。
- **断点续跑**：最终 ply 已存在的场景自动跳过。

## 致谢

[gsplat](https://github.com/nerfstudio-project/gsplat)（Nerfstudio）+ [COLMAP](https://colmap.github.io/)。
