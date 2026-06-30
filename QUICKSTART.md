# 单段视频 → 单个 PLY 快速上手

把**一段视频**生成 3D Gaussian Splatting 的 `.ply`。
流程：抽帧 → COLMAP 求相机位姿（自动挑完整 SfM 模型）→ gsplat 训练 → 单个 PLY。
COLMAP/训练全程在本地 `scratch/`（ext4）跑，完成后整体搬到 `output/<场景名>/`（`data/`、`output/`
都在 16TB FUSE 盘，COLMAP mapper 在 FUSE 上会失败）。

脚本：`scripts/video_to_ply.sh`
环境：conda 环境 **`gsplat`**，已装 gsplat + pycolmap，系统有 colmap / ffmpeg，GPU RTX 5080 16GB。

> 多视角（同场景多机位合成一个 ply）见 `QUICKSTART_MULTIVIEW.md`；一目录批量各出一个 ply 见 `QUICKSTART_BATCH.md`。

---

## 输入约定：一个场景 = 一个子文件夹

```
data/
  0623_one_tomato/          ← 一个场景
    0623_one_tomato.mp4     ← 把这一个视频放进来
  <下一个场景>/             ← 同样: 文件夹里放一个视频
    *.mp4
```

- 文件夹里放这个场景的视频，文件名随意（脚本自动找文件夹顶层的视频）。
- 支持 `.mp4 / .MP4 / .mov / .MOV`。

---

## 怎么跑

### 方式 A：改脚本开头一行（你的习惯）

打开 `scripts/video_to_ply.sh`，改最上面这一行的默认值：

```bash
NAME="${1:-0623_one_tomato}"   # ← 改成 <你的场景名>（= data/<场景名>/ 文件夹）
```

然后：

```bash
conda activate gsplat
scripts/video_to_ply.sh
```

### 方式 B：直接传参（不用改脚本）

```bash
conda activate gsplat
scripts/video_to_ply.sh <场景名>
```

### 后台整夜跑（高质量档耗时长时）

```bash
conda activate gsplat
setsid bash -c 'scripts/video_to_ply.sh' </dev/null \
  > output/<场景名>_$(date +%m%d_%H%M).log 2>&1 &
tail -f output/<场景名>_*.log     # Ctrl-C 只退 tail，不停任务
```

---

## 质量 / 速度档（脚本顶部变量，可用环境变量覆盖）

| 变量 | 默认（快速预览） | 说明 |
|---|---|---|
| `FPS` | 8 | 每秒抽帧数。21s 视频 ≈ 171 张；觉得视角稀就调大 |
| `WIDTH` | 1920 | 抽帧宽度。4K 降到 1920，COLMAP 和训练都快很多 |
| `MAX_STEPS` | 7000 | 训练步数。30000 是高质量常用值 |
| `CAMERA_MODEL` | `OPENCV` | 普通镜头；广角/鱼眼用 `OPENCV_FISHEYE` |

**快速预览**（默认）：几分钟训练，先验证能不能重建。
**高质量**示例：

```bash
MAX_STEPS=30000 scripts/video_to_ply.sh
```

---

## 跑完怎么看是否成功

脚本会自动打印关键信息：

1. **挑选的 SfM 模型注册数**：`选中: .../sparse/0 (注册 168 / 抽帧 171)`
   —— 注册数接近总抽帧数 = 重建完整。若注册率 < 40% 或注册数 < 30 会有 `⚠` 提示
   （加大 `FPS` 重抽，或换 `exhaustive_matcher`）。
2. 训练末尾的 **PSNR**（越高越好；个位数 = 重建失败）。

成功标志（脚本结尾）：`# ✓ 完成: output/<场景名>/results/ply/point_cloud_<步数-1>.ply`

---

## 产物结构

输入视频留在 `data/<场景名>/`；产物在 `output/<场景名>/`（本地 `scratch/` 算完搬过来）：

```
output/<场景名>/
  images/                  抽帧
  database.db              COLMAP 库
  sparse/0/                完整 SfM 模型（已自动挑选）
  results/ply/             point_cloud_<步数-1>.ply   ← 最终结果
  results/ckpts/           ckpt_*.pt
  results/stats/           val_step<步数-1>.json  ← PSNR/SSIM/LPIPS
  results/tb/              TensorBoard 曲线（loss、val/psnr…）
  results/renders/         val_step<步数-1>_*.png ← 左 GT 右渲染的对比图
```

查看 PLY：拖进 https://superspl.at/editor ，或

```bash
python gsplat/examples/simple_viewer.py --ckpt output/<场景名>/results/ckpts/ckpt_<步数-1>_rank0.pt
```

---

## 查看指标 / 写文章

指标写在 `output/<场景名>/results/` 下三处：

- `stats/val_step<步数-1>.json` —— **PSNR / SSIM / LPIPS**、高斯数、每图渲染耗时。
  在 **1/8 held-out 测试视图**上算（即 novel-view 合成质量，论文里要写明这点）。做表用它。
- `tb/` —— TensorBoard：`train/loss`、`val/psnr` 等随 step 的曲线（**loss 只在这里**，不在 json）。
- `renders/val_step<步数-1>_*.png` —— 左 GT 右渲染的对比图，定性图直接用。

**① 多场景汇总成表**（markdown + csv，进论文/Excel）：

```bash
python scripts/collect_metrics.py                          # 打印 markdown 表
python scripts/collect_metrics.py output --csv metrics.csv # 同时导 csv
```

**② 看 loss / PSNR 曲线**（多场景一起对比，可导出图）：

```bash
tensorboard --logdir output --port 6006   # 浏览器开 localhost:6006
```

**③ 快速看单个数值**：

```bash
cat output/<场景名>/results/stats/val_step*.json
grep -E "PSNR:" output/<场景名>_*.log      # 后台跑的日志里也有
```

> **已默认对齐论文口径**（所有训练脚本都固定加了这两项）：
> - `--lpips_net vgg`：LPIPS 用 VGG（和 3DGS / Mip-NeRF360 一致），否则和它们的 LPIPS 不可比。
> - `--eval_steps <步数>`：保证**最终步一定评估**，不会因步数没落在默认的 7000/30000 而漏掉指标。

---

## 注意 / 常见问题

| 现象 | 原因 / 解决 |
|------|------|
| `unrecognised option '--SiftExtraction.use_gpu'` | COLMAP 4.x 改名了，脚本已用 `--FeatureExtraction.use_gpu` / `--FeatureMatching.use_gpu`（老参数会"unrecognised option"并悄悄生成空库） |
| mapper 报 `No images with matches` | 特征库是空的（多半上面那个参数名写错）。脚本每次清旧库重建，重跑即可 |
| 训练 PSNR 个位数 / 注册图像很少 | COLMAP 重建不全：加大 `FPS` 重抽，或相机模型选对（广角用 `OPENCV_FISHEYE`） |
| 训练卡很久没动 | 首次 `import gsplat` 为 RTX 5080 (sm_120) 编译 CUDA 核，约 10~20 分钟，只编一次（之后走缓存 `~/.cache/torch_extensions/`） |
| 显存 OOM | 调小 `WIDTH`（如 1280）或减少帧数（调小 `FPS`） |

> 脚本已自动把"注册图像最多"的子模型设为 `sparse/0`（mapper 可能拆出多个子模型，完整的不一定是 0 号），
> 不用再手动 `model_analyzer` + `rm/mv`。
