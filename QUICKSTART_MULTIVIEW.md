# 多视角视频 → 单个 PLY 快速上手

把**同一场景、不同视角**的多个视频（如上/中/下）合成**一个** 3DGS `.ply`。
流程：三段帧抽到一起 → COLMAP 全配对 SfM（注册到同一坐标系）→ gsplat 训练 → 单个 PLY。

脚本：`scripts/multiview_to_ply.sh`
环境：conda 环境 **`gsplat`**，已装 gsplat + pycolmap，系统有 colmap / ffmpeg，GPU RTX 5080 16GB。

> 与 `batch_video_to_ply.sh` 的区别：batch 是「每个视频各出一个 ply」用 `sequential_matcher`（只配相邻帧）；
> 本脚本是「多个视频合成一个 ply」用 **`exhaustive_matcher`（全配对）**——这样跨视频的帧才会互相匹配、
> 注册进同一坐标系。否则三段会裂成三个互不相干的模型，合不到一起。

---

## 输入约定：一个场景 = 一个子文件夹

```
data/
  lab/              ← 一个场景
    top.mp4
    mid.mp4
    bottom.mp4
  <下一个场景>/      ← 视频数量随意（2 个、4 个都行）
    *.mp4
```

- 文件夹里放这个场景**所有视角**的视频，文件名随意（会用文件名当帧前缀，如 `top_0001.jpg`）。
- 支持 `.mp4 / .MP4 / .mov / .MOV`。

---

## 怎么跑

### 方式 A：改脚本开头两行（你的习惯）

打开 `scripts/multiview_to_ply.sh`，改最上面这两行的默认值：

```bash
IN_DIR="${1:-data/lab}"     # ← 改成 data/<你的场景名>
OUT_NAME="${2:-lab}"        # ← 改成 <你的场景名>（输出到 output/<场景名>/）
```

然后：

```bash
conda activate gsplat
scripts/multiview_to_ply.sh
```

### 方式 B：直接传参（不用改脚本）

```bash
conda activate gsplat
scripts/multiview_to_ply.sh data/<场景名> <场景名>
```

### 后台整夜跑（高质量档耗时长时）

```bash
conda activate gsplat
setsid bash -c 'scripts/multiview_to_ply.sh' </dev/null \
  > output/<场景名>_$(date +%m%d_%H%M).log 2>&1 &
tail -f output/<场景名>_*.log     # Ctrl-C 只退 tail，不停任务
```

---

## 质量 / 速度档（脚本顶部变量，可用环境变量覆盖）

| 变量 | 默认（快速预览） | 说明 |
|---|---|---|
| `TARGET_PER_VID` | 80 | 每个视频抽多少帧。越多越细、COLMAP 全配对越慢（~O(N²)） |
| `SUBCMD` | `default` | 训练算法：`default` / `mcmc`（mcmc 通常质量更好） |
| `STEPS` | 7000 | 训练步数。30000 是高质量常用值 |
| `CAMERA_MODEL` | `OPENCV` | 普通镜头；广角/鱼眼用 `OPENCV_FISHEYE` |
| `SCALE_H` | 720 | 抽帧目标高度（竖屏源 406×720，默认不放大） |

**快速预览**（默认）：先验证多视角能不能合到一起，约十几分钟。
**高质量**示例：

```bash
TARGET_PER_VID=200 SUBCMD=mcmc STEPS=30000 scripts/multiview_to_ply.sh
```

---

## 跑完怎么看是否成功

脚本会自动打印两个关键信息：

1. **挑选的 SfM 模型注册数**：`选中: .../sparse/0 (注册 240 / 抽帧 240)`
   —— 注册数接近总抽帧数 = 三视角合到了一起。若注册率 < 60% 会有 `⚠` 提示。
2. **各视角注册帧数**：

   ```
   bottom: 80 帧
   mid: 80 帧
   top: 80 帧
   合计注册: 240
   ```
   —— 三个前缀都有 = 每个视角都进了同一个模型。**若某个视角是 0 帧，说明它没合上**
   （那个视角和其它视角共视太少，需补拍重叠区域 / 提高 `TARGET_PER_VID`）。
3. 训练末尾的 **PSNR**：实测 lab 三视角 **35.7**（越高越好；个位数 = 重建失败）。

成功标志（脚本结尾）：`# ✓ 完成: output/<场景名>/results/ply/point_cloud_<步数-1>.ply`

> 指标查看（PSNR/SSIM/LPIPS 汇总表、loss 曲线、定性对比图）见 `QUICKSTART.md` 的「查看指标 / 写文章」。
> 所有训练脚本已固定 `--lpips_net vgg`（对齐 3DGS）+ 最终步评估。

---

## 产物结构

```
output/<场景名>/
  images/                  三视角合并的抽帧（带前缀）
  database.db              COLMAP 库
  sparse/0/                合并后的完整 SfM 模型（已自动挑选）
  results/ply/             point_cloud_<步数-1>.ply   ← 最终结果
  results/ckpts/           ckpt_*.pt
```

查看 PLY：拖进 https://superspl.at/editor ，或

```bash
python gsplat/examples/simple_viewer.py --ckpt output/<场景名>/results/ckpts/ckpt_<步数-1>_rank0.pt
```

---

## 注意 / 常见问题

| 现象 | 原因 / 解决 |
|------|------|
| 某视角注册 0 帧 / 注册率低 | 该视角与其它视角重叠不够。拍摄时保证视角间有公共可见区域；或调大 `TARGET_PER_VID` |
| 整体注册图像很少、PSNR 个位数 | 多半 COLMAP 失败：确认 `WORK_ROOT` 是本地 ext4（脚本会拦 FUSE 盘）、相机模型选对 |
| 全配对很慢 | `exhaustive_matcher` 随帧数 ~O(N²)。先用默认 80 帧/视频，确认能合上再加密度 |
| 训练卡很久没动 | 首次 `import gsplat` 编译 CUDA 核，约 10~20 分钟，只编一次 |
| 显存 OOM | 调小 `TARGET_PER_VID`，或 `SCALE_H` 降到 540 |

> COLMAP / 训练全程在本地 `scratch/`（ext4），完成后整体搬到 `output/`。原因：`output/` 在 16TB FUSE 盘上，
> COLMAP mapper 在 FUSE 上三角化会失败。详见 `QUICKSTART_BATCH.md` 的「本地工作盘 scratch/」。
