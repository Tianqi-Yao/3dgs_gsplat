# 单视频 → 一个 PLY

一段视频生成 3DGS `.ply`：抽帧 → COLMAP 位姿(自动挑完整 SfM 模型) → gsplat 训练 → 导 PLY。

## 输入

一个场景 = `data/<场景名>/` 文件夹，里面放**一个**视频（`.mp4/.MP4/.mov/.MOV`），脚本自动找。

## 跑

编辑 `configs/single.yaml` 的 `scenes:`（一个场景名），然后：

```bash
conda activate gsplat
python -m pipeline video --config configs/single.yaml
python -m pipeline video --config configs/single.yaml -n   # 干跑, 只打印命令
```

## 参数（`configs/single.yaml` 的 `params:`）

| 键 | 默认 | 说明 |
|---|---|---|
| `fps` | 5 | 每秒抽帧数；视角稀就调大 |
| `width` | 1920 | 抽帧宽度（4K 降到 1920，COLMAP/训练都快） |
| `max_steps` | 7000 | 训练步数；30000 = 高质量 |
| `camera_model` | OPENCV | 广角鱼眼用 `OPENCV_FISHEYE` |
| `sh_degree` / `ssim_lambda` / `strategy` / `cap_max` | 3 / 0.2 / default / 1e6 | 见 [grid.md](grid.md) 的参数速查 |

## 产物

计算在本地 `scratch/<场景>/`，完成搬到 `output/<场景>/`：

```
output/<场景>/
  images/  database.db  sparse/0/
  results/ply/point_cloud_<步数-1>.ply   ← 结果
  results/ckpts/  results/stats/  results/tb/  results/renders/
```

指标：`python -m pipeline metrics output`（见 [grid.md](grid.md) 的「查看指标」）。
查看 PLY：拖进 https://superspl.at/editor 。

## 常见问题

| 现象 | 解决 |
|---|---|
| PSNR 个位数 / 注册图像很少 | COLMAP 重建不全：加大 `fps`，或相机模型选对 |
| 训练卡很久没动 | 首次 `import gsplat` 编译 CUDA 核约 10~20 分钟，只编一次 |
| 显存 OOM | 调小 `width` 或 `fps` |
| `work_root 是 FUSE` 报错 | `scratch` 必须是本地 ext4，别指到 16TB 盘 |
