# 网格搜索 + 训练参数速查

不确定哪套训练参数适合你的数据？固定一个基准场景（COLMAP 只做一次），暴力扫参数组合，看指标表选最优。

## 跑

编辑 `configs/grid.yaml`，然后：

```bash
conda activate gsplat
python -m pipeline grid --config configs/grid.yaml               # 默认扫 18 组合, 快筛 7000 步
python -m pipeline metrics output/_grid_lab --csv grid_lab.csv   # 出对比表选最优
```

- 复用 `output/<base_scene>/{images,sparse/0}` 当 base（不重跑抽帧/COLMAP），各组合只重训练，产物到 `output/_grid_<base>/<组合名>/`。
- 组合数：`default` = sh×ssim 个；`mcmc` = sh×ssim×cap 个。默认 6+12 = **18**。
- 精训最优：缩小 grid、调大 `steps` 再跑，如
  `configs` 里改成 `strategy:[mcmc] sh_degree:[3] ssim_lambda:[0.2] cap_max:[1000000] steps:30000`。

> ⚠️ base_scene 默认 `lab`，需要 `output/lab` 存在（有 images+sparse/0）。没有就先用别的流程跑出一个，或把 `base_scene` 改成现存的 output 场景。

## 训练参数速查

| 参数 | 默认 | 作用 | 配置键 |
|---|---|---|---|
| strategy | default | 密集化策略；`mcmc` 更稳、可控高斯上限 | `strategy` / grid `strategy:[...]` |
| sh_degree | 3 | 球谐阶数，颜色/高光细节 ↔ 显存 | `sh_degree` |
| ssim_lambda | 0.2 | SSIM 损失权重（结构 ↔ 像素） | `ssim_lambda` |
| cap_max(仅 mcmc) | 1e6 | 高斯数上限（质量/显存/OOM 主因） | `cap_max` |
| lpips_net | alex | 评估用；**vgg 会崩，勿用**（已固定 alex） | — |

> 真正的算法在 `gsplat/`；这些是它的命令行旋钮（`pipeline/steps.py::train` 拼装）。

## 查看指标 / 写文章

指标写在 `output/<场景>/results/`：

- `stats/val_step*.json` —— **PSNR / SSIM / LPIPS**（在 1/8 held-out 测试视图上算，即 novel-view 质量）、高斯数、耗时。
- `tb/` —— TensorBoard 曲线（`train/loss`、`val/psnr`…）；**loss 只在这里**。
- `renders/val_step*_*.png` —— 左 GT 右渲染的对比图，定性图直接用。

```bash
python -m pipeline metrics output/_grid_lab --csv grid_lab.csv   # markdown 表 + csv
tensorboard --logdir output --port 6006                          # 曲线
```

> 训练已固定 `--lpips_net alex`（本机 vgg 会让评估崩溃）+ `--eval_steps=max_steps`（保证最终步一定评估）。
